module Crystal::JIT
  class Repl
    property prelude : String = "prelude"
    getter program : Program
    getter context : Context
    # Extra `[source, filename]` pairs appended to the prelude AST.
    # Spec harness uses this to stub runtime helpers without shifting
    # the user code's `__LINE__`.
    getter prelude_extra : Array({String, String}) = [] of {String, String}

    @prelude_ast : ASTNode? = nil
    @wrapper_cache : Hash(String, Session::CompiledWrapper) = {} of String => Session::CompiledWrapper
    @submission_count : Int32 = 0
    @prelude_semantic_in_progress : Bool = false
    @session_initialized : Bool = false

    def initialize
      @program = Program.new
      configure_program_for_jit
      @session = Session.new(@program)
      @context = Context.new(@program)
    end

    # Resets the Repl to a pristine state. Next submission re-loads
    # the prelude from scratch.
    def reset : Nil
      @session.dispose
      @program = Program.new
      configure_program_for_jit
      @session = Session.new(@program)
      @context = Context.new(@program)
      @prelude_ast = nil
      @wrapper_cache.clear
      @session_initialized = false
      @submission_count = 0
      @prelude_semantic_in_progress = false
    end

    private def configure_program_for_jit
      # Dual-use of Program#flags: macros in the user prelude (kernel.cr,
      # event_loop.cr, signal.cr) check `{% if flag?(...) %}` against the
      # user program's flag set, not the host compiler's, so setting the
      # flag here disables host-side signal installation inside JIT code.
      @program.flags << "host_signal_handlers_already_installed"
    end

    # Runs on a Boehm finalizer thread, which forbids mutex acquisition.
    # `unregister_gc_roots` is `LibGC.remove_roots`, documented safe from
    # finalizers; the signal bridge is left in place because clearing it
    # would lock `SignalChildHandler.@@mutex`. Full teardown (including
    # the bridge) lives in `Session#dispose`.
    def finalize
      @session.unregister_gc_roots
    end

    def run : Nil
      # The prompt appears immediately while the prelude compiles on
      # a dedicated thread (`Fiber::ExecutionContext::Isolated`). The
      # first `run_snippet` call blocks on `@warmup` if the user beats
      # the warmup to the keyboard; subsequent submissions are free.
      reader = ReplReader.new(session: @session)
      reader.color = @program.color?
      kick_off_warmup unless @session_initialized

      reader.read_loop do |expression|
        case expression
        when "exit"
          break
        when "exit!"
          Process.exit(0)
        when .presence
          wait_for_warmup
          run_snippet(expression)
        end
      end
    end

    {% if flag?(:execution_context) %}
      @warmup : Fiber::ExecutionContext::Isolated? = nil

      # `CRYSTAL_JIT_SYNCHRONOUS_WARMUP=1` forces the synchronous fallback
      # so a user diagnosing an interactive crash can rule out the
      # threaded Isolated path without a rebuild.
      private def kick_off_warmup : Nil
        if ENV["CRYSTAL_JIT_SYNCHRONOUS_WARMUP"]? == "1"
          synchronous_warmup
          return
        end
        return if @warmup
        @session.mark_warmup_started
        @warmup = Fiber::ExecutionContext::Isolated.new("jit-warmup") do
          prepare_session
        ensure
          @session.mark_warmup_done
        end
      end

      private def wait_for_warmup : Nil
        ctx = @warmup
        return unless ctx
        ctx.wait if ctx.running?
        @warmup = nil
      end
    {% else %}
      private def kick_off_warmup : Nil
        synchronous_warmup
      end

      private def wait_for_warmup : Nil
      end
    {% end %}

    private def synchronous_warmup : Nil
      @session.mark_warmup_started
      prepare_session
    ensure
      @session.mark_warmup_done
    end

    # Background-warmup work: parse and semantic-walk the prelude so
    # the first user submission only pays codegen. Idempotent.
    def prepare_session : Nil
      return if @session_initialized
      prelude_ast = cached_prelude_ast
      @session.walk_prelude_for_warmup(prelude_ast)
    end

    # One-shot eval for `crystal i --backend=jit -e SOURCE`. Wraps the
    # input in a JIT-internal rescue that prints `Unhandled exception: ...`
    # and `LibC.exit(1)`s so unwinds never cross back to the host.
    # Returns the exit code the caller should pass to `Process.exit`.
    def run_eval_source(source : String) : Int32
      with_rescue(error_value: 1) do
        input_node = parse_code(source, "(jit-eval)")
        input_node = RedefForce.inject(input_node, @program)
        input_node = @session.wrap_in_repl_state(input_node)
        input_node = @session.wrap_runtime_with_rescue(input_node, eval_source_rescue_handler)
        compile_and_run_input(input_node)
        mark_submission_compiled
        0
      end
    end

    # Sets the JIT-side `ARGV` for this Repl. Must be called before the
    # first submission; the argv buffer is captured into prelude
    # constants on init.
    def set_program_args(args : Array(String)) : Nil
      if @submission_count > 0
        raise "Crystal::JIT::Repl#set_program_args must be called before the first submission"
      end
      # Session#initialize already installed ["jit"]; skip the rebuild
      # when the caller has nothing to add.
      return if args.empty?
      @session.install_program_args(["jit"] + args)
    end

    def run_code(code : String) : Value
      @submission_count += 1
      input_node = parse_code(code, "(jit)")
      # Method-defining input may be a hot redef; clear the wrapper
      # cache so call sites recompile against the new dispatch slot.
      if BoolFlagVisitor.found_in?(input_node) { |n| AstShape.defines_value?(n) }
        @wrapper_cache.clear
        input_node = RedefForce.inject(input_node, @program)
      elsif cached = @wrapper_cache[code]?
        return @session.invoke(cached)
      end

      wrapper = compile_input(input_node)
      mark_submission_compiled
      @wrapper_cache[code] = wrapper
      @session.invoke(wrapper)
    rescue ex
      reset_on_pre_success_error
      raise ex
    end

    def run_file(filename : String, argv : Array(String)) : Int32
      with_rescue(error_value: 1) do
        set_program_args(argv)
        file_node = FileNode.new(parse_file(filename), filename)
        compile_and_run_input(file_node)
        mark_submission_compiled
        0
      end
    end

    # Spec-facing entry into `run_snippet` without going through TTY.
    def run_snippet_for_spec(line : String) : Nil
      run_snippet(line)
    end

    # Like `run_snippet_for_spec` but captures the inspect string of
    # the last expression so specs can assert on it without scraping
    # STDOUT.
    def eval_for_spec(line : String) : Value
      input_node = parse_code(line, "(jit-eval)")
      input_node = RedefForce.inject(input_node, @program)
      input_node = ResultCapture.wrap_for_value(input_node)
      input_node = @session.wrap_in_repl_state(input_node)
      # `__REPLState` has nil value; tack a top-level getter call so the
      # wrapper's last expression is the captured value.
      reader = Call.new(Path.new("__REPLState"), ResultCapture::EVAL_HOLDER_GETTER_NAME)
      eval_program = Expressions.new([input_node.as(ASTNode), reader.as(ASTNode)])
      value = compile_and_run_input(eval_program)
      mark_submission_compiled
      value
    rescue ex
      reset_on_pre_success_error
      raise ex
    end

    private def run_snippet(line : String) : Nil
      with_rescue(error_value: nil) do
        input_node = parse_code(line, "(jit-repl)")
        input_node = RedefForce.inject(input_node, @program)
        input_node = ResultCapture.wrap(input_node)
        # JIT-internal rescue keeps the unwind off the host's type_id tables.
        input_node = @session.wrap_in_repl_state(input_node)
        input_node = @session.wrap_runtime_with_rescue(input_node, repl_rescue_handler)
        compile_and_run_input(input_node)
        mark_submission_compiled
      end
    end

    private def repl_rescue_handler : ASTNode -> ASTNode
      ->(n : ASTNode) : ASTNode { build_rescue_handler(n) }
    end

    private def eval_source_rescue_handler : ASTNode -> ASTNode
      ->(n : ASTNode) : ASTNode { build_rescue_handler(n, prefix: "Unhandled exception: ", exit_on_error: true) }
    end

    # Wraps a submission body in the JIT's standard CodeError /
    # LayoutChangeRefused rescues. Returns the block's value on success
    # and `error_value` (caller-typed: `1`, `0`, or `nil`) on either
    # rescue.
    private def with_rescue(error_value : T, & : -> T) : T forall T
      yield
    rescue ex : Crystal::CodeError
      report_code_error(ex)
      error_value
    rescue ex : Session::LayoutChangeRefused
      report_layout_refused(ex)
      error_value
    end

    private def report_code_error(ex : Crystal::CodeError) : Nil
      ex.color = @program.color?
      ex.error_trace = true
      STDERR.puts ex
      reset_on_pre_success_error
    end

    private def report_layout_refused(ex : Session::LayoutChangeRefused) : Nil
      STDERR.puts "Error: #{ex.message}"
      reset_on_pre_success_error
    end

    private def build_rescue_handler(node : ASTNode, prefix : String = "Error: ", exit_on_error : Bool = false) : ASTNode
      loc = Location.new("(jit-rescue)", 1, 1)
      err_name = "__jit_repl_err"
      err_var = Var.new(err_name).at(loc)
      class_call = Call.new(err_var.clone.at(loc).as(ASTNode), "class").at(loc)
      msg_call = Call.new(err_var.clone.at(loc).as(ASTNode), "message").at(loc)
      full = StringInterpolation.new([
        StringLiteral.new(prefix).at(loc).as(ASTNode),
        msg_call.as(ASTNode),
        StringLiteral.new(" (").at(loc).as(ASTNode),
        class_call.as(ASTNode),
        StringLiteral.new(")").at(loc).as(ASTNode),
      ]).at(loc)
      puts_call = Call.new(Path.new("STDERR").at(loc).as(ASTNode), "puts", [full.as(ASTNode)]).at(loc)
      rescue_body =
        if exit_on_error
          exit_call = Call.new(Path.new("LibC").at(loc).as(ASTNode), "exit", [NumberLiteral.new("1", :i32).at(loc).as(ASTNode)]).at(loc)
          Expressions.new([puts_call.as(ASTNode), exit_call.as(ASTNode)])
        else
          puts_call
        end
      rescue_node = Rescue.new(rescue_body, nil, err_name).at(loc)
      ExceptionHandler.new(node, [rescue_node]).at(loc)
    end

    # Dispatch for the per-submission compile. On the first submission,
    # the warmup may have left a typed prelude AST in the Session; if
    # so, we walk only the input and bundle the two for codegen.
    # Otherwise we fall back to `bundle_submission`, which walks
    # `[prelude, input]` together (slower first command but the legacy
    # path approach B has not yet displaced).
    private def compile_input(input : ASTNode) : Session::CompiledWrapper
      if !@session_initialized && (walked = @session.take_walked_prelude)
        @session_initialized = true
        @prelude_semantic_in_progress = true
        return @session.compile_with_walked_prelude(walked, input)
      end
      node, well_known = bundle_submission(input)
      @session.compile(node, well_known_source: well_known)
    end

    private def compile_and_run_input(input : ASTNode) : Value
      @session.invoke(compile_input(input))
    end

    # Returns `(node, well_known_source)` to feed to `Session#compile{,_and_run}`.
    # On the first submission this bundles `[prelude, input]` and arms
    # `@prelude_semantic_in_progress` so a failure during the bundled
    # semantic walk triggers `reset_on_pre_success_error`. Callers clear
    # the flag with `mark_submission_compiled` after a successful return.
    private def bundle_submission(input_node : ASTNode) : {ASTNode, ASTNode?}
      prelude_node = cached_prelude_ast
      return {input_node, prelude_node} if @session_initialized
      @session_initialized = true
      @prelude_semantic_in_progress = true
      {Expressions.new([prelude_node, input_node] of ASTNode), nil}
    end

    private def mark_submission_compiled : Nil
      @prelude_semantic_in_progress = false
    end

    private def reset_on_pre_success_error
      return unless @prelude_semantic_in_progress
      reset
      STDERR.puts "[jit: session reset]"
      # Re-prep the fresh session so the user's next interactive
      # command doesn't pay the bundled-prelude cost a second time.
      prepare_session
    end

    private def cached_prelude_ast : ASTNode
      @prelude_ast ||= parse_prelude
    end

    # Per-prelude-name defaults (always applied for that prelude).
    # Per-instance additions go via `prelude_extra` and append on top.
    PRELUDE_EXTRAS = begin
      h = {} of String => Array({String, String})
      h["primitives"] = [{EXCEPTION_RUNTIME_SOURCE, "(jit-exception-runtime)"}]
      {% if flag?(:unix) %}
        h["prelude"] = [{JIT_SIGCHLD_BRIDGE_SOURCE, "(jit-sigchld-bridge)"}]
      {% end %}
      h
    end

    private def parse_prelude : ASTNode
      filenames = @program.find_in_path(prelude)
      parsed_nodes = filenames.not_nil!.map { |filename| parse_file(filename) }
      PRELUDE_EXTRAS[prelude]?.try &.each do |source, filename|
        parsed_nodes << parse_code(source, filename)
      end
      @prelude_extra.each do |source, filename|
        parsed_nodes << parse_code(source, filename)
      end
      Expressions.new(parsed_nodes)
    end

    private def parse_file(filename : String) : ASTNode
      parse_code(File.read(filename), filename)
    end

    private def parse_code(code : String, filename : String = "") : ASTNode
      warnings = @program.warnings.dup
      warnings.infos = [] of String
      # Seed parser's outermost scope with prior-submission locals so
      # `x = x + 1` parses after a previous `x = ...`.
      var_scopes = [@session.parser_var_scope]
      parser = Parser.new(code, @program.string_pool, var_scopes: var_scopes, warnings: warnings)
      parser.filename = filename
      parsed = parser.parse
      warnings.report(STDOUT)
      @program.normalize(parsed, inside_exp: false)
    end
  end
end
