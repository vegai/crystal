module Crystal::JIT
  # Minimal shim providing the subset of the bytecode `Crystal::Repl::Context`
  # API that the interpreter spec helpers reach for: `program` and
  # `type_id(type)`. The latter assigns sequential integers to Types in the
  # order they are first requested, matching the bytecode VM's semantics so
  # spec equality checks compare like-for-like.
  class Context
    getter program : Crystal::Program

    def initialize(@program : Crystal::Program)
    end

    def type_id(type : Crystal::Type) : Int32
      @program.llvm_id.type_id(type)
    end

    def type_from_id(id : Int32) : Crystal::Type?
      @program.llvm_id.type_from_id(id)
    end

    # JIT has no shared loader; `Session` owns its own.
    def loader? : Crystal::Loader?
      nil
    end
  end
end
