module Crystal::JIT
  class Session
    # Live Sessions pinned so Builder disposal order stays in our hands.
    # `Repl#finalize` cannot dispose us directly because LLVM teardown
    # is not safe from the Boehm finalizer thread; callers (typically
    # specs via `Crystal::JIT::SpecSupport.dispose_all_sessions`) walk
    # this list explicitly. Drained on `dispose`; interactive use only
    # drains on a clean exit. See PROTOTYPE_STATUS.md "Known issues".
    @@alive = [] of Session
    @@at_exit_installed = false

    def self.each_alive(&block : Session ->) : Nil
      @@alive.dup.each(&block)
    end

    # Arms (once) a host-side `at_exit` that disposes any Session still
    # pinned in `@@alive`. Closes the interactive-only-clean-exit gap so
    # a process exit without explicit `Repl#reset` still tears down JIT
    # pages on the main thread (where LLVM teardown is safe).
    def self.ensure_at_exit_drain : Nil
      return if @@at_exit_installed
      @@at_exit_installed = true
      ::at_exit do
        @@alive.dup.each do |session|
          session.dispose rescue nil
        end
      end
    end

    getter program : Program
    # Top-level local names seen in prior submissions. `LocalLifter` mutates.
    @repl_locals = Set(String).new
    @submission_counter = 0
    @loader : Crystal::Loader? = nil
    @loaded_lib_names = Set(String).new
    @libs_initialized = false
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
    # Flipped by `Repl` when the warmup thread finishes touching shared
    # state (`@program.string_pool`, types, defs). `auto_complete`'s
    # method-name lookup walks `@program.types`, so reads must be gated
    # until the warmup releases.
    @warmup_done = Atomic(Int32).new(1)
    # Set by `walk_prelude_for_warmup`; consumed once by
    # `compile_with_walked_prelude` on the first user submission so the
    # prelude's typed AST is reused instead of re-walked.
    @walked_prelude : ASTNode? = nil

    def initialize(@program : Program)
      @program.enable_repl_state!
      @main_visitor = MainVisitor.new(@program)
      install_program_args(["jit"])
      @@alive << self
      Session.ensure_at_exit_drain
    end

    # `Repl#kick_off_warmup` arms this before spawning the background fiber;
    # `prepare_session` clears it when the prelude work releases shared state.
    def mark_warmup_started : Nil
      @warmup_done.set(0, :release)
    end

    def mark_warmup_done : Nil
      @warmup_done.set(1, :release)
    end

    def warmup_done? : Bool
      @warmup_done.get(:acquire) == 1
    end

    # `Session#initialize` calls `enable_repl_state!` so the program-level
    # accessor is always non-nil for any later `Session` method.
    private def repl_state : Crystal::ReplState
      @program.repl_state? || raise "BUG: Session lost its program-level repl_state"
    end

    # Allocates a persistent C-style `argv` the JIT wrapper hands to
    # `__crystal_main`.
    def install_program_args(args : Array(String)) : Nil
      @argv = CArgv.build(args)
    end

    # Drops Boehm root ranges added by `register_const_globals_as_gc_roots`
    # so they vacate slots in the `MAX_ROOT_SETS`-bounded table. Idempotent.
    def unregister_gc_roots : Nil
      return if @registered_root_ranges.empty?
      @registered_root_ranges.each do |low, high|
        LibGC.remove_roots(low, high)
      end
      @registered_root_ranges.clear
      @registered_root_globals.clear
    end

    # Clears the host's `SignalChildHandler.external_reaper` if we installed
    # it, so a successor Session can install its own.
    def uninstall_signal_bridge : Nil
      return unless @signal_bridge_installed
      Crystal::System::SignalChildHandler.external_reaper = nil
      @signal_bridge_installed = false
    end

    # Releases JIT-mapped pages and drops the `@@alive` pin. Idempotent.
    # User-context only (not a finalizer): the bridge proc and Boehm root
    # ranges both capture pointers into JIT memory and must be torn down
    # before the LLJIT unmaps it.
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
      @@alive.delete(self)
    end

    # Rewrites top-level local assigns/refs in `node` to class variables on
    # a synthetic `__REPLState` module so values persist across submissions,
    # then wraps the body in `module __REPLState ... end`. `require`s hoist
    # out as siblings of the wrapper. Compose with `wrap_runtime_with_rescue`
    # when the submission's runtime statements need a JIT-internal rescue.
    def wrap_in_repl_state(node : ASTNode) : ASTNode
      inner = node.transform(LocalLifter.new(@repl_locals))

      partitioner = ModuleWrapPartitioner.new
      partitioner.classify(inner)

      module_def = ModuleDef.new(Path.new("__REPLState"), Expressions.from(partitioner.body))
      if partitioner.outer.empty?
        module_def
      else
        Expressions.from(partitioner.outer.concat([module_def.as(ASTNode)]))
      end
    end

    # Groups consecutive runtime statements in the `__REPLState` module body
    # of an already-`wrap_in_repl_state`'d node through `handler` (typically
    # an `ExceptionHandler` builder). Declarations stay at body level.
    def wrap_runtime_with_rescue(node : ASTNode, handler : ASTNode -> ASTNode) : ASTNode
      rewrite_repl_state_body(node) do |body|
        RuntimeRescueGrouper.group(body, handler)
      end
    end

    # Replaces the body of the `__REPLState` ModuleDef found inside `node`
    # with the result of `block.call(body)`. Handles both shapes produced
    # by `wrap_in_repl_state`: a bare `ModuleDef` and an `Expressions`
    # containing requires followed by the `ModuleDef`.
    private def rewrite_repl_state_body(node : ASTNode, & : ASTNode -> ASTNode) : ASTNode
      case node
      when ModuleDef
        node.body = yield node.body
        node
      when Expressions
        module_def = node.expressions.find &.is_a?(ModuleDef)
        raise "BUG: wrap_runtime_with_rescue: no __REPLState ModuleDef in Expressions" unless module_def
        module_def = module_def.as(ModuleDef)
        module_def.body = yield module_def.body
        node
      else
        raise "BUG: wrap_runtime_with_rescue: expected wrap_in_repl_state output, got #{node.class}"
      end
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

    # Splits a submission body into siblings of the `module __REPLState` wrap
    # (`outer`) and members of its body (`body`). Requires hoist out; the rest
    # stays inside the wrapper.
    private class ModuleWrapPartitioner
      getter outer = [] of ASTNode
      getter body = [] of ASTNode

      def classify(node : ASTNode) : Nil
        case node
        when Expressions
          node.expressions.each { |child| classify(child) }
        when Require
          @outer << node
        else
          @body << node
        end
      end
    end

    # Walks a flat body sequence and groups consecutive non-declaration
    # nodes through `handler` (which builds an `ExceptionHandler` around its
    # input). Declarations remain at their original position so the JIT's
    # codegen doesn't trip on `def`/`class`/`@@__repl_*=…` inside a rescue.
    private class RuntimeRescueGrouper
      def self.group(body : ASTNode, handler : ASTNode -> ASTNode) : ASTNode
        return body if body.is_a?(Nop)
        rewritten = [] of ASTNode
        runtime_group = [] of ASTNode
        children =
          case body
          when Expressions
            body.expressions
          else
            [body]
          end
        children.each do |child|
          if AstShape.declaration?(child)
            flush_group(rewritten, runtime_group, handler)
            rewritten << child
          else
            runtime_group << child
          end
        end
        flush_group(rewritten, runtime_group, handler)
        Expressions.from(rewritten)
      end

      private def self.flush_group(rewritten : Array(ASTNode), runtime_group : Array(ASTNode), handler : ASTNode -> ASTNode) : Nil
        return if runtime_group.empty?
        grouped = runtime_group.size == 1 ? runtime_group[0] : Expressions.new(runtime_group.dup)
        rewritten << handler.call(grouped)
        runtime_group.clear
      end
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
      @main_visitor = MainVisitor.new(from_main_visitor: @main_visitor)
      repl_state.begin_submission!
      check_layout_change_refusal(node)
      # `parse_code` normalized the user input; the bundled-prelude path
      # wraps two normalized ASTs in a fresh `Expressions`. Re-normalize
      # so `Expressions` and any synthetic wrappers (`FileNode`, etc.) go
      # through the Normalizer too. The pass is idempotent on already
      # normalized children.
      node = @program.normalize(node)
      type_graph_dirty = BoolFlagVisitor.found_in?(node) { |n| AstShape.type_mutating?(n) }
      node = semantic_for_submission(node, type_graph_dirty)
      if type_graph_dirty || !@libs_initialized
        ensure_libraries_loaded
        @libs_initialized = true
      end
      run_jit(node, well_known_source)
    end

    # Background-warmup entry: type the prelude so the first user
    # submission only pays codegen. Caches the walked AST so
    # `take_walked_prelude` can fetch it on the foreground thread.
    def walk_prelude_for_warmup(prelude_ast : ASTNode) : Nil
      @main_visitor = MainVisitor.new(from_main_visitor: @main_visitor)
      repl_state.begin_submission!
      node = @program.normalize(prelude_ast)
      walked = semantic_for_submission(node, type_graph_dirty: true)
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
      @main_visitor = MainVisitor.new(from_main_visitor: @main_visitor)
      repl_state.begin_submission!
      input = @program.normalize(input)
      type_graph_dirty = BoolFlagVisitor.found_in?(input) { |n| AstShape.type_mutating?(n) }
      walked_input = semantic_for_submission(input, type_graph_dirty)
      if type_graph_dirty || !@libs_initialized
        ensure_libraries_loaded
        @libs_initialized = true
      end
      bundle = Expressions.new([walked_prelude, walked_input] of ASTNode)
      # The bundle itself is never walked, so its `.type` would default
      # to nil and `run_jit` would treat the wrapper as void; copy the
      # input's type so the result buffer is sized correctly.
      if input_type = walked_input.type?
        bundle.type = input_type
      end
      run_jit(bundle, nil)
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

    # Repoints `slot_name` at `target_name` with release-ordered store.
    # Release pairs with `repl_promote_to_dispatch`'s acquire load.
    private def repoint_slot(slot_name : String, target_name : String) : Nil
      slot_addr = lljit.lookup(slot_name)
      target_addr = lljit.lookup(target_name)
      ::Atomic::Ops.store(slot_addr.as(Pointer(Void*)), target_addr, :release, true)
    end

    # Repoints `:symbol_table:slot` at the newest versioned table once ORC
    # materialised it; otherwise first-wins LinkOnceODR masks growth.
    private def apply_pending_symbol_table_update : Nil
      update = repl_state.take_symbol_table_update
      return unless update
      repoint_slot(*update)
    end

    # Points each dispatch slot at the new :vN body now that ORC linked it.
    private def apply_pending_slot_updates : Nil
      repl_state.drain_slot_updates do |slot_name, body_name|
        repoint_slot(slot_name, body_name)
      end
    end

    # Raised on a layout-changing redef of a class with at least one live
    # instance. Unresolved paths fall through to normal semantic.
    class LayoutChangeRefused < Exception
    end

    private def check_layout_change_refusal(node : ASTNode) : Nil
      findings = LayoutChangeDetector.detect(node)
      return if findings.empty?
      lljit = lljit?
      return unless lljit

      seen = Set(String).new
      findings.each do |finding|
        type_name = path_to_string(finding.class_path).presence
        next unless type_name
        next if seen.includes?(type_name)
        existing = @program.types[type_name]?
        next unless existing.is_a?(Crystal::ModuleType)
        next unless type_has_live_instance?(existing, lljit)

        # `include` with no ivars and a restated superclass do not change layout.
        if finding.is_a?(LayoutChangeDetector::IncludeFinding) &&
           include_module_brings_no_ivars?(finding.include_path)
          next
        end
        if finding.is_a?(LayoutChangeDetector::SuperclassDeclarationFinding) &&
           superclass_unchanged?(existing, finding.superclass_path)
          next
        end

        seen << type_name
        raise LayoutChangeRefused.new(
          "#{type_name} #{finding.reason_text}, but at least one instance has been allocated. " \
          "Hot reload can't relayout existing objects safely; call `Crystal::JIT::Repl#reset` " \
          "to drop the program state and start over.")
      end
    end

    # True when `type`'s `:instantiated` flag is registered with the JIT
    # and the runtime byte at that address is non-zero.
    private def type_has_live_instance?(type : Crystal::ModuleType, lljit : LLVM::Orc::LLJIT) : Bool
      flag_name = "@\"#{type.llvm_name}:instantiated\""
      return false unless repl_state.flag_registered?(flag_name)
      flag_ptr = lljit.lookup(flag_name)
      return false if flag_ptr.address == 0
      flag_ptr.as(UInt8*).value != 0
    end

    # True when `path` resolves to a module with no ivars of its own.
    private def include_module_brings_no_ivars?(path : Crystal::Path?) : Bool
      return false unless path
      name = path_to_string(path).presence
      return false unless name
      mod = @program.types[name]?
      return false unless mod.is_a?(Crystal::ModuleType)
      mod.instance_vars.empty?
    end

    # True when `path` resolves to `existing`'s current superclass.
    private def superclass_unchanged?(existing : Crystal::ModuleType, path : Crystal::Path?) : Bool
      return false unless path
      name = path_to_string(path).presence
      return false unless name
      ast_super = @program.types[name]?
      return false unless ast_super
      existing.superclass == ast_super
    end

    private def path_to_string(path : Crystal::Path) : String
      path.names.join("::")
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

    # Dlopens `@[Link]` libraries so ORC's process resolver finds them.
    # First call evaluates `lib_flags` (forks pkg-config; can race
    # MT/EC scheduler threads); later calls walk `link_annotations`.
    private def ensure_libraries_loaded
      if @loader.nil?
        load_libraries_via_lib_flags
      else
        load_new_libraries_via_link_annotations
      end
    end

    private def load_libraries_via_lib_flags : Nil
      lib_flags = @program.lib_flags
      lib_flags = lib_flags.gsub(/`(.*?)`/) { `#{$1}`.chomp }
      args = Process.parse_arguments(lib_flags)
      unless @program.has_flag?("win32") && @program.has_flag?("gnu")
        args.delete("-lgc")
      end

      extra_search_paths = [] of String
      libnames = [] of String
      args.each do |arg|
        if arg.starts_with?("-L")
          extra_search_paths << arg[2..]
        elsif arg.starts_with?("-l")
          libnames << arg[2..]
        end
      end

      search_paths = extra_search_paths + Crystal::Loader.default_search_paths
      loader = Crystal::Loader.new(search_paths)
      loader.load_current_program_handle
      libnames.each do |name|
        loader.load_library?(name)
        @loaded_lib_names << name
      end
      @loader = loader
    end

    private def load_new_libraries_via_link_annotations : Nil
      libnames = [] of String
      extra_search_paths = [] of String
      @program.link_annotations.each do |ann|
        if ldflags = ann.ldflags
          ldflags.split do |token|
            if token.starts_with?("-L")
              extra_search_paths << token[2..]
            elsif token.starts_with?("-l")
              libnames << token[2..]
            end
          end
        end
        if name = ann.lib
          libnames << name
        end
      end

      unless @program.has_flag?("win32") && @program.has_flag?("gnu")
        libnames.delete("gc")
      end

      loader = @loader.not_nil!
      extra_search_paths.each do |path|
        loader.search_paths << path unless loader.search_paths.includes?(path)
      end
      libnames.each do |name|
        next if @loaded_lib_names.includes?(name)
        loader.load_library?(name)
        @loaded_lib_names << name
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
        repl_mode: true,
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
      main = visitor.typed_fun?(llvm_mod, MAIN_NAME).not_nil!
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
      apply_pending_slot_updates
      apply_pending_symbol_table_update
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
