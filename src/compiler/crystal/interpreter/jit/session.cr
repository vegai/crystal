module Crystal::JIT
  class Session
    # Convenience forwarder so callers (specs, host `at_exit` hooks)
    # don't need to reach for `SessionRegistry`.
    def self.each_alive(&block : Session ->) : Nil
      SessionRegistry.each_alive(&block)
    end

    getter program : Program
    # Top-level local names seen in prior submissions. `LocalLifter` mutates.
    @repl_locals = Set(String).new
    @submission_counter = 0
    @library_loader : LibraryLoader
    getter redef_force : RedefForce = RedefForce.new
    # After `ensure_jit_initialized` runs, these are non-nil for the rest
    # of the Session's life. `getter!` lets call sites use `lljit` / `dylib`
    # / `ts_ctx` / `llvm_context` without restating the precondition.
    getter! lljit : LLVM::Orc::LLJIT
    getter! dylib : LLVM::Orc::JITDylib
    getter! ts_ctx : LLVM::Orc::ThreadSafeContext
    getter! llvm_context : LLVM::Context
    @registered_root_globals = Set(String).new
    @registered_root_ranges = [] of {Void*, Void*}
    @signal_bridge_installed = false
    @disposed = false
    @semantic_graph_clean = false
    @argv : CArgv = CArgv::EMPTY
    # Built by `ensure_jit_initialized`. Pre-init submissions can't
    # have live instances, so the call-site `try` is the natural no-op.
    @layout_guard : LayoutRefusalGuard? = nil
    getter! dispatch_updater : DispatchSlotUpdater
    # Flipped by `Repl` when the warmup thread finishes touching shared
    # state (`@program.string_pool`, types, defs). `auto_complete`'s
    # method-name lookup walks `@program.types`, so reads must be gated
    # until the warmup releases.
    @warmup_done = Atomic(Bool).new(true)
    # Set by `walk_prelude_for_warmup`; consumed once by
    # `compile_with_walked_prelude` on the first user submission so the
    # prelude's typed AST is reused instead of re-walked.
    @walked_prelude : ASTNode? = nil

    def initialize(@program : Program)
      @program.enable_repl_state!
      @main_visitor = MainVisitor.new(@program)
      @library_loader = LibraryLoader.new(@program)
      install_program_args(["jit"])
      SessionRegistry.register(self)
    end

    # `Repl#kick_off_warmup` arms this before spawning the background fiber;
    # `prepare_session` clears it when the prelude work releases shared state.
    def mark_warmup_started : Nil
      @warmup_done.set(false, :release)
    end

    def mark_warmup_done : Nil
      @warmup_done.set(true, :release)
    end

    def warmup_done? : Bool
      @warmup_done.get(:acquire)
    end

    # Guards against a future code path that constructs a `Session`
    # without going through `Repl`: such a path would skip
    # `enable_repl_state!` and the `repl_state?` access would yield nil
    # silently. The raise surfaces the missing precondition explicitly.
    private def repl_state : Crystal::ReplState
      @program.repl_state? || raise "BUG: Session lost its program-level repl_state"
    end

    def install_program_args(args : Array(String)) : Nil
      @argv = CArgv.build(args)
    end

    # Frees slots in the `MAX_ROOT_SETS`-bounded GC table. Idempotent.
    def unregister_gc_roots : Nil
      return if @registered_root_ranges.empty?
      @registered_root_ranges.each do |low, high|
        LibGC.remove_roots(low, high)
      end
      @registered_root_ranges.clear
      @registered_root_globals.clear
    end

    def uninstall_signal_bridge : Nil
      return unless @signal_bridge_installed
      Crystal::System::SignalChildHandler.external_reaper = nil
      @signal_bridge_installed = false
    end

    # User-context only: the bridge proc and Boehm root ranges capture
    # pointers into JIT memory and must be torn down before LLJIT
    # unmaps it (a finalizer thread can't safely do this).
    def dispose : Nil
      return if @disposed
      @disposed = true
      uninstall_signal_bridge
      unregister_gc_roots
      if lljit = lljit?
        lljit.dispose
        @lljit = nil
      end
      @dylib = nil
      SessionRegistry.unregister(self)
    end

    # Forwards to `ReplStateWrap` which owns the AST rewrite; this method
    # remains as the public Session entrypoint so callers (and specs)
    # don't reach across into the implementation module.
    def wrap_in_repl_state(node : ASTNode) : ASTNode
      ReplStateWrap.wrap(node, @repl_locals)
    end

    def wrap_runtime_with_rescue(node : ASTNode, handler : ASTNode -> ASTNode) : ASTNode
      ReplStateWrap.wrap_runtime_with_rescue(node, handler)
    end

    # Dup so the parser's `push_var_name` does not bleed into the lifter's set.
    def parser_var_scope : Set(String)
      @repl_locals.dup
    end

    def repl_locals_matching(prefix : String) : Array(String)
      @repl_locals.select { |name| name.starts_with?(prefix) }.to_a
    end

    # `__REPLState` metaclass methods matching `prefix`. Hides the magic
    # name from callers like tab completion. Linear scan, fine for
    # interactive autocomplete; switch to a sorted/prefix-trie store if
    # it shows up in a profile.
    def repl_method_names_matching(prefix : String) : Array(String)
      repl_module = @program.types?.try &.["__REPLState"]?
      return [] of String unless repl_module
      metaclass_defs = repl_module.metaclass.defs
      return [] of String unless metaclass_defs
      matches = [] of String
      metaclass_defs.each_key do |name|
        matches << name if name.starts_with?(prefix)
      end
      matches
    end

    # Wrapper handle returned by `compile`; re-`invoke`-able without codegen.
    # `buffer_size` is `nil` for void/Nil results; otherwise the byte count
    # the wrapper writes into a caller-supplied buffer.
    struct CompiledWrapper
      getter wrapper_ptr : Pointer(Void)
      getter result_type : Crystal::Type
      getter buffer_size : UInt32?

      def initialize(@wrapper_ptr, @result_type, @buffer_size)
      end

      def wants_value? : Bool
        !@buffer_size.nil?
      end
    end

    # Compiles `node` and invokes the resulting wrapper, returning a
    # `Value` snapshot of the last expression. Callers that only care
    # about side effects can ignore the return.
    def compile_and_run(node : ASTNode, well_known_source : ASTNode? = nil) : Value
      invoke(compile(node, well_known_source))
    end

    # Compile a submission into an invokable wrapper. Separated from
    # `invoke` so callers can cache the wrapper across re-runs.
    def compile(node : ASTNode, well_known_source : ASTNode? = nil) : CompiledWrapper
      @layout_guard.try &.check(node, repl_state)
      walked, dirty = begin_submission_walk(node)
      ensure_libs_loaded(dirty)
      run_jit(walked, well_known_source)
    end

    # Background-warmup entry: type the prelude so the first user
    # submission only pays codegen. Caches the walked AST so
    # `take_walked_prelude` can fetch it on the foreground thread. The
    # lib-load is deferred to the first user submission's
    # `compile_with_walked_prelude`.
    def walk_prelude_for_warmup(prelude_ast : ASTNode) : Nil
      walked, _ = begin_submission_walk(prelude_ast)
      @walked_prelude = walked
    end

    # Returns and clears the warmup's walked prelude AST. Nil if no
    # warmup ran or `take_walked_prelude` was already called.
    def take_walked_prelude : ASTNode?
      ast = @walked_prelude
      @walked_prelude = nil
      ast
    end

    # Like `compile` but bundles a pre-walked prelude AST with the
    # input. Only the input is semantically walked. Used on the first
    # user submission after warmup typed the prelude.
    def compile_with_walked_prelude(walked_prelude : ASTNode, input : ASTNode) : CompiledWrapper
      walked_input, dirty = begin_submission_walk(input)
      ensure_libs_loaded(dirty)
      bundle = Expressions.new([walked_prelude, walked_input] of ASTNode)
      # The bundle itself is never walked, so its `.type` would default
      # to nil and `run_jit` would treat the wrapper as void; copy the
      # input's type so the result buffer is sized correctly.
      if input_type = walked_input.type?
        bundle.type = input_type
      end
      run_jit(bundle, nil)
    end

    # Shared submission front-half: prime the visitor, mark a new
    # submission on `repl_state`, normalize, classify type-graph dirty,
    # and walk. Used by `compile`, `compile_with_walked_prelude`, and
    # `walk_prelude_for_warmup` so the four prep steps stay in lockstep.
    private def begin_submission_walk(node : ASTNode) : {ASTNode, Bool}
      @main_visitor = MainVisitor.new(from_main_visitor: @main_visitor)
      repl_state.begin_submission!
      normalized = @program.normalize(node)
      type_graph_dirty = AstShape.any_type_mutating?(normalized)
      walked = semantic_for_submission(normalized, type_graph_dirty)
      {walked, type_graph_dirty}
    end

    # First submission bootstraps; later dirty submissions pick up new
    # `@[Link]` annotations; later clean submissions are a no-op.
    private def ensure_libs_loaded(type_graph_dirty : Bool) : Nil
      if @library_loader.bootstrapped?
        @library_loader.pick_up_new_link_annotations if type_graph_dirty
      else
        @library_loader.bootstrap
      end
    end

    # Same phases as `Program#semantic`, but `AbstractDefChecker` +
    # `RecursiveStructChecker` skip when input cannot mutate the graph.
    # Worst-case false-negative is a slightly worse error, not a miscompile.
    private def semantic_for_submission(node : ASTNode, type_graph_dirty : Bool) : ASTNode
      dirty = !@semantic_graph_clean || type_graph_dirty
      node, processor = run_top_level_semantic(node, run_graph_checks: dirty)

      ivars_visitor = Crystal::InstanceVarsInitializerVisitor.new(@program)
      @program.visit_with_finished_hooks(node, ivars_visitor)
      ivars_visitor.finish

      @program.visit_class_vars_initializers(node)
      processor.check_non_nilable_class_vars_without_initializers

      # A dirty submission may have grown virtual-call target_defs on
      # bodies the previous cleanup pass already added to
      # `@transformed`. Without a reset the new (un-transformed)
      # target_defs reach codegen with `ExpandableNode`s still in
      # place; see `class.cr:115:5` BUG repros. Reset is idempotent on
      # bodies whose macros were already replaced.
      if dirty
        @program.cleanup_transformer.reset_transformed_for_dirty_submission
      end

      result = @program.visit_main(node, process_finished_hooks: true, cleanup: true, visitor: @main_visitor)
      @program.cleanup_types
      @program.cleanup_files
      # `on_new_subclass` recalculation during a dirty submission can
      # leave typed_defs deep in cached parent bodies whose
      # `MacroExpression`s the AST-driven cleanup walk did not reach.
      # Sweep all `def_instances` to catch them before codegen.
      if dirty
        @program.cleanup_transformer.sweep_typed_def_bodies(@program.types.each_value)
      end
      Crystal::RecursiveStructChecker.new(@program).run if dirty
      @semantic_graph_clean = true
      result
    end

    private def run_top_level_semantic(node : ASTNode, run_graph_checks : Bool) : {ASTNode, Crystal::TypeDeclarationProcessor}
      visitor = Crystal::TopLevelVisitor.new(@program)
      visitor.vars = @main_visitor.vars.dup unless @main_visitor.vars.empty?
      node.accept visitor
      visitor.process_finished_hooks
      new_expansions = visitor.new_expansions
      @program.define_new_methods(new_expansions)
      node, processor = Crystal::TypeDeclarationProcessor.new(@program).process(node)
      Crystal::AbstractDefChecker.new(@program).run if run_graph_checks
      unless @program.has_flag?("no_restrictions_augmenter")
        node.accept Crystal::RestrictionsAugmenter.new(@program, new_expansions)
      end
      @program.top_level_semantic_complete = true
      {node, processor}
    end

    # Wraps the JIT-emitted `crystal_jit_notify_reaped` fun in a host-side
    # Proc and installs it as the SIGCHLD bridge. No-op under `primitives`
    # prelude (symbol absent).
    private def install_signal_bridge : Nil
      return if @signal_bridge_installed
      addr = lljit.lookup?("crystal_jit_notify_reaped")
      return unless addr
      bridge = Proc(LibC::PidT, Int32, Bool).new(addr, Pointer(Void).null)
      Crystal::System::SignalChildHandler.external_reaper = bridge
      @signal_bridge_installed = true
    end

    # Adds JIT-emitted const globals to Boehm's root set; without this they
    # are unreachable (Boehm does not scan JIT-mapped pages) and their
    # finalisers run mid-session. Dedup-by-name across submissions.
    private def register_const_globals_as_gc_roots : Nil
      repl_state.emitted_root_globals.each do |name, size|
        next if @registered_root_globals.includes?(name)
        addr = lljit.lookup(name)
        high = (addr.as(UInt8*) + size).as(Void*)
        LibGC.add_roots(addr, high)
        @registered_root_globals << name
        @registered_root_ranges << {addr, high}
      end
    end

    # Invokes a compiled wrapper with a fresh result buffer. Side effects
    # in the user code re-execute on each call.
    def invoke(wrapper : CompiledWrapper) : Value
      if buffer_size = wrapper.buffer_size
        # `GC.malloc` (not `malloc_atomic`) so Boehm traces references
        # the wrapper writes back, e.g. `String`/`Reference` instances.
        buffer = GC.malloc(buffer_size).as(Pointer(UInt8))
        func = Proc(UInt8*, Nil).new(wrapper.wrapper_ptr, Pointer(Void).null)
        func.call(buffer)
        Value.new(buffer, wrapper.result_type, @program)
      else
        func = Proc(Nil).new(wrapper.wrapper_ptr, Pointer(Void).null)
        func.call
        Value.new(Pointer(UInt8).null, wrapper.result_type, @program)
      end
    end

    private def ensure_jit_initialized : Nil
      return if lljit?

      # Touch `target_machine` so `LLVM.init_<arch>` registers the target
      # before LLJIT looks it up - the spec binary never codegens otherwise.
      @program.target_machine

      ctx =
        {% if LibLLVM::IS_LT_210 %}
          LLVM::Orc::ThreadSafeContext.new.context
        {% else %}
          LLVM::Context.new(dispose_on_finalize: false)
        {% end %}

      ts_ctx =
        {% if LibLLVM::IS_LT_210 %}
          LLVM::Orc::ThreadSafeContext.new
        {% else %}
          LLVM::Orc::ThreadSafeContext.new(ctx)
        {% end %}

      @llvm_context = ctx
      @ts_ctx = ts_ctx

      builder = LLVM::Orc::LLJITBuilder.new
      configure_codegen_opt_level(builder)
      lljit = LLVM::Orc::LLJIT.new(builder)
      @lljit = lljit

      dylib = lljit.main_jit_dylib
      dylib.link_symbols_from_current_process(lljit.global_prefix)
      @dylib = dylib

      @layout_guard = LayoutRefusalGuard.new(@program, lljit)
      @dispatch_updater = DispatchSlotUpdater.new(lljit)
    end

    # Pins LLJIT's TargetMachine at `CodeGenOptLevel::None`; hot reload
    # depends on call-site indirection that inlining would defeat.
    private def configure_codegen_opt_level(builder : LLVM::Orc::LLJITBuilder) : Nil
      triple = @program.target_machine.triple
      target = LLVM::Target.from_triple(triple)
      tm_ref = LibLLVM.create_target_machine(
        target.to_unsafe, triple,
        "", "",
        LLVM::CodeGenOptLevel::None,
        LLVM::RelocMode::PIC,
        LLVM::CodeModel::Default,
      )
      jtmb = LibLLVM.orc_jit_target_machine_builder_create_from_target_machine(tm_ref)
      LibLLVM.orc_lljit_builder_set_jit_target_machine_builder(builder.to_unsafe, jtmb)
    end

    private def run_jit(node : ASTNode, well_known_source : ASTNode?) : CompiledWrapper
      {% if LibLLVM::IS_LT_110 %}
        raise "JIT backend requires LLVM 11 or newer"
      {% else %}
        ensure_jit_initialized
        @submission_counter += 1
        repl_state.submission_id = @submission_counter

        result_type = node.type? || @program.nil_type
        wants_value = !result_type.nil_type? && !result_type.void?

        visitor, llvm_mod = codegen_submission(node, well_known_source)
        wrapper_name = emit_wrapper_function(visitor, llvm_mod, result_type, wants_value)
        llvm_mod.verify
        dump_ir_if_requested(llvm_mod)

        func_ptr = materialize_wrapper(llvm_mod, wrapper_name)
        apply_post_materialization_fixups

        buffer_size = wants_value ? @program.size_of(result_type).to_u32 : nil
        CompiledWrapper.new(func_ptr, result_type, buffer_size)
      {% end %}
    end

    private def codegen_submission(node : ASTNode, well_known_source : ASTNode?) : {CodeGenVisitor, LLVM::Module}
      ctx = llvm_context
      visitor = CodeGenVisitor.new(@program, node,
        single_module: true,
        llvm_context: ctx,
        well_known_source: well_known_source)
      visitor.accept(node)
      visitor.process_finished_hooks
      visitor.finish

      llvm_mod = visitor.modules[""].mod
      llvm_mod.target = @program.target_machine.triple
      {visitor, llvm_mod}
    end

    private def emit_wrapper_function(visitor : CodeGenVisitor, llvm_mod : LLVM::Module,
                                      result_type : Crystal::Type, wants_value : Bool) : String
      ctx = llvm_context
      main = visitor.typed_fun?(llvm_mod, MAIN_NAME) ||
             raise "BUG: __crystal_main not emitted into submission module"
      # First submission only; later ones see the inited globals via ORC.
      init_runtime =
        if @submission_counter == 1
          visitor.typed_fun?(llvm_mod, "*Crystal::init_runtime:Nil")
        end

      wrapper_name = "__jit_wrapper_#{@submission_counter}"
      wrapper_type = if wants_value
                       LLVM::Type.function([ctx.void_pointer], ctx.void)
                     else
                       LLVM::Type.function([] of LLVM::Type, ctx.void)
                     end
      llvm_mod.functions.add(wrapper_name, wrapper_type) do |func|
        func.basic_blocks.append "entry" do |builder|
          if init_runtime
            builder.call(init_runtime.type, init_runtime.func, [] of LLVM::Value)
          end
          # `inttoptr` the Session-owned argv buffer; outlives every wrapper.
          argc = ctx.int32.const_int(@argv.argc)
          argv_addr = @argv.argv.address
          argv_int = ctx.int64.const_int(argv_addr.unsafe_as(Int64))
          argv = builder.int2ptr(argv_int, ctx.void_pointer.pointer)
          ret = builder.call(main.type, main.func, [argc, argv])
          if wants_value
            out_ptr = func.params[0]
            {% if LibLLVM::IS_LT_150 %}
              out_ptr = builder.bit_cast(out_ptr, main.type.return_type.pointer)
            {% end %}
            builder.store(ret, out_ptr)
          end
          builder.ret
        end
      end
      wrapper_name
    end

    private def materialize_wrapper(llvm_mod : LLVM::Module, wrapper_name : String) : Pointer(Void)
      tsm = LLVM::Orc::ThreadSafeModule.new(llvm_mod, ts_ctx)
      lljit.add_llvm_ir_module(dylib, tsm)
      lljit.lookup(wrapper_name)
    end

    private def apply_post_materialization_fixups : Nil
      dispatch_updater.apply_pending(repl_state)
      register_const_globals_as_gc_roots
      install_signal_bridge
    end

    private def dump_ir_if_requested(llvm_mod : LLVM::Module) : Nil
      if dump = ENV["CRYSTAL_JIT_DUMP_IR"]?
        File.write("#{dump}.#{@submission_counter}", llvm_mod.to_s)
      end
    end
  end
end
