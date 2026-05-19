{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Regression: `Session#compile_with_walked_prelude` builds a fresh
# `Expressions` to bundle the warmup-walked prelude with the user
# input. The bundle node itself is not walked, so its `.type` would
# default to nil and `Session#run_jit` would size the wrapper as
# void; the user's first command would return `nil` even for a
# value-bearing expression. The fix copies `walked_input.type` onto
# the bundle.
#
# Uses the `primitives` prelude so the spec doesn't load the full
# stdlib (the regression is the type-propagation in the bundle, not
# anything prelude-specific).
describe "Crystal::JIT::Repl prewalk warmup bundle type" do
  it "first command after prewalk returns the value, not nil" do
    pending! "JIT backend only", file: __FILE__, line: __LINE__ unless JIT_BACKEND

    repl = Crystal::JIT::Repl.new
    repl.prelude = "primitives"
    Crystal::JIT::SpecSupport.apply_stubs(repl, "")
    repl.prepare_session
    value = repl.run_code("1_i32 &+ 2_i32")
    value.value.to_s.should eq("3")
  end
end

# Tab during the background warmup must not race the warmup fiber's
# accesses to `@program.types` and friends. `Session#warmup_done?`
# gates `ReplReader#auto_complete`'s call into the program-touching
# helpers so the user only sees keyword matches while the warmup
# still holds the program semantic state.
describe "Crystal::JIT::Repl warmup autocomplete gate" do
  it "warmup_done? reflects mark_warmup_started / mark_warmup_done" do
    pending! "JIT backend only", file: __FILE__, line: __LINE__ unless JIT_BACKEND

    program = Crystal::Program.new
    session = Crystal::JIT::Session.new(program)
    session.warmup_done?.should be_true

    session.mark_warmup_started
    session.warmup_done?.should be_false

    session.mark_warmup_done
    session.warmup_done?.should be_true
  ensure
    session.try &.dispose
  end

  it "auto_complete returns keyword-only matches while the warmup gate is closed" do
    pending! "JIT backend only", file: __FILE__, line: __LINE__ unless JIT_BACKEND

    program = Crystal::Program.new
    session = Crystal::JIT::Session.new(program)
    reader = Crystal::JIT::ReplReader.new(session: session)

    session.mark_warmup_started
    heading, matches = reader.auto_complete("d", "d")
    heading.should eq("Keywords:")
    matches.should contain("def")

    session.mark_warmup_done
    heading_after, matches_after = reader.auto_complete("d", "d")
    heading_after.should eq("Keywords:")
    matches_after.should contain("def")
  ensure
    session.try &.dispose
  end
end
