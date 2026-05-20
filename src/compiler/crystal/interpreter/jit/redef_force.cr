module Crystal::JIT
  # Forces `codegen_fun` to fire for `Def`s in the user input by
  # prepending a synthetic `ProcPointer`/`ProcLiteral` reference. Without
  # this, a lone `def foo` submission never reaches codegen and the
  # dispatch slot stays pointed at the previous version. Three shapes:
  # top-level proc-pointer, instance-method allocate-and-call, and the
  # block-arg variant. Synthetics carry the `(jit-redef-force)` filename
  # so their mangling can't collide with user proc literals.
  #
  # One instance per `Session` so the synthetic counter resets when a
  # `Repl#reset` drops the LLJIT dylib (cross-Session reuse of a synthetic
  # name would still be fine under LinkOnceODR, but a per-Session counter
  # makes mangled-name debugging easier and keeps state where it belongs).
  class RedefForce
    @counter : Int32 = 0

    def inject(node : ASTNode, program : Program? = nil) : ASTNode
      synthetics = collect_synthetics(node, program)
      return node if synthetics.empty?

      if node.is_a?(Expressions)
        Expressions.new(synthetics + node.expressions)
      else
        Expressions.new(synthetics + [node])
      end
    end

    private def collect_synthetics(node : ASTNode, program : Program?) : Array(ASTNode)
      result = [] of ASTNode
      case node
      when Expressions
        node.expressions.each { |e| collect_from(e, program, result) }
      else
        collect_from(node, program, result)
      end
      result
    end

    private def collect_from(node : ASTNode, program : Program?, result : Array(ASTNode)) : Nil
      case node
      when Def
        if restrictions = top_level_eligible_restrictions(node)
          result << synthesize_top_level_or_class_method(node, restrictions, fresh_force_loc)
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
      when ClassDef
        collect_from_class_body(node, result) if instance_methods_addressable?(node, program)
      end
    end

    # Synthetic for `def m(&b : InT -> OutT)`: `ProcPointer` can't address
    # block-taking methods, so wrap a `Call` carrying an inert `Block` in
    # a `ProcLiteral`. Body is `__ret = uninitialized OutT; __ret`.
    private def top_level_block_arg_synthetic(d : Def) : ASTNode?
      return nil if d.double_splat || d.abstract? || d.macro_def?
      return nil unless d.receiver.nil? || d.receiver.is_a?(Path)
      restrictions = arg_restrictions(d)
      return nil unless restrictions
      block_arg = d.block_arg
      return nil unless block_arg
      restriction = block_arg.restriction
      return nil unless restriction.is_a?(ProcNotation)
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
      loc = Location.new("(jit-redef-force)", counter, 1)
      inputs = restriction.inputs || [] of ASTNode
      block_args = inputs.map_with_index do |_, i|
        var = Var.new("__redef_force_blkarg_#{counter}_#{i}")
        var.at(loc)
        var
      end

      ret_var = Var.new("__redef_force_blkret_#{counter}")
      ret_var.at(loc)
      block_body = Expressions.new([
        UninitializedVar.new(ret_var, output.clone).at(loc).as(ASTNode),
        ret_var.clone.as(ASTNode),
      ])
      block_body.at(loc)

      block = Block.new(block_args, block_body)
      block.at(loc)

      obj = d.receiver.try(&.clone)
      call = Call.new(obj, d.name, uninitialized_call_args(restrictions, loc))
      call.block = block
      call.at(loc)

      proc_def = Def.new("->", [] of Arg, call)
      proc_def.at(loc)
      proc_literal = ProcLiteral.new(proc_def)
      proc_literal.at(loc)
      proc_literal
    end

    private def fresh_counter : Int32
      @counter += 1
    end

    private def contains_underscore?(node : ASTNode) : Bool
      AstShape.any_descendant?(node) { |n| n.is_a?(Underscore) }
    end

    # Replays cached typed instances for a redef whose args are
    # unrestricted, so the new body lands at every previously-seen shape.
    private def top_level_unrestricted_with_prior_instances(d : Def, program : Program?) : Array(Array(Type))?
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

      tuples = [] of Array(Type)
      # `to_s` survives a post-`Repl#reset` object_id recycle: a fresh
      # Type at the same address still stringifies to its current name.
      seen = Set(Array(String)).new
      prior_defs.each do |dwm|
        prior_def = dwm.def
        next unless prior_def.args.size == d.args.size
        program.def_instances.each do |key, _|
          next unless key.def_object_id == prior_def.object_id
          fingerprint = key.arg_types.map(&.to_s)
          next if seen.includes?(fingerprint)
          seen << fingerprint
          tuples << key.arg_types
        end
      end
      tuples.empty? ? nil : tuples
    end

    private def instance_methods_addressable?(cls : ClassDef, program : Program?) : Bool
      # Skip abstract classes (no `.allocate`), structs/value types,
      # and generic classes.
      return false if cls.abstract?
      return false if cls.struct?
      return false unless cls.type_vars.nil? || cls.type_vars.try(&.empty?)
      # Reopened classes (`class Object; ... end`) carry the real
      # abstract/struct flag on the existing type, not the new AST.
      if program
        name = AstHelpers.path_to_string(cls.name)
        existing = program.types[name]?
        if existing.is_a?(ClassType)
          return false if existing.abstract?
          return false if existing.struct?
        end
      end
      true
    end

    private def collect_from_class_body(cls : ClassDef, result : Array(ASTNode)) : Nil
      body = cls.body
      cls_path = cls.name
      case body
      when Expressions
        body.expressions.each { |e| collect_instance_def(e, cls_path, result) }
      else
        collect_instance_def(body, cls_path, result)
      end
    end

    private def collect_instance_def(node : ASTNode, cls_path : Path, result : Array(ASTNode)) : Nil
      return unless node.is_a?(Def)
      d = node.as(Def)
      # Inside a class body, a Def with a `self` or Path receiver is a
      # class method, handled separately (or out of scope). We only
      # care about instance methods, which have a nil receiver.
      return unless d.receiver.nil?
      return unless def_supportable?(d)
      restrictions = arg_restrictions(d)
      return unless restrictions
      # Skip `initialize` and any non-public visibility; the synthetic
      # is `ClassName.allocate.method(...)` at top level, which would
      # try to invoke a protected/private method from outside the
      # class body and trip semantic's visibility check.
      return if d.name == "initialize"
      return unless d.visibility.public?
      result << synthesize_instance_method(d, cls_path, restrictions, fresh_force_loc)
    end

    # `Array(ASTNode)?` of arg restrictions when every arg has one (the
    # shape `RedefForce` can synthesise an inert call for); nil otherwise.
    # Callers that just want the boolean check it for truthiness.
    private def top_level_eligible_restrictions(d : Def) : Array(ASTNode)?
      return nil unless def_supportable?(d)
      receiver = d.receiver
      return nil unless receiver.nil? || receiver.is_a?(Path)
      arg_restrictions(d)
    end

    # Skip shapes RedefForce can't synthesise an inert call for. The
    # block-arg branch (`top_level_block_arg_synthetic`) intentionally
    # allows block_arg/block_arity and uses a narrower check inline.
    private def def_supportable?(d : Def) : Bool
      !(d.double_splat || d.block_arg || d.block_arity || d.abstract? || d.macro_def?)
    end

    private def arg_restrictions(d : Def) : Array(ASTNode)?
      restrictions = [] of ASTNode
      d.args.each do |arg|
        restriction = arg.restriction
        return nil unless restriction
        restrictions << restriction
      end
      restrictions
    end

    private def fresh_force_loc : Location
      Location.new("(jit-redef-force)", fresh_counter, 1)
    end

    private def synthesize_top_level_or_class_method(d : Def, restrictions : Array(ASTNode), loc : Location) : ProcPointer
      args = restrictions.map { |r| r.clone.as(ASTNode) }
      obj = d.receiver.try(&.clone)
      ProcPointer.new(obj, d.name, args).at(loc)
    end

    # The unrestricted-arg synthetic wraps each prior arg type in a
    # `TypeNode` (a "fictitious" AST node carrying a `Type`), letting
    # `ProcPointer` expansion attach the type to the placeholder arg
    # without needing to round-trip through Crystal source syntax.
    private def synthesize_top_level_with_prior_types(d : Def, arg_types : Array(Type), loc : Location) : ProcPointer
      args = arg_types.map { |t| TypeNode.new(t).as(ASTNode) }
      ProcPointer.new(nil, d.name, args).at(loc)
    end

    private def synthesize_instance_method(d : Def, cls_path : Path, restrictions : Array(ASTNode), loc : Location) : ProcLiteral
      allocate_call = Call.new(cls_path.clone.as(ASTNode), "allocate").at(loc)
      call = Call.new(allocate_call, d.name, uninitialized_call_args(restrictions, loc)).at(loc)
      proc_def = Def.new("->", [] of Arg, call).at(loc)
      ProcLiteral.new(proc_def).at(loc)
    end

    # Builds `[uninitialized T1, uninitialized T2, ...]` from the
    # restriction list, for use as call args inside an inert synthetic.
    private def uninitialized_call_args(restrictions : Array(ASTNode), loc : Location) : Array(ASTNode)
      restrictions.map do |restriction|
        uvar = Var.new(restriction_temp_name).at(loc)
        type_path = restriction.clone.at(loc)
        UninitializedVar.new(uvar, type_path).at(loc).as(ASTNode)
      end
    end

    private def restriction_temp_name : String
      "__redef_force_arg#{fresh_counter}"
    end
  end
end
