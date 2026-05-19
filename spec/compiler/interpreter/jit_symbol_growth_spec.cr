{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Verifies symbols introduced in a later submission resolve via the
# versioned `:symbol_table:vN` + `:symbol_table:slot` path.
# Opt-in via CRYSTAL_JIT_SYMBOL_GROWTH_SPEC=1.
describe "Crystal::JIT::Repl symbol table growth" do
  it "resolves a symbol literal introduced in a later submission" do
    jit_opt_in!("CRYSTAL_JIT_SYMBOL_GROWTH_SPEC")

    repl = Crystal::JIT::Repl.new

    # Trigger Symbol#to_s emission in a submission whose program has
    # all prelude symbols (the previous submission's table was sized
    # to fit). Before the fix this crashed in Symbol#inspect.
    repl.run_code("123").value.to_s.should eq("123")
    repl.run_code(":jit_growth_new_sym").value.to_s.should eq(":jit_growth_new_sym")

    # Adding another novel symbol in a follow-up submission must also
    # resolve correctly; the slot needs to repoint to the new table.
    repl.run_code(":jit_growth_second").value.to_s.should eq(":jit_growth_second")
    repl.run_code(":jit_growth_new_sym").value.to_s.should eq(":jit_growth_new_sym")
  end
end
