require "../../program"

# JIT-side additions to `Crystal::Program`. The `@repl_state` field
# and `enable_repl_state!` moved to `program.cr` so AOT builds run
# under `--embed-compiler` can flip the same gates. The symbol-cache
# below stays JIT-only because no AOT path uses it.

module Crystal
  class Program
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
