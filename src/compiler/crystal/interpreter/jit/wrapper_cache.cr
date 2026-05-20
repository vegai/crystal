module Crystal::JIT
  # Bounded insertion-ordered map keyed by source string. `[]?`,
  # `put`, and `touch` all move the looked-up entry to the back so
  # the eviction policy is true LRU. 256-entry cap covers a typical
  # interactive session; a paste-heavy or test-driver loop reaching
  # the cap drops the oldest entry per insert.
  class WrapperCache
    LIMIT = 256

    def initialize
      @entries = {} of String => Session::CompiledWrapper
    end

    def []?(code : String) : Session::CompiledWrapper?
      entry = @entries.delete(code)
      return nil unless entry
      @entries[code] = entry
      entry
    end

    def put(code : String, wrapper : Session::CompiledWrapper) : Nil
      @entries.delete(code)
      @entries.shift if @entries.size >= LIMIT
      @entries[code] = wrapper
    end

    def clear : Nil
      @entries.clear
    end
  end
end
