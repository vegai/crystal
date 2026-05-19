{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Cached-exec bench for tight integer loops under the JIT backend.
# Asserts nothing; prints first/cached/cached timings to stdout.
# Opt-in via CRYSTAL_JIT_LOOP_BENCH_SPEC=1.
JIT_LOOP_BENCH_PRELUDE = ENV["CRYSTAL_JIT_LOOP_BENCH_PRELUDE"]? || "prelude"

private def bench(label : String, code : String)
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
end

describe "Crystal::JIT::Repl 100M loop bench" do
  it "Range#each" do
    bench "Range#each", "sum = 0_i64; (1_i64..100_000_000_i64).each { |i| sum &+= i }; sum"
  end

  it "Int#times" do
    bench "Int#times", "sum = 0_i64; 100_000_000.times { |i| sum &+= i }; sum"
  end

  it "Int#upto" do
    bench "Int#upto", "sum = 0_i64; 1_i64.upto(100_000_000_i64) { |i| sum &+= i }; sum"
  end

  it "while" do
    bench "while", "sum = 0_i64; i = 0_i64; while i < 100_000_000_i64; sum &+= i; i &+= 1_i64; end; sum"
  end
end
