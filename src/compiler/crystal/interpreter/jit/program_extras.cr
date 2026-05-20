require "../../program"

# JIT-side additions to `Crystal::Program`. Kept out of `program.cr` so
# AOT builds carry neither the field nor the symbol-cache.

module Crystal
  class Program
    @repl_state : ReplState? = nil

    def repl_state? : ReplState?
      @repl_state
    end

    def enable_repl_state! : ReplState
      @repl_state ||= ReplState.new
    end

    @symbols_array_cache : Array(String)?
    @symbols_array_cache_size : Int32 = 0

    # `symbols.to_a` cached for `Crystal::JIT::Value`'s per-result
    # symbol lookup. `Set` is append-only here, so size suffices to
    # invalidate; swap for a generation counter if that ever changes.
    def symbol_at?(id : Int32) : String?
      cache = @symbols_array_cache
      if cache.nil? || @symbols_array_cache_size != symbols.size
        cache = symbols.to_a
        @symbols_array_cache = cache
        @symbols_array_cache_size = cache.size
      end
      cache[id]?
    end
  end
end
