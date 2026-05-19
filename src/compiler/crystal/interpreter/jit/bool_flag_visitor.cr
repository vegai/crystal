module Crystal::JIT
  # Single-purpose AST scanner that flips a `found` flag the first
  # time `@predicate` matches. The inherited `visit` short-circuits
  # the walk once a hit lands so the rest of the AST stays untouched.
  class BoolFlagVisitor < Crystal::Visitor
    property found = false

    def initialize(@predicate : Crystal::ASTNode -> Bool)
    end

    def visit(node : Crystal::ASTNode) : Bool
      return false if @found
      if @predicate.call(node)
        @found = true
        return false
      end
      true
    end

    # Walks `node` and returns whether any visit matched. Use this
    # one-shot factory instead of subclassing.
    def self.found_in?(node : Crystal::ASTNode, &predicate : Crystal::ASTNode -> Bool) : Bool
      visitor = new(predicate)
      node.accept(visitor)
      visitor.found
    end
  end
end
