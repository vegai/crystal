# JIT REPL warmup: design notes

## Goal

At `crystal i --backend=jit`, the prompt appears instantly and the
first user command runs in the same time budget as every later
command (~tens of ms, not ~2s). Multi-threaded background work
covers the prelude compile while the user reads the banner and
types. Nothing crashes.

The current state on this branch is a safe-but-shallow workaround:
`prepare_session` only pre-parses the prelude. Parse is tiny, so
the user still pays the codegen cost on the first command. The
threading scaffold (`Fiber::ExecutionContext::Isolated`,
`kick_off_warmup`, `wait_for_warmup`, the "still warming up" line)
is in place but underused. This document is about how to put real
work into the background safely.

## Why the original prepare_session crashed

`Session#compile` produces a fresh `LLVM::Module` per submission
and hands it to LLJIT via `add_llvm_ir_module`. With the original
prepare_session that compiled and invoked the prelude in a Nop
submission, the layout was:

- submission #1 (warmup, Nop): module 1 contained the prelude
- submission #2 (user's `require "big"`): module 2 contained the
  big stdlib's top-level code, type definitions, etc.
- submission #3 (user's `BigDecimal.new("abc")`): module 3 contained
  the call site, the JIT-internal rescue, and the BigDecimal method
  bodies needed by the call

`BigDecimal#initialize` raised inside module 3. The unwind walks
back to the catch frame in module 3's `__crystal_main`. Conceptually
that should be cheap — the catch is in the same module as the
raise. But the segfault landed inside libgcc_s' unwind path, which
means the unwinder either crossed into module 2/1 along the way
(possible if inlining or PLT thunks routed it through them) or
encountered an FDE/CIE inconsistency on the module-3 boundary.

The pre-warmup architecture sidesteps the problem because the
first user submission **bundles** the prelude AST with the input.
Everything that runs on the first command lives in one module.
Unwinding stays inside one CIE/FDE family and works.

So the bug is *cross-module exception unwind*, not anything about
threading or `prepare_session`'s timing.

## Approach landscape

### A. Semantic-only warmup (attempted 2026-05-19, does not work as described)

Have `prepare_session` do parse + semantic-walk for the prelude.
Stash the resulting `Program` state. The first user submission
runs against an already-typed program; semantic walks just the
user's input. Codegen for the prelude still happens on the first
command.

- **What it costs the user (if it worked):** the front-end (~30-40%
  of the 2s budget on a sample profile) moves to the background;
  codegen stays on the foreground.
- **What actually happened:** the BigDecimal spec regresses in a new
  way. Two variants were tried:
  1. **Input-only walk.** Cache the typed prelude AST in `Session`;
     on first user `compile`, semantic walks only the user input,
     then bundle `[typed_prelude, walked_input]` for codegen.
     Result: codegen of the first user submission hits
     `BUG: {{ @type.name.stringify }} (Crystal::MacroExpression)
     at src/class.cr:115:5 should have been expanded`. Some typed
     `Def` for `Class#name` reaches `codegen_fun` with an
     unexpanded macro in its body, even though `cleanup_transformer`
     should have replaced it. The most likely culprit is the
     interaction between `cleanup_transformer.@transformed` (set
     of already-processed defs, with `compare_by_identity`) and
     macro expansion ordering across split walks: a `Class#name`
     instantiation created during the user-input walk reaches
     codegen via a deep call chain (`ExceptionHandler` → `Call` →
     `codegen_dispatch` → `target_def_fun` → `codegen_fun`), and
     somewhere along that chain a `target_def` body wasn't
     transformed. Not localised yet; reproducing requires running
     `CRYSTAL_INTERP_BACKEND=jit CRYSTAL_JIT_BIGDECIMAL_SPEC=1
     .build/interpreter_spec --location spec/compiler/interpreter/jit_bigdecimal_spec.cr:20`.
  2. **Bundle re-walk.** On first compile, build
     `Expressions.new([typed_prelude, input])` and run
     `semantic_for_submission` against the whole bundle (hoping
     `TopLevelVisitor` would be idempotent on re-walking the
     prelude). It is not: `Error: alias Char is already defined`
     in `src/lib_c.cr:16`. Other alias / annotation / type
     decls would hit the same issue. The session-reset path
     covers it visually (the spec returns "passes" via the retry),
     but the warmup work is being thrown away.
- **Cross-module bug:** the doc's earlier claim that A "sidesteps"
  the crash was wrong - splitting semantic into two walks
  introduces its own codegen-time failure mode, separate from the
  unwind crash B is meant to fix.

Before retrying A, instrument `cleanup_transformer.transform(Call)`
to log when a `target_def` is added to `@transformed` and when its
body still contains a `MacroExpression` after `target_def.body.transform(self)`.
That should pinpoint which `Def` is being missed.

The autocomplete-during-warmup race (`ReplReader#auto_complete`
reading `@program.types` while the warmup thread is mutating it)
is a real bug independent of A. The gate (`session.warmup_done?`
returning false until the warmup atomic flips) can ship on its
own, even with the warmup itself being parse-only.

### B. Pin the prelude module, fix cross-module unwind (full win)

Compile and link the prelude module in the background. Leave it
pinned in LLJIT. The first user command compiles only the input
as its own module; calls into the prelude resolve via LLJIT's
symbol lookup. This is what the original `prepare_session` tried
to do.

Making this work means fixing cross-module unwind. Four things to
verify, in roughly increasing depth:

1. **FDE registration.** RTDyldObjectLinkingLayer (LLJIT's default
   linker) calls `__register_frame` for each module's `.eh_frame`
   section at finalisation. Confirm this actually fires for our
   submissions; look for `__register_frame` calls in a perf trace
   or just stick a breakpoint in libgcc_s' `_Unwind_Find_FDE` and
   walk through a working vs broken scenario.

2. **CIE consistency.** Every JIT module emits its own `.eh_frame`
   with a CIE that references `__crystal_personality`. If LLVM
   ends up emitting incompatible CIEs across our modules (e.g.
   different augmentation strings or different LSDA encodings),
   the unwinder will trip when it crosses a module boundary.
   Dump `.eh_frame` from two consecutive JIT modules with
   `llvm-dwarfdump --eh-frame` and confirm the CIEs are
   compatible.

3. **Personality function reachability.** `__crystal_personality`
   lives in the host binary. JIT modules reference it via the
   personality slot. Confirm the slot is resolved correctly
   across all submissions — a stale slot would route through
   garbage. The slot lookup runs at materialisation; if a
   submission lazily-loads, the personality might be unresolved
   until the first call.

4. **Type-info coherence.** The catch clause matches the raised
   exception by its type ID. Crystal emits a LinkOnceODR
   `T:type_id` const per exception type. If submission 1 emitted
   `InvalidBigDecimalException:type_id` with value X, and
   submission 3 also defined it with value Y (LinkOnceODR resolves
   to whichever the linker picked first), the catch table in the
   landing pad won't match the runtime value. The `add_finalizer`
   thunk story bites similarly.

If 1-4 all check out and the crash still reproduces, the next
hypothesis is an RTDyld bug specifically around JIT-emitted EH
frames. The fix path is to switch the LLJIT to use
`JITLinkerObjectLinkingLayer` — the newer ORC linker, which has
materially better support for EH and cross-module work. Crystal's
ORC bindings would need a small extension to expose the alternate
linker constructor; LLVM's C API supports it from 14 onward.

This is the path to "instant prompt + instant first command" and
is the long-term answer.

### Crash anatomy (2026-05-19, gdb walk-through)

A short experiment with `CRYSTAL_JIT_NOP_BUNDLE_WARMUP=1` (a temporary
flag that reinstates the original Nop-bundle warmup) reproduced the
BigDecimal-spec crash deterministically and let gdb attach. Findings
that refine the four verification points above:

- The SIGSEGV does **not** land inside libgcc_s. `_Unwind_RaiseException`
  returned successfully; the crash PC is in JIT-mapped memory
  (`0x7fff…` range, well above the host binary's `0x55…` base and
  outside libgcc_s/libc/libstdc++ mappings).
- The crash PC sits one byte past the end of an indexed-load switch
  prologue (`lea -off(%rip),%rax; movslq (%rax,%rcx,4),%rcx`). `%rcx`
  before the load equals an exception-type-id (1545 in the failing
  scenario, 81 in a benign case). The instruction immediately
  preceding the crash address is the entry sequence of a *different*
  JIT-emitted function (`endbr64; mov %edi,%eax; mov %rax,-0x8(%rsp)…`).
- That means the unwinder finished its phase-2 walk, computed a
  landing-pad PC, called `_Unwind_SetIP`, and resumed — but the
  resumed PC pointed *into the middle of an unrelated JIT function*.
  No corruption of the unwinder itself; the LSDA-derived landing pad
  PC is just wrong.
- The bundled-prelude scenario does *not* re-emit `BigDecimal#initialize`
  in mod.1; only mod.2 (the call site) emits a `linkonce_odr` copy.
  So both the working and the broken scenarios have the raise body
  and the catch frame in the same module IR. The bug is therefore not
  "the raise lives in module A and the catch lives in module B". It
  is something more like "after registering N FDE tables in the JIT
  dylib, the unwinder's PC→FDE lookup returns the wrong FDE for the
  catch frame's PC, so the LSDA used to compute the landing pad is
  the wrong function's LSDA."
- Crystal's LLVM bindings currently expose only the LLJIT's default
  RTDyld linker; there is no `set_object_linking_layer` hook. Approach
  B's "switch to JITLinker" branch therefore needs the binding
  extension before the linker swap can even be attempted.

Concrete next probe before any code work: set a conditional
breakpoint in `__crystal_personality` that prints the chosen
`landingPad`, `ttype_index`, and the FDE address it received. Run
the Nop scenario; the personality should be entered once per frame
of the cleanup walk, and the landing-pad PC it returns is what
later faults. If the personality returns a sensible landing-pad PC
but the unwinder resumes elsewhere, the bug is in
`_Unwind_SetIP`/`__register_frame` interaction. If the personality
itself computes the wrong landing-pad PC, the bug is in the LSDA
encoding or the FDE the personality was handed.

Either way, the autocomplete gate (recommended path step 2) is
unrelated to this and still ships independently. The current
parse-only warmup does not actually mutate `@program.types` —
Normalizer does not touch program state — so the doc's earlier
claim of a *current* race on `auto_complete` was over-stated.
The gate becomes load-bearing the moment any semantic-walk work
moves to the warmup thread.

### C. Cache the prelude object file (cold-start win, doesn't fix the bug)

Use `LLVMContext::setObjectCache` to cache the compiled prelude
object. On next startup, load the cached object directly. Saves
parse + semantic + codegen on warm starts.

- Doesn't address the cross-module unwind bug — the cached prelude
  still lives in its own module.
- Cache invalidation is its own can of worms: Crystal compiler
  version, prelude file mtimes, LLVM version, target triple, plus
  any compile flag that changes IR.
- Only helps repeat startups, not first-ever startup.

Worth doing eventually but not on the critical path.

### D. Single-module accumulation (rejected)

Recompile everything into one module on every submission. Trivially
correct (no cross-module unwind, no warmup needed) but kills the
incremental compile that the whole JIT design rests on. After 10
submissions the per-submission time grows with the prelude + all
prior input. Don't.

## Threading: what's safe to do in the background

`Fiber::ExecutionContext::Isolated` was the right primitive choice
— it gives us a dedicated OS thread for the warmup work without
requiring the rest of the program to opt into the multi-threaded
scheduler. The constraints to respect:

- **`@program` is not thread-safe.** Any Crystal Hash mutation
  during semantic walk on the warmup thread races with reads from
  the main fiber. The main fiber's only `@program` accessor during
  warmup is `ReplReader#auto_complete` via
  `session.repl_method_names_matching`, which reads
  `@program.types`. The fix is to gate autocomplete on a
  `@warmup_done` Atomic flag and return keyword-only matches until
  the warmup releases.

- **`@session.@main_visitor` is not thread-safe.** The warmup
  fiber owns it until `prepare_session` returns. The main fiber
  must not touch the session until `wait_for_warmup` clears.
  This is already true in the current scaffold (`wait_for_warmup`
  runs before `run_snippet`), so it's fine.

- **LLJIT itself IS thread-safe** for `add_llvm_ir_module` and
  `lookup` calls. ORC was designed for concurrent code generation.
  This is the only thing on this list that LLVM gives us
  out-of-the-box.

- **Boehm thread registration.** `Fiber::ExecutionContext::Isolated`
  spawns via `Thread.new`, which Crystal wraps with
  `GC_pthread_create`. Boehm sees the thread; finalisers and
  allocations on it work. Verified during the Isolated experiment
  earlier on this branch.

- **EH-frame registration during materialisation.** `lljit.add_llvm_ir_module`
  on the warmup thread followed by `lljit.lookup` on the main
  fiber's thread should be safe (ORC handles cross-thread
  materialisation). But `__register_frame` is called from
  whichever thread runs the materialisation hooks. If libgcc_s's
  FDE table is per-thread (it isn't, in practice, on Linux
  x86-64) this would matter; on the platforms we target it's a
  process-wide table so we're fine.

## Recommended path

1. **Earlier (2026-05-19, committed):** parse-only `prepare_session`.
   Kept the threading scaffold in place while the cross-module
   regression that killed the original prewalk attempt was diagnosed.
   Superseded by step 3.

2. **Landed (2026-05-19):** autocomplete gate. `Session#warmup_done?`
   is an `Atomic(Int32)`; `Repl#kick_off_warmup` and `synchronous_warmup`
   bracket the warmup with `mark_warmup_started`/`mark_warmup_done`,
   and `ReplReader#auto_complete` falls back to keyword-only matches
   while the gate is closed. Load-bearing now that approach A's
   semantic walk runs on the warmup thread.

3. **Landed (2026-05-19) — approach A is the only path:**
   `Session#walk_prelude_for_warmup` runs the full semantic walk over
   the prelude AST on the warmup thread; `compile_with_walked_prelude`
   bundles the typed prelude with the input on the first submission
   and runs semantic only on the input. No env var gate — every
   interactive REPL run prewalks. The `bundle_submission` path stays
   for `-e` mode and file/spec entry points that never call
   `prepare_session`; on those, the legacy single-walk over
   `[prelude, input]` still applies.

   The variant-1 codegen BUG (`{{ @type.name.stringify }} ... should
   have been expanded`) traced to a different mechanism than the
   doc's earlier hypothesis: `on_new_subclass` recalculation during
   a type-graph-changing submission (`require "big"`) creates new
   typed_defs deep in *cached* prelude parent bodies. The AST-driven
   `cleanup_transformer` walk doesn't reach those typed_defs because
   the parent bodies are already in `@transformed` from the prelude
   cleanup pass and get skipped, leaving the new bodies with
   `ExpandableNode`s codegen would BUG on.

   Fix: on dirty submissions, `semantic_for_submission` resets
   `cleanup_transformer.@transformed` before the AST walk and calls
   `sweep_typed_def_bodies` afterwards. The sweep walks every
   `def_instance` in the type graph (top-level types, nested types,
   generic instantiations, metaclasses, virtual types) and
   re-transforms any body still carrying a `ResidualExpandableFinder`-flagged node.
   `BigDecimal.new("abc")` after `require "big"` passes the
   `jit_bigdecimal_spec`.

   Follow-up: the freshly bundled `Expressions` in
   `compile_with_walked_prelude` never goes through `visit_main`,
   so its `.type` defaults to nil and `run_jit`'s
   `node.type? || @program.nil_type` lookup sized the wrapper as
   void; the user's first command returned `nil` for any
   value-bearing expression. Fix: copy `walked_input.type` onto the
   bundle before `run_jit`. Regression locked in by
   `jit_warmup_autocomplete_spec.cr` ("prewalk warmup bundle type")
   under the `primitives` prelude (the full prelude version of the
   spec exhausts JIT-mapped memory and rolls into the multi-Repl
   wedge that the bytecode interpreter specs run into in the same
   process).

   Measured (single-shot, prelude = full, on this branch): the
   warmup thread runs ~1.1 s of semantic work in the background
   and the user-visible first command drops from ~1.9 s to ~0.8 s.
   Total wall-clock to the second command is unchanged (the
   background work runs while the user reads the banner).

   The doc's earlier claim of "prewalk-mode edge cases ... GC-warn
   or segfault under heavy spec churn" was misattributed: re-running
   the same opt-in spec sequence without prewalk produces the same
   crashes, so the wedge is the well-known multi-Repl-per-process
   condition (`run_jit_optin_specs.sh` runs each opt-in spec in its
   own process for this reason) and is independent of A.

   Warmup is silent on STDERR; the earlier "JIT: still warming up"
   / "JIT: ready (X.XXs)" status lines were removed — codegen for
   the user's first command is the only remaining user-visible
   delay, and that delay can't be eliminated without approach B.

4. **Long-term — approach B:** debug cross-module unwind. Start
   by dumping `.eh_frame` and type-ID consts from the two relevant
   submissions of the BigDecimal repro and comparing. The four
   verification points above are the script. If RTDyld is at
   fault, expose JITLinker through Crystal's ORC bindings. B is
   still the only path to "instant first command" since A only
   moves the semantic-walk cost to the background; codegen still
   runs on the user's first submission.

5. **Eventually — approach C:** when B lands and the warmup is
   bottlenecked on codegen alone, an object cache shaves the
   second-launch time on cold disks.

## What not to do

- **Don't re-introduce the Nop-bundle warmup before B is fixed.**
  The cross-module bug is the actual root cause, not the warmup
  strategy.
- **Don't run the warmup on a plain `spawn` fiber.** In
  single-threaded mode the fiber doesn't preempt the read loop;
  CPU-bound compile work runs to completion before the fiber
  yields, so the wall-clock is identical to synchronous.
- **Don't pass `same_thread: true` to the warmup spawn.** Same
  reason as above.
- **Don't try to extend a finalised LLJIT module.** ORC modules
  are immutable after materialisation; "add more code to the
  prelude module later" is not a thing the LLVM bindings expose.

## Open questions

- The 2026-05-19 attempt at approach A made `MainVisitor.new(from_main_visitor:)`
  not the suspect: the visible failure was a `Class#name` instantiation
  reaching codegen with an unexpanded macro, which points at
  `cleanup_transformer`'s `@transformed` bookkeeping across two
  `visit_main` calls (one on prelude, one on input). Concretely:
  walk through the spec under a debugger, and at the moment
  `codegen_fun` hits the BUG, dump the offending `target_def`'s
  identity and check whether it was ever added to
  `cleanup_transformer.@transformed`. That answers whether the
  bug is "missed call site" or "transform ran but didn't expand".
- The `Fiber::ExecutionContext::Isolated` cleanup pushes the
  thread back to the pool when its fiber finishes. If a later
  fiber (unrelated work) gets that thread and the JIT-emitted
  code references something that was thread-local on the warmup
  thread, we'd see a use-after-thread-exit. We don't currently
  use TLS in any JIT-emitted Crystal code, but if `thread_local`
  class vars ever appear in a hot-reload scenario, revisit this.
