# JIT Interpreter Prototype Status

`bin/crystal i --backend=jit FILE` dispatches to `Crystal::JIT::Repl` and runs the file through the AOT codegen path plus LLVM ORC JIT, with full prelude and FFI parity. `crystal i --backend=jit -e SOURCE` is the one-shot variant; bare `crystal i --backend=jit` enters an interactive REPL. Canonical FFI demo: `require "big"; puts BigInt.new("999999999999999999999999") * 7` produces the same output under JIT and AOT.

The interactive REPL persists defs, top-level locals, and `require`s across submissions through cross-module symbol resolution and a synthetic `__REPLState` module wrap. Line editing, multi-line input, history, and tab completion all work via `Crystal::JIT::ReplReader < Crystal::ReplReader`. Runtime exceptions in user submissions are caught inside the JIT module so the unwind never crosses the JIT/host boundary.

## Per-phase progress

| phase | status | summary |
|---|---|---|
| 0 | done | branch, scaffolding, `--backend=jit` dispatch |
| 1 | done | `Crystal::JIT::Session` runs codegen + ORC JIT end-to-end with full prelude |
| 2 | done | cross-submission state via `repl_emitted_target_defs` / `repl_emitted_externals` and shared `LLJIT`/`JITDylib`/`LLVM::Context` |
| 2.5 | done | result pretty-print in the REPL (`=> <inspect>`) |
| 3a | done | local lifter + `__REPLState` module wrap |
| 3b | done | `get_global_var` emit tracking |
| 3c | done | thread-local class vars under cross-submission (native-TLS targets only) |
| 4 | done | spec harness env-var dispatch; 783 specs / 0 errors / 0 failures / 16 pending under `CRYSTAL_INTERP_BACKEND=jit` |
| 5 | done | FFI parity: `require "big"` works end-to-end |
| 6 | done | microbench done; broad coverage matrix is the Phase 4 result |
| 7a | done | wrapper cache: repeat submissions skip codegen + ORC, drop to ~0 ms |
| 7b | done | explicit `CodeGenOptLevel::None` saves ~1.1 s cold start at small cached-exec cost |
| 7c | done | skip `AbstractDefChecker` / `RecursiveStructChecker` on clean submissions; warm-Repl compile 35 ms → 2 ms |
| 7d | dropped | lazy compilation conflicts with Phase 9 dispatch indirection |
| 8 | done | line-editing parity via `Crystal::JIT::ReplReader` |
| 9.1 | done | method redef via dispatch slots + cold `Repl#reset` |
| 9.2 | done | constants re-init on redef |
| 9.3 | done | per-class instantiation tracking + layout-change refusal |
| 9.4 | partial | acquire/release ordering on dispatch slots; full stop-the-world deferred |
| 9.5a | done | broader method-redef coverage (explicit-restriction args, class methods, instance methods, replay from `def_instances` for unrestricted args) |
| 9.5b | done | benchmark + doc closing pass |

## Benchmark snapshot

Measured on CachyOS / Crystal 1.21.0-dev / LLVM 22.1.5. Wall-clock, smallest-of-three by hand.

| measurement | pre-Phase-7 | post-Phase-7a/b/c | post-Phase-9.1 | post-Phase-9.x |
|---|---:|---:|---:|---:|
| full prelude compile (cold) | ~3.0 s | ~1.9 s | ~2.0 s | ~1.9 s |
| fresh warm-Repl submission, clean expression | n/a | ~2 ms + body exec | ~2 ms + body exec | ~3 ms + body exec |
| fresh warm-Repl submission, type-mutating (Def) | n/a | ~34 ms + body exec | ~34 ms + body exec | ~30 ms + body exec |
| fresh warm-Repl submission, redef (RedefForce + dispatch) | n/a | n/a | n/a | ~88 ms |
| cached-wrapper re-invoke (same source) | n/a | ~0 ms | ~0 ms | ~0 ms |
| 100M `Int#times` loop, cached exec | n/r | n/r | n/r | ~45 ms |

| Program | bytecode `crystal i` | JIT pre-7b | JIT post-7b (`None`) | JIT post-9.1 | JIT post-9.x | AOT `-O0` | AOT `--release` |
|---|---:|---:|---:|---:|---:|---:|---:|
| `puts "ok"` | 1.26 s | 3.10 s | 2.06 s | 1.95 s | 2.00 s | 0.002 s* | 0.002 s* |
| `fib(35)` | 145 s | 3.18 s | 2.17 s | 2.01 s | 2.05 s | 0.043 s | 0.029 s |
| 100M `sum &+= i` loop | n/a | 3.23 s | 2.52 s | 1.96 s | 2.11 s | 0.047 s | 0.002 s |

\* AOT numbers exclude ~2 s compile time. Reproducible loop harness at `spec/compiler/interpreter/jit_loop_bench_spec.cr` (opt-in via `CRYSTAL_JIT_LOOP_BENCH_SPEC=1`).

## Out of scope

- **Emulated TLS targets** (Android, some embedded toolchains). LLVM's emutls lowering emits `__emutls_v.<name>` symbols outside Crystal codegen; the JIT bails out on detection. Non-issue on Linux/macOS x86_64/aarch64.
- **Full stop-the-world for dispatch-slot updates** (Phase 9.4). Acquire/release pairs are correct on x86_64 and aarch64; ARM32 / RISC-V need explicit pause-the-world (scheduler-layer change).
- **Yield-method redef without an explicit `&block` type restriction**. `codegen_call_with_block` inlines the body into the caller; a slot swap has nothing to swap. Real fix requires call-site recompilation or routing yield through a dispatch-callable thunk.
- **IR-level passes for hot-loop performance**. `IRTransformLayer` is identity by design; enabling `mem2reg` / `instcombine` would close the AOT-`-O0` gap on tight loops, but the inliner-bearing shape conflicts with Phase 9's call-site indirection.

## Known issues

- One spec is excluded from the JIT subprocess runner as known-flaky: `jit_top_level_reassign_spec` under `--location` filtering reports 0 examples ~3-of-4 runs. Passes reliably when invoked without `--location`. Still runnable manually under its gate.
- `Crystal::EventLoop.@@registry` is append-only. Each `Repl#reset` plus subsequent submission registers another EventLoop instance from JIT-mapped memory; entries from disposed Sessions remain in the registry. `interrupt_all` walks them all, so a cross-context wake on a post-reset Repl touches stale entries pointing at unmapped JIT pages. Interactive use stays single-Session in the prototype, so the registry stays bounded in practice; a real fix needs Session-scoped registration.
- `Crystal::JIT::Session.@@alive` is drained on `Session#dispose` and on the host `at_exit` hook armed when the first Session is constructed. Specs call `SpecSupport.dispose_all_sessions` between runs; interactive use that exits cleanly (Ctrl-D, `exit`, unhandled exception that reaches the main fiber) now drains via the hook. SIGKILL still leaks, but the prototype no longer keeps a pin past a normal process exit.
- `Crystal::JIT::RedefForce.@@counter` is process-wide (`Atomic(Int32)`) for synthetic-name uniqueness. The counter is fine for interactive use but makes spec parallelism harder — concurrent specs in the same process share the counter. Threading the counter through Session would remove the global at the cost of a parameter on every helper; not worth it for the prototype.

## Open direction

Prototype meets its stated goals (full prelude, FFI parity via `require "big"`, hot reload, 783-spec parity with the bytecode backend). The natural fork is between:

- **Upstreaming**: split the diff into landable pieces, write user-facing docs, decide on a feature flag and spec-suite policy for the opt-in JIT specs.
- **Push further**: pick up one of the out-of-scope items above. IR-level passes are the highest-leverage on observable performance; yield-method redef is the most user-visible remaining limit.

## Verification commands

```sh
# File mode, full prelude
echo 'puts(1 + 1)' > /tmp/jit.cr
./bin/crystal i --backend=jit /tmp/jit.cr

# FFI parity (canonical demo)
echo 'require "big"; puts BigInt.new("999999999999999999999999") * 7' > /tmp/jit_big.cr
./bin/crystal i --backend=jit /tmp/jit_big.cr

# Interactive REPL
./bin/crystal i --backend=jit
jit> puts(1 + 1)
2
jit> exit
```
