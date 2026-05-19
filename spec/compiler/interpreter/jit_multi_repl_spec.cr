{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Verifies the JIT submission inherits the host's signal handlers, so a
# subsequent host-side `Process.run` is not wedged in `epoll_wait`.
# Opt-in via CRYSTAL_JIT_MULTI_REPL_SPEC=1.
describe "Crystal::JIT::Repl multi-submission with full prelude" do
  it "host Process.run and subsequent submissions survive the first JIT __crystal_main" do
    jit_opt_in!("CRYSTAL_JIT_MULTI_REPL_SPEC")

    # Sanity-check: a host backtick works before any JIT submission.
    `echo pre`.chomp.should eq("pre")

    repl = Crystal::JIT::Repl.new
    repl.run_snippet_for_spec("a = 1")

    # Host backtick after a JIT submission must still complete.
    `echo post`.chomp.should eq("post")

    # Require whose top-level macros run shell commands must not hang
    # (a semantic error from http/server is acceptable; a wedge is not).
    repl.run_snippet_for_spec(%(require "http/server"))
  end
end
