module Crystal::JIT
  # Forces `codegen_fun` to fire for `Def`s in the user input by
  # prepending a synthetic `ProcPointer`/`ProcLiteral` reference. Without
  # this, a lone `def foo` submission never reaches codegen and the
  # dispatch slot stays pointed at the previous version. Three shapes:
  # top-level proc-pointer, instance-method allocate-and-call, and the
  # block-arg variant. Synthetics carry the `(jit-redef-force)` filename
  # so their mangling can't collide with user proc literals.
  module RedefForce
    extend self

    def inject(node : Crystal::ASTNode, program : Crystal::Program? = nil) : Crystal::ASTNode
      synthetics = collect_synthetics(node, program)
      return node if synthetics.empty?

      if node.is_a?(Crystal::Expressions)
        Crystal::Expressions.new(synthetics + node.expressions)
      else
        Crystal::Expressions.new(synthetics + [node])
      end
    end

    private def collect_synthetics(node : Crystal::ASTNode, program : Crystal::Program?) : Array(Crystal::ASTNode)
      result = [] of Crystal::ASTNode
      case node
      when Crystal::Expressions
        node.expressions.each { |e| collect_from(e, program, result) }
      else
        collect_from(node, program, result)
      end
      result
    end

    private def collect_from(node : Crystal::ASTNode, program : Crystal::Program?, result : Array(Crystal::ASTNode)) : Nil
      case node
      when Crystal::Def
        if top_level_eligible?(node)
          result << synthesize_top_level_or_class_method(node, fresh_force_loc)
        elsif tuples = top_level_unrestricted_with_prior_instances(node, program)
          # `prior_arg_types` replay concrete tuples that earlier call sites
          # populated in `Program#def_instances` for the OLD def, so the new
          # body gets emitted for the same shapes when arg restrictions are
          # absent on the AST.
          tuples.each { |arg_types| result << synthesize_top_level_with_prior_types(node, arg_types, fresh_force_loc) }
        elsif prebuilt = top_level_block_arg_synthetic(node)
          # A3: block-arg redefs build their own Call+Block synthetic; the
          # other branches return ProcPointer / ProcLiteral built here.
          result << prebuilt
        end
      when Crystal::ClassDef
        collect_from_class_body(node, result) if instance_methods_addressable?(node, program)
      end
    end

    # Synthetic for `def m(&b : InT -> OutT)`: `ProcPointer` can't address
    # block-taking methods, so wrap a `Call` carrying an inert `Block` in
    # a `ProcLiteral`. Body is `__ret = uninitialized OutT; __ret`.
    private def top_level_block_arg_synthetic(d : Crystal::Def) : Crystal::ASTNode?
      return nil if d.double_splat || d.abstract? || d.macro_def?
      return nil unless d.receiver.nil? || d.receiver.is_a?(Crystal::Path)
      return nil unless arg_restrictions_present?(d)
      block_arg = d.block_arg
      return nil unless block_arg
      restriction = block_arg.restriction
      return nil unless restriction.is_a?(Crystal::ProcNotation)
      output = restriction.output
      return nil unless output
      # Skip underspecified `-> _` shapes: `uninitialized _` is not
      # materialisable, so let caller-driven emission handle it.
      return nil if contains_underscore?(output)
      inputs_for_check = restriction.inputs
      if inputs_for_check
        return nil if inputs_for_check.any? { |i| contains_underscore?(i) }
      end

      counter = fresh_counter
      loc = Crystal::Location.new("(jit-redef-force)", counter, 1)
      inputs = restriction.inputs || [] of Crystal::ASTNode
      block_args = inputs.map_with_index do |_, i|
        var = Crystal::Var.new("__redef_force_blkarg_#{counter}_#{i}")
        var.at(loc)
        var
      end

      ret_var = Crystal::Var.new("__redef_force_blkret_#{counter}")
      ret_var.at(loc)
      block_body = Crystal::Expressions.new([
        Crystal::UninitializedVar.new(ret_var, output.clone).at(loc).as(Crystal::ASTNode),
        ret_var.clone.as(Crystal::ASTNode),
      ])
      block_body.at(loc)

      block = Crystal::Block.new(block_args, block_body)
      block.at(loc)

      obj = d.receiver.try(&.clone)
      call = Crystal::Call.new(obj, d.name, uninitialized_call_args(d, loc))
      call.block = block
      call.at(loc)

      proc_def = Crystal::Def.new("->", [] of Crystal::Arg, call)
      proc_def.at(loc)
      proc_literal = Crystal::ProcLiteral.new(proc_def)
      proc_literal.at(loc)
      proc_literal
    end

    # Process-wide: stale LinkOnceODR bodies would otherwise survive `Repl#reset`.
    @@counter = Atomic(Int32).new(0)

    private def fresh_counter : Int32
      @@counter.add(1)
    end

    private def contains_underscore?(node : Crystal::ASTNode) : Bool
      BoolFlagVisitor.found_in?(node) { |n| n.is_a?(Crystal::Underscore) }
    end

    # Replays cached typed instances for a redef whose args are
    # unrestricted, so the new body lands at every previously-seen shape.
    private def top_level_unrestricted_with_prior_instances(d : Crystal::Def, program : Crystal::Program?) : Array(Array(Crystal::Type))?
      return nil unless program
      return nil unless def_supportable?(d)
      return nil unless d.receiver.nil?
      return nil if d.args.empty?
      # If every arg has a restriction the `top_level_eligible?` branch
      # already handles this def. Only fire when at least one arg is
      # unrestricted.
      return nil if d.args.all? { |arg| !arg.restriction.nil? }

      defs_hash = program.defs
      return nil unless defs_hash
      prior_defs = defs_hash[d.name]?
      return nil if prior_defs.nil? || prior_defs.empty?

      tuples = [] of Array(Crystal::Type)
      # Tuple-of-fingerprints: object_id catches the common case;
      # to_s defends against the theoretical post-`Repl#reset` case
      # where a fresh Type could land at a recycled object_id slot.
      seen = Set({Array(UInt64), Array(String)}).new
      prior_defs.each do |dwm|
        prior_def = dwm.def
        next unless prior_def.args.size == d.args.size
        program.def_instances.each do |key, _|
          next unless key.def_object_id == prior_def.object_id
          fingerprint = {key.arg_types.map(&.object_id), key.arg_types.map(&.to_s)}
          next if seen.includes?(fingerprint)
          seen << fingerprint
          tuples << key.arg_types
        end
      end
      tuples.empty? ? nil : tuples
    end

    private def instance_methods_addressable?(cls : Crystal::ClassDef, program : Crystal::Program?) : Bool
      # Skip abstract classes (no `.allocate`), structs/value types,
      # and generic classes.
      return false if cls.abstract?
      return false if cls.struct?
      return false unless cls.type_vars.nil? || cls.type_vars.try(&.empty?)
      # Reopened classes (`class Object; ... end`) carry the real
      # abstract/struct flag on the existing type, not the new AST.
      if program
        name = cls.name.names.join("::")
        existing = program.types[name]?
        if existing.is_a?(Crystal::ClassType)
          return false if existing.abstract?
          return false if existing.struct?
        end
      end
      true
    end

    private def collect_from_class_body(cls : Crystal::ClassDef, result : Array(Crystal::ASTNode)) : Nil
      body = cls.body
      cls_path = cls.name
      case body
      when Crystal::Expressions
        body.expressions.each { |e| collect_instance_def(e, cls_path, result) }
      else
        collect_instance_def(body, cls_path, result)
      end
    end

    private def collect_instance_def(node : Crystal::ASTNode, cls_path : Crystal::Path, result : Array(Crystal::ASTNode)) : Nil
      return unless node.is_a?(Crystal::Def)
      d = node.as(Crystal::Def)
      # Inside a class body, a Def with a `self` or Path receiver is a
      # class method, handled separately (or out of scope). We only
      # care about instance methods, which have a nil receiver.
      return unless d.receiver.nil?
      return unless def_supportable?(d)
      return unless arg_restrictions_present?(d)
      # Skip `initialize` and any non-public visibility; the synthetic
      # is `ClassName.allocate.method(...)` at top level, which would
      # try to invoke a protected/private method from outside the
      # class body and trip semantic's visibility check.
      return if d.name == "initialize"
      return unless d.visibility.public?
      result << synthesize_instance_method(d, cls_path, fresh_force_loc)
    end

    private def top_level_eligible?(d : Crystal::Def) : Bool
      return false unless def_supportable?(d)
      receiver = d.receiver
      return false unless receiver.nil? || receiver.is_a?(Crystal::Path)
      arg_restrictions_present?(d)
    end

    # Skip shapes RedefForce can't synthesise an inert call for. The
    # block-arg branch (`top_level_block_arg_synthetic`) intentionally
    # allows block_arg/block_arity and uses a narrower check inline.
    private def def_supportable?(d : Crystal::Def) : Bool
      !(d.double_splat || d.block_arg || d.block_arity || d.abstract? || d.macro_def?)
    end

    private def arg_restrictions_present?(d : Crystal::Def) : Bool
      d.args.all? { |arg| !arg.restriction.nil? }
    end

    private def fresh_force_loc : Crystal::Location
      Crystal::Location.new("(jit-redef-force)", fresh_counter, 1)
    end

    private def synthesize_top_level_or_class_method(d : Crystal::Def, loc : Crystal::Location) : Crystal::ProcPointer
      args = d.args.map { |arg| arg.restriction.not_nil!.clone.as(Crystal::ASTNode) }
      obj = d.receiver.try(&.clone)
      Crystal::ProcPointer.new(obj, d.name, args).at(loc)
    end

    # The unrestricted-arg synthetic wraps each prior arg type in a
    # `TypeNode` (a "fictitious" AST node carrying a `Type`), letting
    # `ProcPointer` expansion attach the type to the placeholder arg
    # without needing to round-trip through Crystal source syntax.
    private def synthesize_top_level_with_prior_types(d : Crystal::Def, arg_types : Array(Crystal::Type), loc : Crystal::Location) : Crystal::ProcPointer
      args = arg_types.map { |t| Crystal::TypeNode.new(t).as(Crystal::ASTNode) }
      Crystal::ProcPointer.new(nil, d.name, args).at(loc)
    end

    private def synthesize_instance_method(d : Crystal::Def, cls_path : Crystal::Path, loc : Crystal::Location) : Crystal::ProcLiteral
      allocate_call = Crystal::Call.new(cls_path.clone.as(Crystal::ASTNode), "allocate").at(loc)
      call = Crystal::Call.new(allocate_call, d.name, uninitialized_call_args(d, loc)).at(loc)
      proc_def = Crystal::Def.new("->", [] of Crystal::Arg, call).at(loc)
      Crystal::ProcLiteral.new(proc_def).at(loc)
    end

    # Builds `[uninitialized T1, uninitialized T2, ...]` from `d.args`
    # restrictions, for use as call args inside an inert synthetic.
    private def uninitialized_call_args(d : Crystal::Def, loc : Crystal::Location) : Array(Crystal::ASTNode)
      d.args.map do |arg|
        uvar = Crystal::Var.new(restriction_temp_name).at(loc)
        type_path = arg.restriction.not_nil!.clone.at(loc)
        Crystal::UninitializedVar.new(uvar, type_path).at(loc).as(Crystal::ASTNode)
      end
    end

    private def restriction_temp_name : String
      "__redef_force_arg#{fresh_counter}"
    end
  end
end
