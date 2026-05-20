module Crystal::JIT
  # Process-wide pin set for live `Session`s. LLVM teardown must happen
  # on the main thread (a Boehm finalizer thread can't safely dispose
  # LLJIT), so `Repl#finalize` cannot tear down the Session directly.
  # Callers walk this list explicitly — typically specs via
  # `SpecSupport.dispose_all_sessions` and the `at_exit` drain armed on
  # first registration.
  module SessionRegistry
    extend self

    @@alive = [] of Session
    @@at_exit_installed = false

    def register(session : Session) : Nil
      @@alive << session
      ensure_at_exit_drain
    end

    def unregister(session : Session) : Nil
      @@alive.delete(session)
    end

    def each_alive(&block : Session ->) : Nil
      @@alive.dup.each(&block)
    end

    # Arms (once) a host-side `at_exit` that disposes any Session still
    # pinned. Closes the interactive-only-clean-exit gap so a process exit
    # without explicit `Repl#reset` still tears down JIT pages on the main
    # thread (where LLVM teardown is safe).
    private def ensure_at_exit_drain : Nil
      return if @@at_exit_installed
      @@at_exit_installed = true
      ::at_exit do
        @@alive.dup.each do |session|
          begin
            session.dispose
          rescue ex
            # Best-effort drain: a failure here only matters during dev,
            # since the process is exiting anyway. Surface it so a real
            # bug isn't silently swallowed.
            STDERR.puts "Crystal::JIT::Session at_exit dispose failed: #{ex.class}: #{ex.message}"
          end
        end
      end
    end
  end
end
