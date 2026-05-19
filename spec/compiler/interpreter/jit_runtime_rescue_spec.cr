{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Exercises the JIT-internal begin/rescue wrap around bare-expression
# submissions: a raising user expression must not crash the host.
# Opt-in via CRYSTAL_JIT_RUNTIME_RESCUE_SPEC=1.
RUN_JIT_RUNTIME_RESCUE_SPEC = ENV["CRYSTAL_JIT_RUNTIME_RESCUE_SPEC"]? == "1"

describe "Crystal::JIT::Repl run_snippet runtime rescue" do
  it "catches an unhandled exception in a bare-expression submission and keeps the REPL alive" do
    pending! "JIT backend only", file: __FILE__, line: __LINE__ unless JIT_BACKEND
    pending! "opt in via CRYSTAL_JIT_RUNTIME_RESCUE_SPEC=1", file: __FILE__, line: __LINE__ unless RUN_JIT_RUNTIME_RESCUE_SPEC

    repl = Crystal::JIT::Repl.new

    repl.run_snippet_for_spec(%(require "big"))

    # Bare raising expression: pre-fix this unwound to the host's
    # `rescue` and SIGSEGV'd during `ex.message` interpolation.
    repl.run_snippet_for_spec(%(BigInt.new("cr")))

    # Subsequent submissions still work.
    repl.run_snippet_for_spec(%(BigInt.new("123")))

    # Class-var-assigning submission whose RHS raises.
    repl.run_snippet_for_spec(%(a = BigInt.new("cr")))

    # Successful class-var assign still works through the same path.
    repl.run_snippet_for_spec(%(b = BigInt.new("42")))
    repl.run_snippet_for_spec(%(b))
  end
end
