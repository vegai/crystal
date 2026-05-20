require "../../semantic/cleanup_transformer"

# JIT-only extensions to `CleanupTransformer`. Kept here (not in
# `semantic/cleanup_transformer.cr`) so the AOT semantic surface stays
# free of REPL-shaped entry points; the JIT REPL is the sole caller.

module Crystal
  class CleanupTransformer
    # Forces a JIT submission's cleanup walk to re-visit bodies a prior
    # submission already transformed; new virtual-call instantiations
    # may have appended un-transformed target_defs to those bodies.
    def reset_transformed_for_dirty_submission : Nil
      @transformed = Set(Def).new.compare_by_identity
    end

    # Catches `ExpandableNode`s the AST-driven cleanup walk no longer
    # reaches after a JIT dirty submission. `on_new_subclass`
    # recalculation can instantiate typed_defs inside cached parent
    # bodies that the walk skips, leaving unreplaced `MacroExpression`s
    # that codegen would BUG on.
    def sweep_typed_def_bodies(types : Iterator(Type) | Enumerable(Type)) : Nil
      @transformed = Set(Def).new.compare_by_identity
      visited = Set(Type).new.compare_by_identity
      types.each do |type|
        sweep_type(type, visited)
      end
    end

    private def sweep_type(type : Type, visited : Set(Type)) : Nil
      return unless visited.add?(type)
      if type.is_a?(DefInstanceContainer)
        type.def_instances.each_value do |typed_def|
          finder = ResidualExpandableFinder.new
          typed_def.body.accept(finder)
          next unless finder.found?
          typed_def.body = typed_def.body.transform(self)
        end
      end
      type.types?.try &.each_value do |child|
        sweep_type(child, visited)
      end
      if type.is_a?(GenericType)
        type.each_instantiated_type do |instance|
          sweep_type(instance, visited)
        end
      end
      if type.is_a?(ModuleType)
        mc = type.metaclass
        sweep_type(mc, visited) unless mc == type
      end
      # Virtual types (`Foo+`) and their metaclasses carry their own
      # `def_instances` populated by virtual-dispatch instantiation.
      # Force-create-via-getter is harmless: each base type's lazy
      # `@virtual_type` slot is single-shot.
      if type.is_a?(ClassType)
        vt = type.virtual_type
        sweep_type(vt, visited) if vt != type && vt.is_a?(Type)
      end
    end

    # Detects any `ExpandableNode` left in an AST, regardless of
    # whether its `.expanded` slot is set. `cleanup_transformer` is
    # supposed to replace these in place, so a survivor means a
    # `Def#body` still needs to be transformed.
    class ResidualExpandableFinder < Visitor
      getter? found = false

      def visit(node : ExpandableNode) : Bool
        @found = true
        false
      end

      def visit(node : ASTNode) : Bool
        !@found
      end
    end
  end
end
