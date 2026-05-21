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
      slot_addr = lookup_slot_address(slot_name)
      target_addr = @lljit.lookup(target_name)
      ::Atomic::Ops.store(slot_addr.as(Pointer(Void*)), target_addr, :release, true)
    end

    # Slots live in two places under `--embed-compiler`: AOT-emitted
    # globals from the host's link-time and JIT-emitted globals from
    # later loaded modules. AOT-side slots are exposed to `dlsym` via
    # `-rdynamic`; trying `dlsym(RTLD_DEFAULT, ...)` first finds those,
    # and the LLJIT fallback covers slots created by previous loads.
    # On normal JIT REPL builds the AOT lookup will simply return null
    # for every slot and we go straight to the LLJIT path.
    private def lookup_slot_address(slot_name : String) : Void*
      aot = LibC.dlsym(LibC::RTLD_DEFAULT, slot_name)
      return aot unless aot.null?
      @lljit.lookup(slot_name)
    end
  end
end
