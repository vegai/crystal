require "../repl_reader"

module Crystal::JIT
  # Minimal subclass of the bytecode REPL's `Crystal::ReplReader` so
  # the JIT prompt gets history, in-line cursor editing, multi-line
  # input with autoindent, paste handling, and `Reply::Reader`'s other
  # affordances. The bytecode reader carries scope info from a
  # `Crystal::Repl` instance via its `@repl` field; we leave that nil
  # so the continuation-detection parser uses default scopes. That
  # only affects the multi-line `continue?` heuristic - the actual
  # parse + JIT compile still goes through `Repl#run_snippet`, which
  # has the full program string-pool.
  class ReplReader < ::Crystal::ReplReader
    @session : Session?

    def initialize(@session : Session? = nil)
      super(repl: nil)
    end

    def prompt(io : IO, line_number : Int32, color : Bool) : Nil
      io << "jit:"
      io << line_number
      io.print(@incomplete ? '*' : '>')
      io << ' '
    end

    # Tab-complete keywords (as the bytecode `ReplReader` does) plus
    # user-introduced names from the active Session. Method-shape
    # completions (`.foo`) still fall through to the upstream
    # `METHOD_KEYWORDS` list - walking `Program#defs` for prefix matches
    # on every Tab would return thousands of prelude method names with
    # no useful ranking.
    #
    # Tab during the background warmup falls back to keyword-only
    # matches: the warmup thread may be mutating `@program.types` (or
    # other shared semantic state once approach A lands) and a
    # concurrent Hash walk in `repl_method_names_matching` would race.
    def auto_complete(name_filter : String, expression : String) : {String, Array(String)}
      if expression.ends_with? '.'
        return "Keywords:", METHOD_KEYWORDS.dup
      end

      keyword_matches = KEYWORDS.select { |kw| kw.starts_with?(name_filter) }
      session = @session
      gate_open = session ? session.warmup_done? : true
      local_matches = (session && gate_open) ? session.repl_locals_matching(name_filter) : [] of String
      method_matches = (session && gate_open) ? session.repl_method_names_matching(name_filter) : [] of String

      user_matches = (local_matches + method_matches).sort!.uniq!

      if user_matches.empty?
        {"Keywords:", keyword_matches}
      elsif keyword_matches.empty?
        heading =
          if local_matches.empty?
            "Methods:"
          elsif method_matches.empty?
            "Locals:"
          else
            "Locals + methods:"
          end
        {heading, user_matches}
      else
        {"User + keywords:", user_matches + keyword_matches}
      end
    end

    # Persist input history across REPL sessions in
    # `$XDG_DATA_HOME/crystal/jit_repl_history` (falling back to
    # `~/.local/share/crystal/jit_repl_history`). `Reply::Reader`
    # reads from `history_file` at start, appends on each accepted
    # expression, and trims to `History#max_size` entries. Same
    # interactive affordances as the bytecode REPL would have if
    # opt-in - only the path differs so the two prompts don't share
    # state.
    def history_file : Path | String | IO | Nil
      base = ENV["XDG_DATA_HOME"]?.presence || begin
        if home = ENV["HOME"]?.presence
          File.join(home, ".local", "share")
        end
      end
      return nil unless base
      dir = File.join(base, "crystal")
      begin
        Dir.mkdir_p(dir)
      rescue File::Error
        return nil
      end
      File.join(dir, "jit_repl_history")
    end
  end
end
