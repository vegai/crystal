{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Exercises method redef across submissions via the versioned-body /
# dispatch-slot path. Opt-in via CRYSTAL_JIT_HOT_REDEF_SPEC=1.
RUN_JIT_HOT_REDEF_SPEC = ENV["CRYSTAL_JIT_HOT_REDEF_SPEC"]? == "1"

describe "Crystal::JIT::Repl method redef" do
  it "redefines a top-level method three times across submissions, including a redef-only submission whose new body is reached only by a previously-compiled caller" do
    pending! "JIT backend only", file: __FILE__, line: __LINE__ unless JIT_BACKEND
    pending! "opt in via CRYSTAL_JIT_HOT_REDEF_SPEC=1", file: __FILE__, line: __LINE__ unless RUN_JIT_HOT_REDEF_SPEC

    repl = Crystal::JIT::Repl.new

    repl.run_code("def hot_redef_target; Random.new(42).rand(2_i32..2_i32); end")
    repl.run_code("hot_redef_target").value.to_s.should eq("2")

    repl.run_code("def hot_redef_target; Random.new(42).rand(7_i32..7_i32); end")
    repl.run_code("hot_redef_target").value.to_s.should eq("7")

    repl.run_code("def hot_redef_target; Random.new(42).rand(11_i32..11_i32); end")
    repl.run_code("hot_redef_target").value.to_s.should eq("11")

    # Redef-only submission with no self-call: RedefForce must inject
    # a synthetic call so the new body emits.
    repl.run_code("def hot_redef_foo; Random.new(42).rand(3_i32..3_i32); end")
    repl.run_code("def hot_redef_bar; hot_redef_foo; end; hot_redef_bar").value.to_s.should eq("3")
    repl.run_code("def hot_redef_foo; Random.new(42).rand(13_i32..13_i32); end")
    repl.run_code("hot_redef_bar").value.to_s.should eq("13")

    # Defs with restricted args.
    repl.run_code("def hot_redef_arg(x : Int32); Random.new(42).rand(x..x); end")
    repl.run_code("hot_redef_arg(4_i32)").value.to_s.should eq("4")
    repl.run_code("def hot_redef_arg(x : Int32); Random.new(42).rand((x &* 5)..(x &* 5)); end")
    repl.run_code("hot_redef_arg(4_i32)").value.to_s.should eq("20")

    # Class method under module receiver.
    repl.run_code("module HotMod; def self.compute(x : Int32); Random.new(42).rand((x &+ 10)..(x &+ 10)); end; end")
    repl.run_code("HotMod.compute(6_i32)").value.to_s.should eq("16")
    repl.run_code("module HotMod; def self.compute(x : Int32); Random.new(42).rand((x &* 100)..(x &* 100)); end; end")
    repl.run_code("HotMod.compute(6_i32)").value.to_s.should eq("600")

    # Instance method inside a class body.
    repl.run_code("class HotCalc; def add(x : Int32, y : Int32); Random.new(42).rand((x &+ y)..(x &+ y)); end; end")
    repl.run_code("class HotCalc; def double(n : Int32); add(n, n); end; end")
    repl.run_code("HotCalc.new.double(7_i32)").value.to_s.should eq("14")

    repl.run_code("class HotCalc; def add(x : Int32, y : Int32); Random.new(42).rand((x &* y)..(x &* y)); end; end")
    repl.run_code("HotCalc.new.double(7_i32)").value.to_s.should eq("49")

    # Top-level def with unrestricted args (replayed against cached
    # arg tuples).
    repl.run_code("def hot_unrestricted(x); Random.new(42).rand((x &+ 1)..(x &+ 1)); end")
    repl.run_code("hot_unrestricted(5_i32)").value.to_s.should eq("6")
    repl.run_code("def hot_unrestricted(x); Random.new(42).rand((x &* 10)..(x &* 10)); end")
    repl.run_code("hot_unrestricted(5_i32)").value.to_s.should eq("50")

    # Top-level def with an explicit block_arg restriction.
    repl.run_code("def hot_blk(&b : Int32 -> Int32); b.call(Random.new(42).rand(7_i32..7_i32)); end")
    repl.run_code("def hot_blk_caller; hot_blk { |x| x &+ 100 }; end")
    repl.run_code("hot_blk_caller").value.to_s.should eq("107")
    repl.run_code("def hot_blk(&b : Int32 -> Int32); b.call(Random.new(42).rand(77_i32..77_i32)); end")
    repl.run_code("hot_blk_caller").value.to_s.should eq("177")
  end
end
