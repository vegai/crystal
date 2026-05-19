{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Verifies PROGRAM_NAME and ARGV are populated from the Session-owned
# C-style argv buffer.
# Opt-in via CRYSTAL_JIT_PROGRAM_NAME_SPEC=1.
RUN_JIT_PROGRAM_NAME_SPEC = ENV["CRYSTAL_JIT_PROGRAM_NAME_SPEC"]? == "1"

describe "Crystal::JIT::Repl program args" do
  it "exposes PROGRAM_NAME and ARGV without crashing" do
    pending! "JIT backend only", file: __FILE__, line: __LINE__ unless JIT_BACKEND
    pending! "opt in via CRYSTAL_JIT_PROGRAM_NAME_SPEC=1", file: __FILE__, line: __LINE__ unless RUN_JIT_PROGRAM_NAME_SPEC

    # `set_program_args` must be called before the first submission:
    # PROGRAM_NAME is always `argv[0] = "jit"`, ARGV is the remainder.
    repl = Crystal::JIT::Repl.new
    repl.set_program_args(["one", "two"])
    code = %(PROGRAM_NAME + "/" + ARGV.size.to_s + "/" + ARGV[0] + "/" + ARGV[1])
    repl.run_code(code).value.to_s.should eq("jit/2/one/two")
  end
end
