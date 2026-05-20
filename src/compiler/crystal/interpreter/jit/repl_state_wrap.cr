module Crystal::JIT
  # AST rewrites that wrap a submission body in the `__REPLState` module
  # so top-level locals lift to class vars that persist across
  # submissions. Pure AST work, no LLJIT dependency — kept out of
  # `Session` so the JIT compilation pipeline stays self-contained.
  module ReplStateWrap
    extend self

    # Lifts top-level locals to class vars on `__REPLState` so they
    # persist across submissions, then wraps the body in `module
    # __REPLState`. `require`s hoist out as siblings of the wrapper.
    def wrap(node : ASTNode, repl_locals : Set(String)) : ASTNode
      inner = node.transform(LocalLifter.new(repl_locals))

      partitioner = ModuleWrapPartitioner.new
      partitioner.classify(inner)

      module_def = ModuleDef.new(Path.new("__REPLState"), Expressions.from(partitioner.body))
      if partitioner.outer.empty?
        module_def
      else
        Expressions.from(partitioner.outer.concat([module_def.as(ASTNode)]))
      end
    end

    # Wraps consecutive runtime statements in the `__REPLState` body
    # with `handler`, leaving declarations at body level.
    def wrap_runtime_with_rescue(node : ASTNode, handler : ASTNode -> ASTNode) : ASTNode
      rewrite_repl_state_body(node) do |body|
        RuntimeRescueGrouper.group(body, handler)
      end
    end

    # Replaces the body of the `__REPLState` ModuleDef found inside `node`
    # with the result of `block.call(body)`. Handles both shapes produced
    # by `wrap`: a bare `ModuleDef` and an `Expressions` containing
    # requires followed by the `ModuleDef`.
    private def rewrite_repl_state_body(node : ASTNode, & : ASTNode -> ASTNode) : ASTNode
      case node
      when ModuleDef
        node.body = yield node.body
        node
      when Expressions
        module_def = node.expressions.find &.is_a?(ModuleDef)
        raise "BUG: wrap_runtime_with_rescue: no __REPLState ModuleDef in Expressions" unless module_def
        module_def = module_def.as(ModuleDef)
        module_def.body = yield module_def.body
        node
      else
        raise "BUG: wrap_runtime_with_rescue: expected wrap output, got #{node.class}"
      end
    end

    # Splits a submission body into siblings of the `module __REPLState` wrap
    # (`outer`) and members of its body (`body`). Requires hoist out; the rest
    # stays inside the wrapper.
    private class ModuleWrapPartitioner
      getter outer = [] of ASTNode
      getter body = [] of ASTNode

      def classify(node : ASTNode) : Nil
        case node
        when Expressions
          node.expressions.each { |child| classify(child) }
        when Require
          @outer << node
        else
          @body << node
        end
      end
    end

    # Walks a flat body sequence and groups consecutive non-declaration
    # nodes through `handler` (which builds an `ExceptionHandler` around its
    # input). Declarations remain at their original position so the JIT's
    # codegen doesn't trip on `def`/`class`/`@@__repl_*=…` inside a rescue.
    private class RuntimeRescueGrouper
      def self.group(body : ASTNode, handler : ASTNode -> ASTNode) : ASTNode
        return body if body.is_a?(Nop)
        rewritten = [] of ASTNode
        runtime_group = [] of ASTNode
        children =
          case body
          when Expressions
            body.expressions
          else
            [body]
          end
        children.each do |child|
          if AstShape.declaration?(child)
            flush_group(rewritten, runtime_group, handler)
            rewritten << child
          else
            runtime_group << child
          end
        end
        flush_group(rewritten, runtime_group, handler)
        Expressions.from(rewritten)
      end

      private def self.flush_group(rewritten : Array(ASTNode), runtime_group : Array(ASTNode), handler : ASTNode -> ASTNode) : Nil
        return if runtime_group.empty?
        grouped = runtime_group.size == 1 ? runtime_group[0] : Expressions.new(runtime_group.dup)
        rewritten << handler.call(grouped)
        runtime_group.clear
      end
    end
  end
end
