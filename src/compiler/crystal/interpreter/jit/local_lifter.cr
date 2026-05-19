module Crystal::JIT
  # Rewrites top-level local assignments/references in REPL input to use
  # class variables on `__REPLState` so values persist across submissions.
  # Names inside nested scopes (Def, Block, ProcLiteral, Macro, FunDef,
  # ClassDef, ModuleDef) are left alone.
  class LocalLifter < Crystal::Transformer
    PREFIX                 = "@@__repl_"
    RESERVED_NAME_PREFIXES = {"__repl_", "__temp_"}

    @scope_depth : Int32 = 0
    @known : Set(String)

    def initialize(@known : Set(String))
    end

    private def at_top_level? : Bool
      @scope_depth == 0
    end

    private def reserved?(name : String) : Bool
      RESERVED_NAME_PREFIXES.any? { |prefix| name.starts_with?(prefix) }
    end

    def transform(node : Crystal::Assign) : Crystal::ASTNode
      if at_top_level? && (target = node.target).is_a?(Crystal::Var) && !reserved?(target.name)
        @known << target.name
        new_target = Crystal::ClassVar.new("#{PREFIX}#{target.name}").at(target)
        node.value = node.value.transform(self)
        Crystal::Assign.new(new_target, node.value).at(node)
      else
        super
      end
    end

    def transform(node : Crystal::Var) : Crystal::ASTNode
      if at_top_level? && !reserved?(node.name) && @known.includes?(node.name)
        Crystal::ClassVar.new("#{PREFIX}#{node.name}").at(node)
      else
        node
      end
    end

    # Top-level identifiers parse as `Call`; rewrite the ones we know are persistent locals.
    def transform(node : Crystal::Call) : Crystal::ASTNode
      if lift_call_as_class_var?(node)
        Crystal::ClassVar.new("#{PREFIX}#{node.name}").at(node)
      else
        super
      end
    end

    private def lift_call_as_class_var?(node : Crystal::Call) : Bool
      at_top_level? && node.obj.nil? && node.args.empty? && node.block.nil? &&
        node.block_arg.nil? && node.named_args.nil? &&
        !reserved?(node.name) && @known.includes?(node.name)
    end

    # Top-level `def foo` becomes `def self.foo` so the wrapper module's
    # body can call it from any submission. The Def is mutated in place;
    # safe because submission ASTs are freshly parsed and not shared.
    def transform(node : Crystal::Def) : Crystal::ASTNode
      if at_top_level? && node.receiver.nil?
        node.receiver = Crystal::Var.new("self").at(node)
      end
      @scope_depth += 1
      result = super
      @scope_depth -= 1
      result
    end

    def transform(node : Crystal::Block | Crystal::ProcLiteral | Crystal::Macro | Crystal::FunDef | Crystal::ClassDef | Crystal::ModuleDef) : Crystal::ASTNode
      @scope_depth += 1
      result = super
      @scope_depth -= 1
      result
    end
  end
end
