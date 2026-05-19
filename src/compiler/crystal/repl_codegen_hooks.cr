require "./repl_state"

module Crystal
  # Codegen-side facade over `ReplState`. The Null-object subclass keeps
  # AOT call sites guard-free; the active subclass forwards to the
  # per-session state. Without this, every REPL-aware codegen site needed
  # an `if (rs = @program.repl_state?) && rs.foo(...)` gate that mixed
  # the dispatch decision with the state lookup.
  abstract class ReplCodegenHooks
    # Returns the right subclass for `program` so callers don't repeat
    # the nil check at every CodeGenVisitor allocation.
    def self.for(program : Program, repl_mode : Bool) : ReplCodegenHooks
      if repl_mode
        state = program.repl_state? || raise "BUG: repl_mode codegen requires Program#enable_repl_state!"
        Active.new(state)
      else
        Noop.new
      end
    end

    abstract def repl_mode? : Bool
    abstract def const_reinit_pending?(const : Const) : Bool
    abstract def external_emitted?(object_id : UInt64) : Bool
    abstract def mark_external_emitted(object_id : UInt64) : Nil
    abstract def target_def_emitted?(object_id : UInt64) : Bool
    abstract def mark_target_def_emitted(object_id : UInt64) : Nil
    abstract def global_emitted?(name : String) : Bool
    abstract def mark_global_emitted(name : String) : Nil
    abstract def mark_const_global_emitted(name : String) : Nil
    abstract def record_root_global(name : String, size : Int32) : Nil
    abstract def proc_literal_name?(def_id : UInt64) : String?
    abstract def record_proc_literal_name(def_id : UInt64, name : String) : Nil
    abstract def register_instantiated_flag(name : String) : Nil
    abstract def queue_slot_update(slot : String, body : String) : Nil
    abstract def queue_symbol_table_update(slot : String, table : String) : Nil
    abstract def emitted_stub_version?(canonical : String) : Int32?
    abstract def set_emitted_stub_version(canonical : String, version : Int32) : Nil
    abstract def bump_symbol_table_version : Int32

    class Noop < ReplCodegenHooks
      def repl_mode? : Bool
        false
      end

      def const_reinit_pending?(const : Const) : Bool
        false
      end

      def external_emitted?(object_id : UInt64) : Bool
        false
      end

      def mark_external_emitted(object_id : UInt64) : Nil
      end

      def target_def_emitted?(object_id : UInt64) : Bool
        false
      end

      def mark_target_def_emitted(object_id : UInt64) : Nil
      end

      def global_emitted?(name : String) : Bool
        false
      end

      def mark_global_emitted(name : String) : Nil
      end

      def mark_const_global_emitted(name : String) : Nil
      end

      def record_root_global(name : String, size : Int32) : Nil
      end

      def proc_literal_name?(def_id : UInt64) : String?
        nil
      end

      def record_proc_literal_name(def_id : UInt64, name : String) : Nil
      end

      def register_instantiated_flag(name : String) : Nil
      end

      def queue_slot_update(slot : String, body : String) : Nil
      end

      def queue_symbol_table_update(slot : String, table : String) : Nil
      end

      def emitted_stub_version?(canonical : String) : Int32?
        nil
      end

      def set_emitted_stub_version(canonical : String, version : Int32) : Nil
      end

      def bump_symbol_table_version : Int32
        raise "BUG: AOT codegen should not version the symbol table"
      end
    end

    class Active < ReplCodegenHooks
      def initialize(@state : ReplState)
      end

      def repl_mode? : Bool
        true
      end

      def const_reinit_pending?(const : Const) : Bool
        @state.const_reinit_pending?(const)
      end

      def external_emitted?(object_id : UInt64) : Bool
        @state.external_emitted?(object_id)
      end

      def mark_external_emitted(object_id : UInt64) : Nil
        @state.mark_external_emitted(object_id)
      end

      def target_def_emitted?(object_id : UInt64) : Bool
        @state.target_def_emitted?(object_id)
      end

      def mark_target_def_emitted(object_id : UInt64) : Nil
        @state.mark_target_def_emitted(object_id)
      end

      def global_emitted?(name : String) : Bool
        @state.global_emitted?(name)
      end

      def mark_global_emitted(name : String) : Nil
        @state.mark_global_emitted(name)
      end

      def mark_const_global_emitted(name : String) : Nil
        @state.mark_const_global_emitted(name)
      end

      def record_root_global(name : String, size : Int32) : Nil
        @state.record_root_global(name, size)
      end

      def proc_literal_name?(def_id : UInt64) : String?
        @state.proc_literal_name?(def_id)
      end

      def record_proc_literal_name(def_id : UInt64, name : String) : Nil
        @state.record_proc_literal_name(def_id, name)
      end

      def register_instantiated_flag(name : String) : Nil
        @state.register_instantiated_flag(name)
      end

      def queue_slot_update(slot : String, body : String) : Nil
        @state.queue_slot_update(slot, body)
      end

      def queue_symbol_table_update(slot : String, table : String) : Nil
        @state.queue_symbol_table_update(slot, table)
      end

      def emitted_stub_version?(canonical : String) : Int32?
        @state.emitted_stub_version?(canonical)
      end

      def set_emitted_stub_version(canonical : String, version : Int32) : Nil
        @state.set_emitted_stub_version(canonical, version)
      end

      def bump_symbol_table_version : Int32
        @state.bump_symbol_table_version
      end
    end
  end
end
