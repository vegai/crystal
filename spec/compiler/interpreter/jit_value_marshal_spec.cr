{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Verifies `Crystal::JIT::Value#to_s` stringifies tuples, named tuples,
# and struct ivars from the wrapper buffer.
# Opt-in via CRYSTAL_JIT_VALUE_MARSHAL_SPEC=1.
describe "Crystal::JIT::Value marshalling" do
  it "stringifies tuples, named tuples, and struct ivars from the wrapper buffer" do
    jit_opt_in!("CRYSTAL_JIT_VALUE_MARSHAL_SPEC")

    repl = Crystal::JIT::Repl.new

    repl.run_code("{1, 2, 3}").to_s.should eq("{1, 2, 3}")
    repl.run_code("{1_i32, 'a'}").to_s.should eq("{1, 'a'}")
    repl.run_code(%({1, "x"})).to_s.should eq(%({1, "x"}))

    repl.run_code("{a: 1, b: 2}").to_s.should eq("{a: 1, b: 2}")

    repl.run_code(<<-CRYSTAL).to_s.should eq("Pt(@x=10 @y=20)")
      struct Pt
        @x : Int32
        @y : Int32

        def initialize(@x, @y)
        end
      end

      Pt.new(10, 20)
    CRYSTAL
  end
end
