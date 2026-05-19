{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Verifies a JIT-emitted `Process.run` / backtick completes via the
# host-reaper external_reaper bridge (no infinite wait on the JIT-side
# `@channel.receive`).
# Opt-in via CRYSTAL_JIT_PROCESS_RUN_SPEC=1.
describe "Crystal::JIT::Repl Process.run from user code" do
  it "backtick from JIT-emitted user code completes (no infinite hang)" do
    jit_opt_in!("CRYSTAL_JIT_PROCESS_RUN_SPEC")

    crystal_bin = File.expand_path("./bin/crystal", Dir.current)
    output = IO::Memory.new
    started = Time.monotonic
    status = Process.run(
      crystal_bin,
      ["i", "--backend=jit", "-e", "puts `echo hi from jit`.chomp"],
      output: output,
      error: STDERR,
    )
    elapsed = Time.monotonic - started

    status.success?.should be_true
    output.to_s.lines.last.should eq("hi from jit")
    # Wake-latency regression bound. Pre-fix the StackPool fallback
    # floored at ~5 s; pick 30 s as a comfortably above-floor cap that
    # still catches the regression on a loaded CI host without
    # flaking on momentary scheduler stalls.
    elapsed.should be < 30.seconds
  end
end
