module Crystal::JIT
  # Drains per-submission dispatch-slot fixups queued on `ReplState` and
  # repoints each slot at its newly-materialised target. The release
  # store pairs with the acquire load `repl_promote_to_dispatch` emits
  # at each call site (see `codegen/fun.cr`).
  class DispatchSlotUpdater
    def initialize(@lljit : LLVM::Orc::LLJIT)
    end

    def apply_pending(repl_state : Crystal::ReplState) : Nil
      apply_pending_slot_updates(repl_state)
      apply_pending_symbol_table_update(repl_state)
    end

    private def apply_pending_symbol_table_update(repl_state : Crystal::ReplState) : Nil
      update = repl_state.take_symbol_table_update
      return unless update
      repoint_slot(*update)
    end

    private def apply_pending_slot_updates(repl_state : Crystal::ReplState) : Nil
      repl_state.drain_slot_updates do |slot_name, body_name|
        repoint_slot(slot_name, body_name)
      end
    end

    private def repoint_slot(slot_name : String, target_name : String) : Nil
      slot_addr = @lljit.lookup(slot_name)
      target_addr = @lljit.lookup(target_name)
      ::Atomic::Ops.store(slot_addr.as(Pointer(Void*)), target_addr, :release, true)
    end
  end
end
