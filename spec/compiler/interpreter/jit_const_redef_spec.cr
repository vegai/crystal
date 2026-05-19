{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Exercises `CONST = expr` redef across submissions in the JIT REPL.
# Opt-in via CRYSTAL_JIT_CONST_REDEF_SPEC=1.

describe "Crystal::JIT::Repl constant redef" do
  it "redefines a top-level constant and subsequent reads return the new value" do
    jit_opt_in!("CRYSTAL_JIT_CONST_REDEF_SPEC")

    repl = Crystal::JIT::Repl.new

    repl.run_code("CONST_REDEF_X = 1_i32")
    repl.run_code("CONST_REDEF_X").value.to_s.should eq("1")

    repl.run_code("CONST_REDEF_X = 100_i32")
    repl.run_code("CONST_REDEF_X").value.to_s.should eq("100")

    repl.run_code("CONST_REDEF_X = 200_i32")
    repl.run_code("CONST_REDEF_X").value.to_s.should eq("200")

    # Non-simple value (Random defeats const inlining at parse time).
    repl.run_code("CONST_REDEF_Y = Random.new(42).rand(7_i32..7_i32)")
    repl.run_code("CONST_REDEF_Y").value.to_s.should eq("7")

    repl.run_code("CONST_REDEF_Y = Random.new(42).rand(70_i32..70_i32)")
    repl.run_code("CONST_REDEF_Y").value.to_s.should eq("70")

    # Method body compiled before the redef must also see the new value.
    repl.run_code("CONST_REDEF_Z = Random.new(42).rand(42_i32..42_i32)")
    repl.run_code("def use_const_z; CONST_REDEF_Z &+ 1; end")
    repl.run_code("use_const_z").value.to_s.should eq("43")

    repl.run_code("CONST_REDEF_Z = Random.new(42).rand(1000_i32..1000_i32)")
    repl.run_code("use_const_z").value.to_s.should eq("1001")
  end
end
