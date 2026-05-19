module Crystal::JIT
  # Categorisation of AST shapes used by JIT submission handling.
  # One module so the four predicates (declaration placement, type-graph
  # mutation, value definition, value-printing eligibility) cannot drift.
  module AstShape
    extend self

    # Type-graph mutators: defining a type or function, including another
    # type, requiring more code, or expanding a macro.
    def type_mutating?(node : Crystal::ASTNode) : Bool
      case node
      when Crystal::ClassDef, Crystal::ModuleDef, Crystal::EnumDef, Crystal::LibDef,
           Crystal::Def, Crystal::FunDef, Crystal::Macro,
           Crystal::Include, Crystal::Extend,
           Crystal::Alias, Crystal::Require,
           Crystal::MacroExpression, Crystal::MacroFor, Crystal::MacroIf
        true
      else
        false
      end
    end

    # Nodes that must sit at module-body level rather than inside an
    # `ExceptionHandler` (declarations trip "can't declare X dynamically";
    # `@@__repl_*` assigns trip a missing-var BUG via the literal expander).
    def declaration?(node : Crystal::ASTNode) : Bool
      return true if type_mutating?(node)
      case node
      when Crystal::AnnotationDef, Crystal::VisibilityModifier, Crystal::FileNode
        true
      when Crystal::Assign
        target = node.target
        target.is_a?(Crystal::ClassVar) && target.name.starts_with?("@@__repl_")
      else
        false
      end
    end

    # Defines a method, type, or top-level constant (`Assign(Path)`).
    # Used to invalidate the Repl's wrapper cache.
    def defines_value?(node : Crystal::ASTNode) : Bool
      case node
      when Crystal::Def, Crystal::ClassDef, Crystal::ModuleDef, Crystal::EnumDef,
           Crystal::FunDef, Crystal::Macro, Crystal::LibDef
        true
      when Crystal::Assign
        node.target.is_a?(Crystal::Path)
      else
        false
      end
    end

    # The expression itself yields nothing inspect-worthy: ResultCapture
    # skips the `=> <inspect>` line for these and prints `=> nil` instead.
    def non_value_expression?(node : Crystal::ASTNode) : Bool
      case node
      when Crystal::Def, Crystal::ClassDef, Crystal::ModuleDef, Crystal::FunDef,
           Crystal::LibDef, Crystal::EnumDef, Crystal::Macro, Crystal::Require, Crystal::Annotation
        true
      else
        false
      end
    end
  end
end
