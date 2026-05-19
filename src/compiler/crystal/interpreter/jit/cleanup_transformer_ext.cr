require "../../semantic/cleanup_transformer"

# JIT-only extensions to `CleanupTransformer`. Kept here (not in
# `semantic/cleanup_transformer.cr`) so the AOT semantic surface stays
# free of REPL-shaped entry points; the JIT REPL is the sole caller.

module Crystal
  class CleanupTransformer
    # Drops the per-instance `@transformed` set so that bodies a prior
    # cleanup invocation already walked are re-walked. The JIT REPL
    # uses this when a type-graph-changing submission may have grown
    # virtual-call target_defs that the prior walk's parent typed_defs
    # still reach through Calls whose `target_defs` arrays now include
    # newly instantiated, un-transformed entries. Idempotent on bodies
    # whose `ExpandableNode`s were already replaced.
    def reset_transformed_for_dirty_submission : Nil
      @transformed = Set(Def).new.compare_by_identity
    end

    # Scans every `def_instance` in the type graph and transforms any
    # body whose AST still carries an `ExpandableNode` that has not
    # been replaced with its `.expanded` form. Used by the JIT REPL
    # after a dirty submission: `on_new_subclass` recalculation can
    # instantiate typed_defs deep inside cached parent bodies that
    # the AST-driven cleanup walk no longer reaches, so the post-walk
    # codegen would BUG on the unreplaced `MacroExpression`s.
    # Independent invocation; resets `@transformed` so each body's
    # transform is idempotent and stops only at the `@transformed`
    # cycle detection.
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
