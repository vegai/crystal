# Shape B implementation plan: in-process Crystal module loading

## Scope

**Goal**: an in-process API, callable from any AOT-compiled Crystal program, that loads Crystal source at runtime, typechecks and codegens it against the host's already-compiled program, and makes its methods/classes callable from host code through a typed bridge. Reloading the same source replaces the previously-loaded version's method bodies in place. The model is embedded scripting (Lua-style), but the scripting language is Crystal itself, JIT-compiled to native through the machinery this branch already built.

**API sketch**:
```crystal
require "crystal/embed"

Crystal::Embed.load("plugins/strategy.cr")    # JIT, install, run top-level
Crystal::Embed.load("plugins/strategy.cr")    # second call: hot reload
Crystal::Embed.unload("plugins/strategy.cr")  # drop slots, let GC reclaim
```

No socket. No control plane. The host program decides when to load, what to load, and what to expose. The compiler-as-library is along for the ride.

## Non-goals

For the first cut, the following are explicitly out:

- Layout-changing class edits at reload (same refusal as the JIT REPL today)
- New macros / `{% if flag?(...) %}` reinterpretation at module load
- Modules adding methods that AOT host code calls but didn't reference at host compile time (see "Bridge" below; the host's call surface is fixed at host compile time)
- Cross-Crystal-version modules (host and module compiler must match because the module compiler is the one embedded in the host)
- Windows. The JIT REPL is unix-only and Embed inherits that
- Static-linking the host binary. `--embed-compiler` requires a dynamic symbol table for `dlsym(RTLD_DEFAULT)` slot resolution; `crystal build --static --embed-compiler` is rejected at the CLI
- Forking after first `Embed.load`. LLJIT-mapped memory shared with a child process leads to UB if the child loads. The API refuses load post-fork and the documentation tells you not to fork after load
- Cross-compilation with `--embed-compiler`. The embedded compiler would need to target the host triple of the eventual runtime, which is unspecified

## Upfront decisions (resolved)

1. **LLVM linking**: dynamic against `libLLVM.so` by default, `--embed-compiler=static` for the self-contained case.
2. **`Program` materialization**: re-typecheck the host source on demand at first `Embed.load`. Snapshot serialization is a separate multi-month project.
3. **Indirection scope**: annotation-gated. A def or class member only gets the stub+`:slot`+`:vN` shape if it carries `@[Embeddable]` (or its enclosing class does, with the annotation propagated). Module-internal defs are always indirection-emitted (they need to be reloadable). The default-on alternative was rejected because `--release` builds depend heavily on inlining and forcing indirection on every host def would impose a 2-5x regression on inlining-sensitive workloads. Users opt in to embeddability per call surface.
4. **Module identity key**: file path (canonicalized). Same path means same module. Different paths with identical contents are different modules.
5. **Reload semantics for top-level code**: top-level code in a loaded module re-runs on reload. Registries the host exposes are expected to deduplicate by module identity (the registry helper provided by `Crystal::Embed` handles this).
6. **Stdlib embedding**: the host's stdlib is bundled into the host binary alongside its own source. Gzipped. Cost is ~2-3 MB on top of the binary.

## The bridge

This is the design question that everything else hangs on. Crystal is whole-program typed: a host AOT compile resolves every call site against a closed type lattice. Code loaded later can't add new symbols the host calls unless the host already emitted a call to them.

A loaded module can do these things naturally:

- Define types and methods used only by the module itself. The module's `Program` is a superset of the host's; module-internal calls resolve within the module.
- Subclass a host abstract class declared `@[Embeddable]`, override its abstract methods, register an instance with the host (see "Registry" below). The host iterates the registry and dispatches through the abstract interface. Virtual dispatch routes through a slot in `repl_mode`.
- Redefine an existing `@[Embeddable]` host method body. Host call sites pick up the new body through their existing dispatch slot.

These cases need explicit setup at host compile time. Both bridge mechanisms ship; users pick.

### Primary bridge: abstract-class registry

The host declares an `abstract class` (or `module` with abstract methods) tagged `@[Embeddable]`. The annotation does two things: emits the dispatch indirection so subclass methods are slot-routable, and exports the class's metaclass/type-id symbols so the loaded module can `dlsym` them when codegen'ing the subclass.

`Crystal::Embed::Registry(T)` is a generic registry helper:

```crystal
class Crystal::Embed::Registry(T)
  def register(instance : T, owner : String) : Nil   # owner is module identity
  def unregister(owner : String) : Nil               # called on reload before re-run
  def each(& : T ->) : Nil
end
```

The host owns one or more registries typed on its abstract class. The module subclasses the abstract class and calls `register`. On reload, `Crystal::Embed` calls `unregister` with the module path before re-running its top-level code, so the new instance replaces the old in the registry.

**Open verification**: extending the host's virtual dispatch with a brand-new subclass at runtime needs to work in the JIT REPL's existing machinery. The slot mechanism handles redefinition of an existing def's body, but a new subclass of an existing abstract class introduces a new `type_id` and a new entry in the per-method virtual table. This is exercised by JIT REPL spec `jit_layout_refusal_spec.cr`'s subclass cases and case 3 of `samples/jit_hot_reload.cr`; what the plan needs is a confirmation that *adding a new sibling subclass after the host's compile* works as expected, not just *redefining an existing one*. Phase B5a's exit criterion includes this.

### Secondary bridge: typed slot

For the embedded-scripting "call a function" case, the host declares slots at compile time:

```crystal
# In the host:
Crystal::Embed.declare_slot compute, (Int32, Int32) -> Int32
Crystal::Embed.declare_slot greeting, () -> String

# Calling:
if proc = Crystal::Embed.compute
  result = proc.call(3, 4)
end
```

The macro expands into:

- A `Proc(Int32, Int32, Int32)?` typed wrapper (`nil` when unfilled)
- A slot global in `repl_mode` emission
- A registration entry consulted by `Crystal::Embed.load`: after each load, the loader looks for a top-level def in the loaded module matching the slot's name and signature

Semantics:

- **Unfilled slot**: returns `nil` from the typed getter. Callers explicitly check. No exception, no UB. This is the honest contract.
- **Type mismatch at load**: the macro records the slot's expected signature as a string in the slot's metadata. The loader, after typechecking the module, compares the loaded def's type signature against the recorded one. Mismatch produces a typed `Crystal::Embed::SignatureMismatch` raised from `load`. The slot stays at its previous value (or `nil`).
- **Overloads**: not supported in the secondary bridge. One slot, one signature, one name. Users wanting overloads use the registry.
- **Generics**: not supported in declared slots (Crystal's `Proc` doesn't carry uninstantiated type parameters).
- **Method receivers**: declared slots are for top-level defs only. Class methods and instance methods use the registry.
- **Multiple modules filling the same slot**: last `load` wins, with a warning logged. Users are expected to use the registry for plural cases.
- **`declare_slot` must appear at top level** of the host source (in a `module` or at the file root). Inside a method body, it's a compile error.

The macro is implemented under `src/embed/declare_slot.cr` and uses the existing `repl_state` slot emission so `DispatchSlotUpdater` works on it unmodified.

## Architecture: reuse vs net-new

This branch already built almost everything. What carries over:

- Stub + `:slot` + `:vN` codegen at `src/compiler/crystal/codegen/fun.cr:67-92, 332-365`
- `DispatchSlotUpdater` for atomic slot rewrite (`interpreter/jit/dispatch_slot_updater.cr`)
- `LayoutRefusalGuard` for ivar-layout-change refusal
- `RedefForce` for forcing codegen on `def`-only inputs
- The whole `Session`, wrapper cache, rescue handling, FFI parity, `ReplCodegenHooks` collaborator at the AOT/JIT seam

What changes or is new:

- The AOT codegen path emits indirection for `@[Embeddable]` symbols only (not the JIT REPL's blanket "everything is reloadable").
- The compiler library is linked into user binaries. **Build-time consequence**: `require "compiler/crystal/interpreter"` today inlines the compiler's source into the user's binary, which means every `--embed-compiler` build pays the compiler's own compile time (currently multi-minute on a small program; it's the same cost building `samples/jit_hot_reload.cr` has today). Until the compiler is shipped as a precompiled library (out of scope here), `--embed-compiler` builds are slow. Document this prominently.
- The host source is bundled into the user binary so the embedded compiler can re-walk it.
- A user-facing `Crystal::Embed` API.
- `DispatchSlotUpdater` learns to resolve slot symbols via `dlsym(RTLD_DEFAULT)` (AOT slots) in addition to `lljit.lookup` (slots created by previous loads).
- Macros for `Crystal::Embed.declare_slot` and `@[Embeddable]` (the annotation is currently a no-op; the codegen-side logic interprets it).

## Phase plan

### Phase B0: build-mode flag

Deliverable: `crystal build --embed-compiler foo.cr` parses, sets `Compiler#embed_compiler = true`, otherwise behaves like a normal build. Submodes `--embed-compiler=dynamic` (default) and `--embed-compiler=static` are accepted. `--embed-compiler` with `--static` or `--cross-compile` errors out at the CLI.

Exit: flag accepted, ignored. CLI conflict detection works. CI green.

### Phase B1: AOT codegen emits dispatch indirection for `@[Embeddable]` symbols

Four sub-phases because the work is large enough to need its own verification rhythm.

**B1a: `@[Embeddable]` annotation + repl_state gating on AOT path.** Define the annotation. When `embed_compiler` is set, `program.enable_repl_state!` runs before semantic. `ReplCodegenHooks` participates as it does for the JIT path. Initially, treat every def as embeddable (default-on) to validate the codegen, then restrict in B1b.

Exit: `nm -D ./host_binary | grep ':slot'` shows slot globals for every def. Binary runs and produces identical output to the same program built without `--embed-compiler`.

**B1b: Restrict indirection to `@[Embeddable]`.** Codegen consults the annotation per def (or inherited from the enclosing class). Non-annotated defs emit as plain AOT functions, no slot, no version.

Exit: a sample with one annotated method and many unannotated methods shows slots only for the annotated ones. Inlining of unannotated methods works under `--release`.

**B1c: Linker flag plumbing.** `-Wl,--export-dynamic` (Linux), `-Wl,-export_dynamic` (macOS) for slot symbol export. Plumbed through `compiler.cr:linker_command`. Constants under `@[Embeddable]` types emit as mutable globals with runtime loads.

Exit: `dlsym` from a test C program finds the slot symbols at the expected mangled names.

**B1d: Regression suite under `--embed-compiler`.** Run Crystal's existing spec suite with `--embed-compiler` on the spec binaries themselves. Investigate every failure; many will be benign (test depends on inlining, test depends on specific symbol mangling), some will indicate real codegen regressions.

Exit: spec suite passes under `--embed-compiler` or every failure has a documented justification.

This phase is the riskiest. Static linker behavior around `LinkOnceODR` versus ORC's resolution might surface here; LTO interactions are unspecified. Budget for surprises.

### Phase B2: embed host source into the binary

Deliverable: the host binary contains its own source tree plus stdlib as a packed blob, plus a runtime accessor.

Concrete work:

- After the parser resolves all `require`s, the compiler emits the source set into LLVM IR as a `[N x i8]` global named `__crystal_embedded_sources`.
- Format: TOC of `(filename, offset, length, kind)` followed by concatenated bodies, gzipped. `kind` distinguishes host source from stdlib so the embedded compiler can route resolution. Stdlib at ~10 MB raw, ~2-3 MB gzipped.
- Filenames are canonicalized to forward-slash relative paths, rooted at the build CWD (host) or the resolved `Crystal::Config.path` (stdlib).
- `Crystal::Embed::HostSources` exposes the blob to the embedded compiler.
- **Resolver contract**: when a loaded module calls `require "./helper.cr"`, the path is resolved relative to the loaded module's file path on disk. When it calls `require "json"`, the stdlib lookup goes to `HostSources` first, then to disk as fallback. Module-relative requires never read from `HostSources`. Document this.
- **Shards dependencies**: a host that depends on shards has those shards already resolved into the require graph at host compile time, so they're in `HostSources` automatically. Modules that need additional shards beyond what the host bundled must load them from disk; the embedded compiler walks `Crystal::Config.lib_path` for these.

Exit: a sample program calls `Crystal::Embed::HostSources.size` and the count matches the host's resolved require graph. A loaded module that `require`s a host-bundled file resolves correctly. A loaded module that `require`s a disk-only file resolves correctly. Binary size delta measured.

### Phase B3: link the compiler library into the host

Deliverable: when `embed_compiler` is set, the host binary's compile inlines the compiler source (current model, via the equivalent of `require "compiler/crystal/interpreter"`), producing a binary that contains the compiler.

Concrete work:

- The flag wires up the require automatically before user code is compiled.
- LLVM linking per the upfront decision (dynamic by default).
- Audit the JIT REPL for places it assumes it runs inside `bin/crystal`: signal handler installation (`SignalChildHandler.external_reaper`), `Program#flags` ("host_signal_handlers_already_installed"), GC root registration, `at_exit` ordering. The JIT REPL already handled some of these; the embedded scenario inverts some assumptions (the host has installed its own signal handlers, the embedded compiler must not clobber them).

Acknowledged cost: every `--embed-compiler` build pays the compiler's full compile time. This is the same cost `samples/jit_hot_reload.cr` already pays, on the order of minutes for a small program. Until the compiler is shipped as a precompiled library, this is unavoidable. Documented at the CLI as a startup banner and in the README.

Exit: `ldd ./host_binary` shows `libLLVM` (dynamic mode). `./host_binary` boots and exits without invoking any compiler code. Binary size is within the projected band (~10-15 MB dynamic, ~50 MB static, both above the host's own code). Host's signal handlers survive the embedded compiler being linked.

### Phase B4: `Crystal::Embed` API and lazy Session bootstrap

Deliverable: `Crystal::Embed.load(path)` lazily materializes a `Crystal::JIT::Session` on first call, then compiles and runs the file at `path` into it.

Concrete work:

- New module `Crystal::Embed` with `load`, `reload` (alias for `load`), `unload`, registry helpers, and the slot-declaration macro.
- **Thread safety**: first `load` builds the `Program` under an internal mutex. Concurrent loads from multiple fibers block on the bootstrap; once warm, loads serialize through a queue (the JIT Session is not designed for parallel codegen of independent modules and would need substantial work to be so). Document that loads are serialized.
- **Signal handler audit**: `Session#initialize` today installs a SIGCHLD reaper bridge. In the embedded case, the host's own SIGCHLD handler must not be displaced. Refactor `SignalChildHandler.external_reaper=` to chain (call the prior handler) rather than replace, or gate the bridge installation on a flag the host can set. Verify with a test that installs a SIGCHLD handler, calls `Embed.load`, and observes the host's handler still fires.
- **Fork detection**: `Embed.load` checks the PID against the PID seen at first load. If it differs (we're in a forked child), the call raises `Crystal::Embed::PostForkLoadRefused`.
- `unload(path)` clears the wrapper cache entries for that path and the loader's tracking of which slots that module filled. JIT memory drains lazily through Phase B6's epoch scheme.

Exit: `Crystal::Embed.load("/tmp/plug.cr")` where the file is `puts "hello from a module"` produces the message. First-load timing measured. Concurrent-load test passes (deterministic serialization). Fork-then-load test raises. Host's pre-existing signal handler still fires after `Embed.load`.

### Phase B5: bridge mechanisms

Three sub-phases.

**B5a: Abstract-class registry.** `Crystal::Embed::Registry(T)` implementation. `@[Embeddable]` annotation propagates to abstract methods so their dispatch indirection is emitted. Verification target: a host declares `@[Embeddable] abstract class Plugin; abstract def name : String; end`, owns a `Registry(Plugin)`, a loaded module subclasses with `class P < Plugin; def name; "loaded"; end; end` and registers, host calls `.name` on the registered instance, gets `"loaded"`. A second module registers a different subclass; host iteration sees both.

Exit: the demo works. The new-subclass-of-existing-abstract case is explicitly verified (this is the architectural claim that wasn't pre-verified in the JIT REPL's spec suite for this exact case).

**B5b: `declare_slot` macro.** Implements the secondary bridge per the design above. Located at `src/embed/declare_slot.cr`. Generates the typed wrapper, slot global, and registration entry.

Exit: declare_slot demos pass (call before fill returns nil; call after fill works; reload changes behavior; signature mismatch raises at load).

**B5c: Cross-domain symbol resolution audit.** The Session's `JITDylib` fallback resolver must find every host-provided symbol a loaded module needs. The JIT REPL gets these from `bin/crystal`'s symbol table; in the embedded case they come from the host binary, which has a different symbol set. Explicit list to verify:

- Boehm GC entry points (`GC_malloc`, `GC_malloc_atomic`, `GC_realloc`, `GC_free`)
- Exception personality (`__gxx_personality_v0` or platform equivalent)
- Crystal runtime helpers (`__crystal_main`, `__crystal_once`, `__crystal_raise`, type-id table accessors)
- libunwind / libbacktrace
- Stdlib free functions (`Process.exit` resolves to a typed call, but `LibC.exit` is direct)
- Math library (`sin`, `cos`, etc.) and any `Lib*` referenced indirectly via inlined intrinsics

For each, document whether it's exported by default from an AOT binary or whether `--export-dynamic` is enough. Anything that isn't requires either explicit export or a thunk in the embed runtime.

Exit: a deliberately broad test module exercises each category; all loads cleanly.

### Phase B6: slot rewrite for AOT slots and drain

Deliverable: `DispatchSlotUpdater` works when the slot lives in the AOT host's data segment. Old module code holds for the lifetime of the process to keep this phase simple.

Concrete work:

- Refactor `DispatchSlotUpdater#repoint_slot` (`dispatch_slot_updater.cr:27`) to take a resolver. Default for the JIT REPL stays `@lljit.lookup`; embed strategy tries `dlsym(RTLD_DEFAULT, name)` first, falls back to LLJIT.
- New-body address comes from LLJIT.
- `LayoutRefusalGuard` carries over.
- `RedefForce.inject` is called for every loaded module so `def`-only files actually emit codegen and trigger slot updates.
- **Drain story (first cut)**: do not free JIT memory across reloads. Each reload leaks the prior module's JIT pages until process exit. Estimated cost per reload: 200 KB to 2 MB depending on module size, dominated by the LLVM-generated object code and the small runtime tables ORC keeps per module. For a long-lived host with thousands of reloads, this is significant; for a dev-mode tool reloaded tens of times per session, it's negligible. Documented as a known trade. A future phase introduces per-fiber epochs.

Exit: Phase B5 demos pass under repeated reload. A "100 reloads" stress test runs to completion with monotonically-increasing RSS at a documented rate.

### Phase B7: integration verification

Deliverable: a single integration test that exercises the full surface in one program.

Targets in one file:

- A loaded module calls `puts`, `String#+`, basic stdlib
- A loaded module reads a host constant and a host class var
- A loaded module instantiates a host class and calls instance methods
- A loaded module subclasses a host abstract `@[Embeddable]` class and registers
- A loaded module redefines a host `@[Embeddable]` method
- A loaded module's top-level code calls into another file via `require`, and that file is found via the loaded-module-relative resolution path
- A loaded module uses a host-defined macro
- A second reload of the same file replaces the prior version, re-runs top-level (registries deduplicate via the module path)

Exit: one passing integration spec, run in-process and as a subprocess (the AOT-binary variant).

### Phase B8: docs, benchmarks, demo

Deliverable: documented, benchmarked, demoable feature.

Concrete work:

- A `samples/embed_plugin_strategy.cr` demo: host iterates registered plugins on a timer; user edits the plugin source and reloads via a host-provided `r` keybind in the demo's input loop; output changes without restart.
- Update `PROTOTYPE_STATUS.md` with Embed phase rows and benchmark deltas.
- README section listing the limits (the non-goals from this plan), the build-time cost, and the steady-state cost.
- **Steady-state benchmark**: build a non-trivial host (HTTP server, `fib(35)` loop, JSON parser exercise) twice, once with `--embed-compiler` and once without, with no `Embed.load` calls in either. Compare wall-clock and RSS at steady state. This is the number that drives deployment decisions. Document.
- **First-load benchmark**: time the first `Embed.load` against the host source size. Quantify the "lazy bootstrap takes seconds for a compiler-sized host" claim.

Exit: subprocess specs green; demo works; benchmark numbers in `PROTOTYPE_STATUS.md`; docs accurate.

## Open questions

Most of the previous round's questions were resolved in "Upfront decisions". What genuinely remains:

1. **Macro reload semantics.** If a loaded module redefines a host macro, what happens? Macros are compile-time; the host's AOT code has already expanded its macros. A reloaded macro can only affect subsequently-loaded modules' compilation. Behavior is well-defined (new macro affects new loads, old code unchanged) but should be documented as "yes this works but only for forward calls". Worth a small spec.
2. **Should `unload` actually free anything in the first cut?** Per B6, JIT memory leaks anyway. If `unload` only clears the wrapper cache and slot targets (without freeing), it's mostly cosmetic until B6 gets a real drain. Decide whether to ship `unload` in v1 or defer.
3. **Registry equality.** If a loaded module's class compares equal to a host's class via `==` after registration, do operations like `Set#add` work as expected? Type identity is preserved (the loaded subclass has its own `type_id`); document and test.

## Risk register

- **Build time inheritance.** Every `--embed-compiler` build pays the Crystal compiler's full compile time (minutes on a small program). Until the compiler is a precompiled library, this is the steady-state cost. Mitigation: cache aggressively in development; document prominently.
- **First-load typecheck cost.** Lazy materialization of `Program` on first `Embed.load` takes the host's compile-minus-codegen time. Sub-second for small hosts; seconds-to-tens-of-seconds for compiler-sized hosts. The fact that it's lazy means host startup is unaffected; the cost lands at first load. Document and accept.
- **Steady-state cost of indirection.** Annotation-gated means non-`@[Embeddable]` code is unaffected, but every `@[Embeddable]` def loses inlining. For a host with a small reloadable surface, negligible; for a host with broad reloadability, measurable. Phase B8's benchmark quantifies.
- **Compiler-in-library reentrancy.** The compiler assumes it runs inside `bin/crystal`. Signal handlers, thread-locals, `at_exit` ordering, GC roots all need auditing in the embedded scenario. Phase B3 and B4 do the audit; expect surprises.
- **Symbol-name collisions and bloat.** `@[Embeddable]` symbols carry `:slot`, `:vN` decorations in the host's symbol table. For a host with many embeddable types, the symbol table grows; link time grows; `nm -D` output is noisy. Mostly cosmetic.
- **`Program` snapshot lifetime.** Once Embed is active, the live `Program` is the dominant RAM cost. A long-running server doing many reloads grows the snapshot. Periodic explicit reset is available; document the trade.
- **JIT memory leak across reloads.** Per B6, first-cut accepts the leak. Documented.
- **LLVM dynamic linking on older distros.** Some distros ship LLVM 17 while this branch targets 22. `--embed-compiler=static` exists for this case.
- **Static linking of the host is rejected.** A user expecting to ship a self-contained static binary with `--embed-compiler` will hit a CLI error. Documented; the recommendation is `--embed-compiler=static` which only statically links LLVM (the host binary itself stays dynamically linked enough for `dlsym` to work).
- **The bridge ceiling.** Users will want to load a module that introduces a brand-new top-level symbol and call it from host code that didn't declare a slot or anticipate the type. Documented; the registry and `declare_slot` are the only mechanisms.
- **Fork-after-load.** Refused at the API level. Users who fork must do so before any `Embed.load`.

## Spec strategy

- **Reuse**: the existing JIT redef/layout specs run against an in-process `Crystal::JIT::Repl`. Keep running them; they're the fast feedback loop covering slot mechanics.
- **New (in-process)**: `embed_spec.cr` family exercises `Crystal::Embed.load` against fixture files in `spec/fixtures/embed/`. Same process. Covers the API surface, registry, declare_slot, reload semantics.
- **New (subprocess)**: `embed_aot_spec.cr` family builds a fixture binary with `--embed-compiler`, runs it, asserts on stdout. Gated behind `CRYSTAL_EMBED_AOT_SPEC=1` because subprocess spawn plus JIT bootstrap per case is expensive.
- **Memory-leak monitoring**: a spec under `CRYSTAL_EMBED_LEAK_SPEC=1` does 100 reloads, samples RSS at intervals, and asserts growth is within the documented per-reload bound.
- **Build-fixture management**: cache compiled fixture binaries under `tmp/spec/embed/` keyed by source hash; reuse across runs.

## Rough scope estimate

In LOC terms relative to this branch's ~2.4k of JIT code, with the decomposition above:

- B0: ~50 LOC (flag plumbing, CLI conflict detection)
- B1a-d: 400-600 LOC (annotation, codegen gating, linker flags, spec audit + fixes)
- B2: 250-400 LOC (source embedding, resolver contract, stdlib bundling)
- B3: 150-250 LOC (require-injection, audit fixes for SignalChildHandler chaining, GC root handling)
- B4: 300-500 LOC (`Crystal::Embed` module, lazy bootstrap, mutex, fork detection)
- B5a-c: 400-700 LOC (Registry helper, declare_slot macro, cross-domain resolution thunks where needed)
- B6: 150-250 LOC (resolver refactor, no-drain leak path)
- B7-B8: mostly verification and docs, 200-400 LOC in spec harness and benchmark plumbing

Total: 1.9-3.1k LOC net new, plus modest refactors to existing JIT files. Wider band than the previous estimate because B1d (regression suite) is unbounded by design.

Phase order: B0 → B1 → B2 (parallelizable with B3) → B3 → B4 → B5a/b/c (parallelizable internally) → B6 → B7 → B8. B1 is the longest pole and the riskiest. B5a's verification of new-subclass-of-existing-abstract is the architectural unknown; if it doesn't work out of the box, that turns into a separate codegen subproject around extending virtual dispatch tables at runtime.

Phases B1, B4, B5 are the load-bearing ones. The rest is plumbing.

---

## B5b `declare_slot` macro — landed

The secondary bridge shipped alongside the materialisation primary bridge:

- `Crystal::Embed.declare_slot name : (T...) -> R` at `src/embed/declare_slot.cr`; the call form is a `TypeDeclaration` (`name : ProcNotation`) because Crystal's parser doesn't accept a bare `(T...) -> R` in macro-argument position.
- `Crystal::Embed::DeclaredSlots` registry (process-wide, populated by macro expansions at startup) and `Crystal::Embed::SignatureMismatch` exception, both in the same file.
- Loader hook in `src/embed/loader.cr`: `fill_declared_slots` runs after each `repl.run_code(source)`. It snapshots top-level `Def` AST `object_id`s before the load and consults the diff to ignore unrelated submissions. For each declared slot with a fresh def of the same name, the loader resolves the JIT-side typed instance from `program.def_instances`, calls `def.mangled_name(program, program)`, and resolves the address through `repl.session.lljit.lookup`. The mangled stub address is what the host's `Atomic(Pointer(Void))` class var ends up holding; reloads stay stable at this address because the JIT's redef machinery updates the stub's internal slot in place.
- Loader removed the `embed_compiler` flag it was previously setting on the JIT `Program`. That flag tells AOT codegen to gate dispatch indirection on `@[Embeddable]`; on the JIT side the blanket dispatch shape is what makes reload work, so the flag is intentionally absent from the loaded-module-side `Program`. Loaded modules that explicitly `require "embed"` no longer get a populated `Crystal::Embed` (the embed files' `skip_file` gate flips negative without the flag) — accept this for v1.
- Safe-types restriction enforced by the macro: only primitives (`Int*`/`UInt*`/`Float32/64`), `Bool`, `Char`, `Nil`, `Symbol`, `String`, `Bytes` are accepted. Host-defined classes are rejected with a clear error pointing at `materialize_files` + the registry.
- Spec coverage at `spec/compiler/crystal/commands/embed_compiler_spec.cr`: six new `B5b: declare_slot` examples covering unfilled, filled, signature mismatch, reload, multi-module warn, and safe-types rejection.

History from before the work landed — the original pick-up plan is preserved below for reference; the implementation is faithful to it apart from the macro syntax (`name : (T...) -> R` instead of `name, (T...) -> R`) and the JIT-side `Program` flag fix described above.

### Already in place

- `--embed-compiler` flag, `program.flags << "embed_compiler"`, `program.enable_repl_state!` (in `src/compiler/crystal/compiler.cr:new_program`)
- AOT codegen emits dispatch indirection for `@[Embeddable]` defs/types (see `src/compiler/crystal/codegen/fun.cr:embeddable_def?` and `compute_redef_plan`)
- `__crystal_embedded_sources_data` + `_size` globals from `src/compiler/crystal/codegen/embed_sources.cr`; runtime accessor at `src/embed/host_sources.cr`
- `Crystal::Embed.load/reload/unload/materialize_files/before_reload` at `src/embed/loader.cr`; lazy `Crystal::JIT::Repl` shared across loads
- `Crystal::Embed::Registry(T)` at `src/embed/registry.cr`
- `DispatchSlotUpdater#lookup_slot_address` tries `dlsym(RTLD_DEFAULT, ...)` before `LLJIT.lookup`, so AOT-emitted method slots get repointed by JIT submissions (see `src/compiler/crystal/interpreter/jit/dispatch_slot_updater.cr`)
- 32 specs in `spec/compiler/crystal/commands/embed_compiler_spec.cr`

### What `declare_slot` is for

The "secondary bridge" from the design above: the host declares a typed entry point at compile time; a loaded module fills it with a top-level def matching the declared signature; the host calls through a typed accessor that returns `nil` when no module has filled it yet.

```crystal
# Host code:
Crystal::Embed.declare_slot compute, (Int32, Int32) -> Int32
Crystal::Embed.declare_slot greeting, () -> String

# Calling:
if proc = Crystal::Embed.compute
  result = proc.call(3, 4)
end
```

Different from the registry: the registry needs a host-defined abstract class plus a loaded subclass, and surfaces *plural* implementations. `declare_slot` needs no host-side class hierarchy, surfaces *one* implementation, and the loaded module's contribution is a free-standing top-level def — the lightest possible coupling.

### Concrete implementation steps

1. **Macro file** `src/embed/declare_slot.cr` (gated `{% skip_file unless flag?(:embed_compiler) %}`)

   The macro:
   - Validates the call form: name (Path or string literal), signature (Proc type literal `(T...) -> R`).
   - Validates location at the top level of the host source. The macro can check `@type.name`'s nesting via `@type.id == "main"` heuristics, or — simpler — be a method on `Crystal::Embed` only, and rely on the call-site context that Crystal already restricts.
   - Validates: no generics in the signature, no method receivers, no overloads (a second `declare_slot` with the same name is a compile error — track names in a `{% verbatim %}`-scoped state if needed, or accept duplicates and emit a warning at runtime).
   - Generates:
     - A class-var-backed atomic pointer slot on `Crystal::Embed`:
       ```crystal
       @@__#{name}_slot_addr = Atomic(Void*).new(Pointer(Void).null)
       ```
     - A typed accessor:
       ```crystal
       def self.#{name} : Proc(T..., R)?
         addr = @@__#{name}_slot_addr.get
         return nil if addr.null?
         Proc(T..., R).new(addr, Pointer(Void).null)
       end
       ```
     - A registration entry in a process-wide table:
       ```crystal
       Crystal::Embed::DeclaredSlots.register(
         name: "#{name}",
         signature: "(T...) -> R",  # canonicalised string for the loader to compare
         setter: ->(addr : Void*) { @@__#{name}_slot_addr.set(addr) }
       )
       ```

   `Crystal::Embed::DeclaredSlots` is a new module holding a `{} of String => DeclaredSlot` registry. A `DeclaredSlot` record carries `signature : String` (the canonicalised type representation), `setter : Void* -> Nil`, and `last_owner : String?` (the path of the loaded module that last filled it, for the warning on multiple-fills).

2. **Signature canonicalisation**. The macro generates the signature string with a stable spelling — e.g. always `(A, B) -> C` (space after comma, single-space arrow), so loader-side comparison is plain string equality. Document the canonical form so the loader's comparison code uses the same shape.

3. **Loader hook** in `src/embed/loader.cr`. After each successful `repl.run_code(source)` in `Crystal::Embed.load`, iterate `DeclaredSlots`. For each `(name, slot)`:
   - Ask the JIT for the mangled name of the top-level def `name` from the most-recent submission. **This is the new JIT-side API surface needed** — see §"JIT API surface to add" below.
   - If no such def → skip (don't fill, don't error; another module may provide it).
   - If found → fetch the def's typed signature, canonicalise to the same shape, compare against `slot.signature`. On mismatch raise `Crystal::Embed::SignatureMismatch` *from inside `load`*, leave the slot at its previous value.
   - On match → resolve the mangled name via `repl.session.lljit.lookup(mangled_name)` to get the function address. Call `slot.setter.call(addr)`. Record `slot.last_owner = canonical_path`.
   - If `slot.last_owner` was already set to a *different* path, log a warning at `STDERR` ("slot `name` was previously filled by `prior_owner`; replacing with `current_owner`").

4. **Error class** in `src/embed/loader.cr` (or a dedicated file):
   ```crystal
   class Crystal::Embed::SignatureMismatch < Exception
     getter slot_name : String
     getter expected : String
     getter actual : String
     def initialize(@slot_name, @expected, @actual)
       super("slot #{@slot_name} declared as #{@expected} but loaded module's def is #{@actual}")
     end
   end
   ```

5. **Require it from `src/embed.cr`**:
   ```crystal
   require "./embed/declare_slot"
   ```

### JIT API surface to add

The loader needs to ask the JIT `Repl` two things about the just-finished submission:

1. *Does it contain a top-level def named `X`?* If yes, return its typed `Def` node (the post-semantic one with `Type` already attached).
2. *What's the mangled name for that def?* So `LLJIT.lookup` can resolve it.

Today `Crystal::JIT::Repl` exposes `run_code` and a few high-level entry points but nothing that reaches into a post-submission `Program` snapshot. The bounded addition:

- `Repl#last_submission_top_level_def(name : String) : Def?` — walks `@program.main_def_visitor` (or whatever holds top-level defs after the most recent submission's `run_top_level_semantic`) and returns the most-recently-added def matching `name`. Stash a "submission high-water mark" so this query ignores defs from older submissions.
- `Repl#mangled_name_for(target_def : Def) : String` — calls into the existing `Crystal::CodeGenVisitor` name-mangling logic. The mangling lives at `src/compiler/crystal/codegen/codegen.cr` (look for `target_def_fun` / `mangled_name` callers); extract a pure function from that.

Both methods are `pub`-but-internal: they're in `Crystal::JIT::Repl`, not in `Crystal::Embed`. `Crystal::Embed::Loader` calls them.

### Top-level def storage — where to look

Top-level defs in Crystal hang off the program rather than a class. Look at:
- `Program#main_def` and friends in `src/compiler/crystal/program.cr` and `src/compiler/crystal/semantic/ast.cr` for how the JIT REPL stores top-level defs across submissions.
- The cross-submission visitor in `src/compiler/crystal/interpreter/jit/local_lifter.cr` shows how top-level statements get wrapped — that may inform whether a "top-level def" really is a def on the program or a method on a synthetic `__REPLState` module.

If top-level defs end up as methods on a synthetic module wrap (likely), the loader's lookup walks that module's defs rather than `program.defs`. The JIT REPL's existing dispatch-slot machinery (`fun.cr:compute_redef_plan`) already mangles these names; reuse that path.

### Cross-boundary type-identity caveat (read before writing code)

This is the same hazard that limits B5a's full registry pattern. `declare_slot compute, (Int32, Int32) -> Int32` is safe because the parameter and return types are stdlib primitives — the same `Int32` lives in both the AOT host's `Program` and the JIT `Program`. But the moment a declared signature mentions a host-defined class:

```crystal
class Order; end
Crystal::Embed.declare_slot process, (Order) -> Order   # <-- danger zone
```

…the host's `Order` and the JIT's `Order` are distinct types. The host's accessor expects `Proc(host-Order, host-Order)`, the loader-side check would canonicalise the loaded module's def as `Proc(jit-Order, jit-Order)`, and they don't match. The signature-string comparison treats them as the same string ("Proc(Order, Order)"), so the load *appears* to succeed, but the runtime call from the host into the slot passes a host-Order to code that's typed for jit-Order — undefined behaviour.

Mitigations, in priority order:

1. **Restrict declared signatures to safe types**. The macro accepts only: primitives (`Int*`, `UInt*`, `Float32/64`, `Bool`, `Char`, `Nil`, `Symbol`), `String`, `Bytes`, fixed-shape `Tuple`s of safe types, and `Proc`s of safe types. Reject host-defined class refs at expansion with a clear error message pointing the user at `materialize_files` for cross-boundary types.
2. **Document the restriction prominently**. Users who hit it have a workaround (define the data type in a materialised file so it's the JIT type, then arrange for the host to refer to the JIT-side type through a thunk).
3. **Don't try to bridge type identity here**. That's the multi-month "snapshot serialization" item from "Upfront decisions" / "Risk register". Once it lands, the restriction in (1) goes away.

Implement (1) by walking the signature's AST in the macro and rejecting any non-allowlisted `TypeNode`.

### Spec coverage to write

In `spec/compiler/crystal/commands/embed_compiler_spec.cr`, add five tests, each as its own `it` block (each will take ~40 seconds because it builds with `--embed-compiler`):

1. **Unfilled slot returns nil.** Declare a slot; never load a module that fills it; assert `Crystal::Embed.<name>` is `nil`.
2. **Filled slot is callable.** Declare a slot; load a module with a matching top-level def; assert `Crystal::Embed.<name>.try &.call(...)` returns the expected value.
3. **Signature mismatch raises at load time.** Declare a slot as `(Int32) -> Int32`; load a module whose top-level def is `def x(s : String) : String`; assert `load` raises `Crystal::Embed::SignatureMismatch`; assert the slot is still `nil` afterward.
4. **Reload replaces slot value.** Load one impl, call → gets v1; rewrite the file with a different body, reload, call → gets v2.
5. **Multiple modules filling same slot warn but accept.** Load module A filling `foo`; load module B filling `foo`; assert STDERR mentions "previously filled by"; assert `Crystal::Embed.foo` calls B's body.

For the safe-types restriction, add a sixth test asserting that `declare_slot bad, (SomeHostClass) -> Nil` is a compile error with a message pointing to `materialize_files`.

### Estimated scope

- Macro file: ~80 LOC
- `DeclaredSlots` module + `SignatureMismatch`: ~40 LOC
- Loader hook (`fill_declared_slots`): ~60 LOC
- JIT API surface (`last_submission_top_level_def`, `mangled_name_for`): ~50 LOC
- Specs: ~150 LOC
- Total: ~380 LOC

Roughly half a day to a day, dominated by figuring out the JIT-side def-lookup API. The cross-boundary type-identity work is *not* in scope here — only enforcing the restriction is.

### Things to watch for

- **`Atomic(Void*)` on Crystal**: confirm the spelling and that the JIT's existing acquire/release pattern in `fun.cr:install_repl_dispatch_stub` agrees with the macro's load-side ordering. Use `Atomic::Ops.load/store` with `:acquire`/`:release` if `Atomic(T)` doesn't carry orderings.
- **Macro location enforcement**: Crystal's macro engine doesn't directly expose "am I at top level?". Easiest enforcement is to require `declare_slot` to be a method call on the `Crystal::Embed` module — calling it from a method body still expands, but the generated class vars on `Crystal::Embed` would conflict in surprising ways. A `{% raise %}` if `@type != Crystal::Embed.class` (or similar) catches the wrong-context case.
- **Idempotent registration**: re-running a `declare_slot` macro (e.g. because a build dirty-walked the host source twice) should not double-register. `DeclaredSlots.register` overwrites on duplicate name — that's fine because the macro expansion is deterministic.
- **Thread safety**: the JIT REPL is mutex-serialised on load via `Crystal::Embed.@@mutex`. Slot writes happen inside that critical section, so loader-side writes are serialised. Host-side reads happen outside; they go through `Atomic#get` which is safe.
- **Don't accidentally fill on reload of a *different* module**: when `Embed.load("foo.cr")` runs, only foo's top-level defs should count for slot population. The "high-water mark" trick (only consider defs added by the latest `run_code`) handles this — verify the JIT exposes enough state to draw the line.
- **Recovery on `SignatureMismatch`**: the spec for case 3 must verify the slot stayed at its prior value (or `nil` if previously unset). The loader must not write the bad address before checking.

### Done criteria

The six specs above pass. The "what doesn't work yet" sentence in `PROTOTYPE_STATUS.md`'s Embed section drops `declare_slot` and gains a note about the safe-types restriction. No regressions in the existing 32 embed specs or the 1810-example codegen sweep.
