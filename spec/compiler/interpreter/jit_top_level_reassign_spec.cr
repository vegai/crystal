{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Verifies top-level `x = value` reassignment across submissions (lifted
# to `@@__repl_x` and emitted as a runtime store under repl_mode).
# Opt-in via CRYSTAL_JIT_TOP_LEVEL_REASSIGN_SPEC=1.
RUN_JIT_TOP_LEVEL_REASSIGN_SPEC = ENV["CRYSTAL_JIT_TOP_LEVEL_REASSIGN_SPEC"]? == "1"

describe "Crystal::JIT::Repl top-level reassign" do
  it "reassigns top-level locals across submissions and surfaces the new value" do
    pending! "JIT backend only", file: __FILE__, line: __LINE__ unless JIT_BACKEND
    pending! "opt in via CRYSTAL_JIT_TOP_LEVEL_REASSIGN_SPEC=1", file: __FILE__, line: __LINE__ unless RUN_JIT_TOP_LEVEL_REASSIGN_SPEC

    repl = Crystal::JIT::Repl.new

    repl.eval_for_spec("x = 1_i32").value.to_s.should eq("1")
    repl.eval_for_spec("x = 99_i32").value.to_s.should eq("99")
    repl.eval_for_spec("x").value.to_s.should eq("99")

    # Non-primitive value type (Array).
    repl.eval_for_spec("a = [1, 2, 3]").value.to_s.should eq("[1, 2, 3]")
    repl.eval_for_spec("a = [4, 5]").value.to_s.should eq("[4, 5]")
    repl.eval_for_spec("a").value.to_s.should eq("[4, 5]")

    # String.
    repl.eval_for_spec("s = \"hello\"").value.to_s.should eq("\"hello\"")
    repl.eval_for_spec("s = \"world\"").value.to_s.should eq("\"world\"")
    repl.eval_for_spec("s").value.to_s.should eq("\"world\"")

    # Float, Char, Bool, Symbol.
    repl.eval_for_spec("flo = 1.5_f64").value.to_s.should eq("1.5")
    repl.eval_for_spec("flo = 2.75_f64").value.to_s.should eq("2.75")
    repl.eval_for_spec("flo").value.to_s.should eq("2.75")

    repl.eval_for_spec("ch = 'a'").value.to_s.should eq("'a'")
    repl.eval_for_spec("ch = 'z'").value.to_s.should eq("'z'")
    repl.eval_for_spec("ch").value.to_s.should eq("'z'")

    repl.eval_for_spec("bo = true").value.to_s.should eq("true")
    repl.eval_for_spec("bo = false").value.to_s.should eq("false")
    repl.eval_for_spec("bo").value.to_s.should eq("false")

    repl.eval_for_spec("sy = :hello").value.to_s.should eq(":hello")
    repl.eval_for_spec("sy = :world").value.to_s.should eq(":world")
    repl.eval_for_spec("sy").value.to_s.should eq(":world")

    # Range and Tuple.
    repl.eval_for_spec("rg = 1..5").value.to_s.should eq("1..5")
    repl.eval_for_spec("rg = 100..200").value.to_s.should eq("100..200")
    repl.eval_for_spec("rg").value.to_s.should eq("100..200")

    repl.eval_for_spec("tp = {1, 2, 3}").value.to_s.should eq("{1, 2, 3}")
    repl.eval_for_spec("tp = {99, 88, 77}").value.to_s.should eq("{99, 88, 77}")
    repl.eval_for_spec("tp").value.to_s.should eq("{99, 88, 77}")

    # `x = x + 1`-style self-reassign across submissions: parser var
    # scope is seeded from `Session#repl_locals` so the LHS is known.
    repl.eval_for_spec("ctr = 1_i32").value.to_s.should eq("1")
    repl.eval_for_spec("ctr = ctr + 1_i32").value.to_s.should eq("2")
    repl.eval_for_spec("ctr = ctr * 3_i32").value.to_s.should eq("6")
    repl.eval_for_spec("ctr").value.to_s.should eq("6")
  end
end
