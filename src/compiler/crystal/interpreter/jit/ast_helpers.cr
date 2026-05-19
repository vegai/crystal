module Crystal::JIT
  # Tiny constructors for synthetic AST nodes used by the JIT REPL.
  # Centralises the duplicated `node.at(loc)` boilerplate.
  module AstHelpers
    extend self

    # `def name(*args); body; end` with `self` as the receiver (so the
    # lifter leaves it at top level and codegen emits it as a class method).
    def def_with_self_receiver(name : String, args : Array(Crystal::Arg), body : Crystal::ASTNode) : Crystal::Def
      d = Crystal::Def.new(name, args, body)
      d.receiver = Crystal::Var.new("self")
      d
    end

    # `@@<name> : <type_path> = <default>` at `loc`.
    def class_var_decl(name : String, type_path : String, default : Crystal::ASTNode,
                       loc : Crystal::Location) : Crystal::TypeDeclaration
      Crystal::TypeDeclaration.new(
        Crystal::ClassVar.new(name).at(loc),
        Crystal::Path.new(type_path).at(loc),
        default.at(loc),
      ).at(loc)
    end

    # `@@<name> = <value>` at `loc` (omitted if `nil`).
    def class_var_assign(name : String, value : Crystal::ASTNode,
                         loc : Crystal::Location?) : Crystal::Assign
      assign = Crystal::Assign.new(
        Crystal::ClassVar.new(name).at(loc),
        value,
      )
      assign.at(loc) if loc
      assign
    end

    # `method(content)` with no receiver, at `loc` (omitted if `nil`).
    def string_arg_call(method : String, content : String,
                        loc : Crystal::Location?) : Crystal::Call
      str = Crystal::StringLiteral.new(content)
      str.at(loc) if loc
      Crystal::Call.new(nil, method, [str] of Crystal::ASTNode).at(loc)
    end

    # `<obj>.<method>(*args)` at `loc`. `args` defaults to empty so
    # zero-arg calls (`err.class`, `err.message`) don't have to spell
    # out an empty array.
    def call_with_receiver(obj : Crystal::ASTNode, method : String,
                           loc : Crystal::Location,
                           args : Array(Crystal::ASTNode) = [] of Crystal::ASTNode) : Crystal::Call
      Crystal::Call.new(obj, method, args).at(loc)
    end
  end
end
