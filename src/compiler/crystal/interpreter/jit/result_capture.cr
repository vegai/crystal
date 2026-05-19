module Crystal::JIT
  # Wraps a parsed user input AST so the value of its last expression is
  # captured and pretty-printed as `=> <inspect>`, mirroring the bytecode
  # REPL's response. Definitions that don't yield a value (Def, ClassDef,
  # ModuleDef, FunDef, LibDef, EnumDef, Macro, Require, Annotation) print
  # `=> nil` instead.
  module ResultCapture
    extend self

    def wrap(node : Crystal::ASTNode) : Crystal::ASTNode
      wrap_structure(node, when_empty: ->(n : Crystal::ASTNode) { n }) do |last|
        wrap_last(last)
      end
    end

    # Captures the last expression's `inspect` into `@@__repl_eval_holder`,
    # paired with a class-method getter so spec callers can read it after
    # `LocalLifter` wraps the AST in `module __REPLState`.
    EVAL_HOLDER_CLASS_VAR   = "@@__repl_eval_holder"
    EVAL_HOLDER_GETTER_NAME = "__repl_eval_holder"

    def wrap_for_value(node : Crystal::ASTNode) : Crystal::ASTNode
      empty_capture = ->(_n : Crystal::ASTNode) {
        Crystal::Expressions.new([nil_holder_assign(nil)] of Crystal::ASTNode).as(Crystal::ASTNode)
      }
      capture = wrap_structure(node, when_empty: empty_capture) do |last|
        holder_capture_for(last)
      end

      # Declare the holder's type explicitly: TypeGuessVisitor can't infer
      # `something.inspect`, so without this TypeDeclarationVisitor wouldn't
      # register the class var before ClassVarsInitializerVisitor reaches it.
      synth_loc = Crystal::Location.new("(jit-eval-wrap)", 1, 1)
      holder_decl = AstHelpers.class_var_decl(
        EVAL_HOLDER_CLASS_VAR, "String", Crystal::StringLiteral.new("nil"), synth_loc)

      # Class-method getter that `eval_for_spec` calls from the top level
      # after `prepare_top_level_for_submission` wraps everything in
      # `module __REPLState`. `self` receiver keeps it out of the lifter.
      getter_def = AstHelpers.def_with_self_receiver(
        EVAL_HOLDER_GETTER_NAME, [] of Crystal::Arg,
        Crystal::ClassVar.new(EVAL_HOLDER_CLASS_VAR))

      Crystal::Expressions.new([holder_decl, capture, getter_def] of Crystal::ASTNode)
    end

    private def holder_capture_for(expr : Crystal::ASTNode) : Crystal::Expressions
      build_parts(expr) do |value, loc|
        if value
          [AstHelpers.class_var_assign(EVAL_HOLDER_CLASS_VAR, inspect_call(value, loc), loc)] of Crystal::ASTNode
        else
          [nil_holder_assign(loc)] of Crystal::ASTNode
        end
      end
    end

    private def inspect_call(target : Crystal::ASTNode, loc : Crystal::Location?) : Crystal::Call
      call = Crystal::Call.new(target, "inspect")
      call.at(loc) if loc
      call
    end

    private def nil_holder_assign(loc : Crystal::Location?) : Crystal::Assign
      str = Crystal::StringLiteral.new("nil")
      str.at(loc) if loc
      AstHelpers.class_var_assign(EVAL_HOLDER_CLASS_VAR, str, loc)
    end

    private def wrap_last(expr : Crystal::ASTNode) : Crystal::Expressions
      build_parts(expr) do |value, loc|
        if value
          result_var = Crystal::Var.new("__repl_result__").at(loc)
          [
            Crystal::Assign.new(result_var, value).at(loc).as(Crystal::ASTNode),
            AstHelpers.string_arg_call("print", " => ", loc),
            Crystal::Call.new(nil, "puts", [
              Crystal::Call.new(result_var.clone.at(loc).as(Crystal::ASTNode), "inspect").at(loc).as(Crystal::ASTNode),
            ] of Crystal::ASTNode).at(loc),
          ] of Crystal::ASTNode
        else
          [AstHelpers.string_arg_call("puts", " => nil", loc)] of Crystal::ASTNode
        end
      end
    end

    # Shared scaffold: split `expr`, push the optional pre-statement,
    # then yield `(value, loc)` so the caller picks the per-variant
    # capture parts.
    private def build_parts(expr : Crystal::ASTNode, & : (Crystal::ASTNode?, Crystal::Location?) -> Array(Crystal::ASTNode)) : Crystal::Expressions
      loc = expr.location
      pre, value = capture_parts(expr, loc)
      parts = [] of Crystal::ASTNode
      parts << pre if pre
      parts.concat(yield value, loc)
      Crystal::Expressions.new(parts).at(loc)
    end

    # Splits `expr` into `(pre_statement, value_to_capture)`.
    # `pre_statement` keeps definitions / side-effect assigns visible at
    # top level; `value_to_capture` is `nil` for non-value definitions.
    private def capture_parts(expr : Crystal::ASTNode, loc : Crystal::Location?) : {Crystal::ASTNode?, Crystal::ASTNode?}
      if AstShape.non_value_expression?(expr)
        {expr, nil}
      elsif expr.is_a?(Crystal::Assign) && (target = expr.target).is_a?(Crystal::Var)
        {expr, Crystal::Var.new(target.name).at(loc)}
      else
        {nil, expr}
      end
    end

    # Skeleton shared by `wrap` and `wrap_for_value`. The block runs on the
    # AST's last expression and returns the replacement Expressions; the
    # empty/Nop case delegates to `when_empty`.
    private def wrap_structure(node : Crystal::ASTNode,
                               when_empty : Crystal::ASTNode -> Crystal::ASTNode,
                               & : Crystal::ASTNode -> Crystal::Expressions) : Crystal::ASTNode
      case node
      when Crystal::Nop
        when_empty.call(node)
      when Crystal::Expressions
        return when_empty.call(node) if node.expressions.empty?
        last = node.expressions[-1]
        rest = node.expressions[0...-1]
        Crystal::Expressions.new(rest.concat(yield(last).expressions))
      else
        yield(node)
      end
    end
  end
end
