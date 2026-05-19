{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Reproduces a user-reported SIGSEGV: in `crystal i --backend=jit`,
#
#   jit:1> require "big"
#   jit:2> BigDecimal.new("abc")
#
# the second submission crashed during exception unwind. The root
# cause was `prepare_session` compiling and running the prelude in a
# Nop submission of its own; the user's `require "big"` then landed
# in a separate JIT module, and an exception raised inside a method
# from that module couldn't unwind cleanly back to the JIT-internal
# rescue. The fix restricts `prepare_session` to pre-parsing the
# prelude (which is fast and side-effect-free) - the first user
# submission re-bundles `[prelude, input]` as one module again.
describe "Crystal::JIT::Repl BigDecimal raising init" do
  it "raises InvalidBigDecimalException after warmup + require big" do
    jit_opt_in!("CRYSTAL_JIT_BIGDECIMAL_SPEC")

    repl = Crystal::JIT::Repl.new
    # Mirror the interactive Repl#run path.
    repl.prepare_session
    repl.run_snippet_for_spec(%(require "big"))
    repl.run_snippet_for_spec(%(BigDecimal.new("abc")))
    # If the segfault returned, this never runs.
    repl.run_snippet_for_spec(%(1 + 1))
  end
end
