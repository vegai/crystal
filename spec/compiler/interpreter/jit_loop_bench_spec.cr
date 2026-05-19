{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Cached-exec bench for tight integer loops under the JIT backend.
# Prints first/cached/cached timings to stdout and asserts the computed
# sum so a codegen regression that still produces output fails the spec.
# Opt-in via CRYSTAL_JIT_LOOP_BENCH_SPEC=1.
JIT_LOOP_BENCH_PRELUDE = ENV["CRYSTAL_JIT_LOOP_BENCH_PRELUDE"]? || "prelude"

# Sum 1..N (inclusive) and 0..N-1 for N = 100_000_000.
JIT_LOOP_BENCH_SUM_1_TO_N   = "5000000050000000"
JIT_LOOP_BENCH_SUM_0_TO_N_1 = "4999999950000000"

private def bench(label : String, code : String, expected : String)
  jit_opt_in!("CRYSTAL_JIT_LOOP_BENCH_SPEC")

  repl = Crystal::JIT::Repl.new
  repl.prelude = JIT_LOOP_BENCH_PRELUDE

  t0 = Time.monotonic
  v1 = repl.run_code(code)
  t1 = Time.monotonic

  v2 = repl.run_code(code)
  t2 = Time.monotonic

  v3 = repl.run_code(code)
  t3 = Time.monotonic

  puts ""
  puts "[#{label}] result: #{v1.value.inspect}"
  puts "[#{label}] first invoke (compile + execute): #{(t1 - t0).total_milliseconds.round(1)} ms"
  puts "[#{label}] second invoke (cached, execute): #{(t2 - t1).total_milliseconds.round(1)} ms"
  puts "[#{label}] third invoke (cached, execute): #{(t3 - t2).total_milliseconds.round(1)} ms"

  v1.value.to_s.should eq(expected)
  v2.value.to_s.should eq(expected)
  v3.value.to_s.should eq(expected)
end

describe "Crystal::JIT::Repl 100M loop bench" do
  it "Range#each" do
    bench "Range#each",
      "sum = 0_i64; (1_i64..100_000_000_i64).each { |i| sum &+= i }; sum",
      JIT_LOOP_BENCH_SUM_1_TO_N
  end

  it "Int#times" do
    bench "Int#times",
      "sum = 0_i64; 100_000_000.times { |i| sum &+= i }; sum",
      JIT_LOOP_BENCH_SUM_0_TO_N_1
  end

  it "Int#upto" do
    bench "Int#upto",
      "sum = 0_i64; 1_i64.upto(100_000_000_i64) { |i| sum &+= i }; sum",
      JIT_LOOP_BENCH_SUM_1_TO_N
  end

  it "while" do
    bench "while",
      "sum = 0_i64; i = 0_i64; while i < 100_000_000_i64; sum &+= i; i &+= 1_i64; end; sum",
      JIT_LOOP_BENCH_SUM_0_TO_N_1
  end
end
