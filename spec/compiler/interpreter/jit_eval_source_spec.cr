{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Exercises `Crystal::JIT::Repl#run_eval_source` (the
# `crystal i --backend=jit -e SOURCE` one-shot path).
# Opt-in via CRYSTAL_JIT_EVAL_SOURCE_SPEC=1.
describe "Crystal::JIT::Repl run_eval_source" do
  it "runs a one-shot evaluation and returns 0 on success" do
    jit_opt_in!("CRYSTAL_JIT_EVAL_SOURCE_SPEC")

    repl = Crystal::JIT::Repl.new

    repl.run_eval_source("puts 7").should eq(0)

    # Multi-statement source (top-level def + runtime call).
    repl.run_eval_source(<<-CRYSTAL).should eq(0)
      def add_eval(a, b)
        a + b
      end

      puts add_eval(2, 3)
      CRYSTAL

    # Declaration-shape (`require`) hoisted past the rescue.
    repl.run_eval_source(<<-CRYSTAL).should eq(0)
      require "big"
      puts BigInt.new("100") * 3
      CRYSTAL

    # Parse error: returns 1.
    repl.run_eval_source("def").should eq(1)
  end
end
