#!/usr/bin/env bash
# Run the opt-in JIT-only interpreter specs each in its own process.
# Combining them with the broader suite under one process triggers the
# multi-Repl-with-full-prelude wedge documented in PROTOTYPE_STATUS.md.
#
# Usage: run_jit_optin_specs.sh <interpreter_spec_binary>
#
# Exits non-zero if any spec fails. Runs all specs even if earlier
# ones fail so a single regression doesn't mask the rest.
#
# Three opt-in specs are intentionally excluded from this runner; each
# is still gated by its `CRYSTAL_JIT_*_SPEC=1` env var so a developer
# can run it manually:
#   - jit_top_level_reassign_spec: under `--location` filtering the
#     spec runner reports 0 examples maybe-3-times-out-of-4 even with
#     the env gate set; the spec passes reliably when invoked
#     standalone (without `--location`). Likely a `pending!` /
#     line-filter interaction in the spec runner.
#   - jit_loop_bench_spec: a wall-clock benchmark (100M loops). Runs to
#     completion but takes 30s+ and isn't a regression gate.
#   - jit_bigdecimal_spec: loads the full prelude via `require "big"`,
#     which clashes with the full-prelude multi-Repl wedge if any
#     other prelude-loading spec ran in the same process.

BIN="${1:-.build/interpreter_spec}"

declare -A SPECS=(
  [jit_const_redef_spec]=CRYSTAL_JIT_CONST_REDEF_SPEC
  [jit_cross_submission_spec]=CRYSTAL_JIT_CROSS_SUBMISSION_SPEC
  [jit_eval_source_spec]=CRYSTAL_JIT_EVAL_SOURCE_SPEC
  [jit_hot_redef_spec]=CRYSTAL_JIT_HOT_REDEF_SPEC
  [jit_layout_refusal_spec]=CRYSTAL_JIT_LAYOUT_REFUSAL_SPEC
  [jit_multi_repl_spec]=CRYSTAL_JIT_MULTI_REPL_SPEC
  [jit_process_run_spec]=CRYSTAL_JIT_PROCESS_RUN_SPEC
  [jit_program_name_spec]=CRYSTAL_JIT_PROGRAM_NAME_SPEC
  [jit_runtime_rescue_spec]=CRYSTAL_JIT_RUNTIME_RESCUE_SPEC
  [jit_symbol_growth_spec]=CRYSTAL_JIT_SYMBOL_GROWTH_SPEC
  [jit_value_marshal_spec]=CRYSTAL_JIT_VALUE_MARSHAL_SPEC
)

failed=()
for spec in "${!SPECS[@]}"; do
  envvar="${SPECS[$spec]}"
  path="spec/compiler/interpreter/${spec}.cr"
  line=$(grep -n '^[[:space:]]*it ' "$path" | head -1 | cut -d: -f1)
  echo "==> ${spec} (${envvar}=1) line ${line}"
  if ! env "$envvar=1" CRYSTAL_INTERP_BACKEND=jit "$BIN" --location "$path:$line"; then
    failed+=("$spec")
  fi
done

if (( ${#failed[@]} > 0 )); then
  echo "Failed JIT opt-in specs: ${failed[*]}" >&2
  exit 1
fi
