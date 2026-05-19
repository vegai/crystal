{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Drives multiple submissions on one Repl to exercise cross-submission
# defs, class vars, and `@[ThreadLocal]` class vars.
# Opt-in via CRYSTAL_JIT_CROSS_SUBMISSION_SPEC=1.
describe "Crystal::JIT::Repl cross-submission" do
  it "persists defs, class vars, and TLS class vars across submissions" do
    jit_opt_in!("CRYSTAL_JIT_CROSS_SUBMISSION_SPEC")

    repl = Crystal::JIT::Repl.new

    repl.run_code <<-CRYSTAL
      def cross_sub_double(x)
        x &* 2
      end

      class CrossSubPersist
        @@n : Int32 = 0

        def self.add(x)
          @@n = @@n &+ x
          @@n
        end
      end

      class CrossSubTLS
        @[ThreadLocal]
        @@counter : Int32 = 100

        def self.bump
          @@counter = @@counter &+ 1
          @@counter
        end

        def self.value
          @@counter
        end
      end
    CRYSTAL

    repl.run_code("cross_sub_double(21)").value.to_s.should eq("42")
    repl.run_code("CrossSubPersist.add(5)").value.to_s.should eq("5")
    repl.run_code("CrossSubPersist.add(7)").value.to_s.should eq("12")
    repl.run_code("CrossSubTLS.bump").value.to_s.should eq("101")
    repl.run_code("CrossSubTLS.bump").value.to_s.should eq("102")
    repl.run_code("CrossSubTLS.value").value.to_s.should eq("102")
  end
end
