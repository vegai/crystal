module Crystal
  # Per-session state for the JIT REPL. AOT codegen leaves it nil.
  class ReplState
    # target_defs / FunDefs / module globals emitted by a prior
    # submission; later submissions declare them extern.
    getter emitted_target_defs = Set(UInt64).new
    getter emitted_externals = Set(UInt64).new
    getter emitted_globals = Set(String).new
    property submission_id : Int32 = 0

    def mark_target_def_emitted(id : UInt64) : Nil
      @emitted_target_defs << id
    end

    def target_def_emitted?(id : UInt64) : Bool
      @emitted_target_defs.includes?(id)
    end

    def mark_external_emitted(id : UInt64) : Nil
      @emitted_externals << id
    end

    def external_emitted?(id : UInt64) : Bool
      @emitted_externals.includes?(id)
    end

    def mark_global_emitted(name : String) : Nil
      @emitted_globals << name
    end

    def global_emitted?(name : String) : Bool
      @emitted_globals.includes?(name)
    end

    # Stable mangled name per `ProcLiteral`'s `Def` across multidispatch
    # re-visits in one submission. Cleared at the start of each `compile`.
    getter proc_literal_names = {} of UInt64 => String

    def record_proc_literal_name(def_id : UInt64, name : String) : Nil
      @proc_literal_names[def_id] = name
    end

    def proc_literal_name?(def_id : UInt64) : String?
      @proc_literal_names[def_id]?
    end

    def clear_proc_literal_names : Nil
      @proc_literal_names.clear
    end

    # Hot-reload dispatch: `emitted_stubs[canonical] = version_count`;
    # `pending_slot_updates` queues `(slot, body)` for the next ORC pass.
    getter emitted_stubs = Hash(String, Int32).new
    getter pending_slot_updates = [] of {String, String}

    def emitted_stub_version?(canonical : String) : Int32?
      @emitted_stubs[canonical]?
    end

    def set_emitted_stub_version(canonical : String, version : Int32) : Nil
      @emitted_stubs[canonical] = version
    end

    def queue_slot_update(slot : String, body : String) : Nil
      @pending_slot_updates << {slot, body}
    end

    def drain_slot_updates(& : {String, String} ->) : Nil
      while update = @pending_slot_updates.shift?
        yield update
      end
    end

    # JIT-emitted const globals registered with Boehm so GC traces them;
    # `{mangled_name => byte_size}` for `GC_add_roots`.
    getter emitted_root_globals = Hash(String, Int32).new

    def record_root_global(name : String, size : Int32) : Nil
      @emitted_root_globals[name] = size unless @emitted_root_globals.has_key?(name)
    end

    # `Const`s whose `.value` AST was replaced in the current
    # submission; codegen_assign(Path) drains and re-evaluates each.
    # Keyed on `object_id` to match the neighbouring emitted_* sets.
    getter pending_const_reinits = Set(UInt64).new

    def queue_const_reinit(const : Const) : Nil
      @pending_const_reinits << const.object_id
    end

    def const_reinit_pending?(const : Const) : Bool
      @pending_const_reinits.includes?(const.object_id)
    end

    def clear_pending_const_reinits : Nil
      @pending_const_reinits.clear
    end

    # Reset per-submission state before `Session#compile` begins a new
    # walk. Bundling lets future state additions register here without
    # touching `Session#compile`.
    def begin_submission! : Nil
      clear_pending_const_reinits
      clear_proc_literal_names
    end

    # Mirrors `emitted_globals` for const globals.
    getter emitted_const_globals = Set(String).new

    def mark_const_global_emitted(name : String) : Nil
      @emitted_const_globals << name
    end

    # Per-class `:instantiated` flag names; `Session` reads them to
    # refuse layout-changing redefs of types with live instances.
    getter emitted_instantiated_flags = Set(String).new

    def register_instantiated_flag(name : String) : Nil
      @emitted_instantiated_flags << name
    end

    def flag_registered?(name : String) : Bool
      @emitted_instantiated_flags.includes?(name)
    end

    # `:symbol_table` versioned per submission; `Symbol#to_s` reads
    # through `:symbol_table:slot`. `Session` repoints the slot after
    # each `add_llvm_ir_module`.
    property symbol_table_version : Int32 = 0
    getter pending_symbol_table_update : {String, String}? = nil

    def bump_symbol_table_version : Int32
      @symbol_table_version += 1
    end

    def queue_symbol_table_update(slot : String, table : String) : Nil
      @pending_symbol_table_update = {slot, table}
    end

    def take_symbol_table_update : {String, String}?
      update = @pending_symbol_table_update
      @pending_symbol_table_update = nil
      update
    end
  end
end
