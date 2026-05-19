{% skip_file if flag?(:without_interpreter) %}
require "./spec_helper"

# Exercises the layout-change refusal path: a class redef that would
# change ivar layout is refused once an instance has been allocated.
# Opt-in via CRYSTAL_JIT_LAYOUT_REFUSAL_SPEC=1.
describe "Crystal::JIT::Repl layout change refusal" do
  it "refuses to add a new instance variable to an instantiated class" do
    jit_opt_in!("CRYSTAL_JIT_LAYOUT_REFUSAL_SPEC")

    repl = Crystal::JIT::Repl.new
    repl.run_code("class LayoutRefuseFoo; @x : Int32 = 0; end")
    repl.run_code("LayoutRefuseFoo.new")

    expect_raises(Crystal::JIT::Session::LayoutChangeRefused, /LayoutRefuseFoo/) do
      repl.run_code("class LayoutRefuseFoo; @y : String = \"\"; end")
    end

    # Including a method-only module after allocation must NOT be
    # refused: it brings no ivars and leaves the layout intact.
    repl.run_code("module LayoutNoIvarMixin; def layout_greet; \"hi\"; end; end")
    repl.run_code("class LayoutHostA; @x : Int32 = 1; end")
    repl.run_code("LayoutHostA.new")
    repl.run_code("class LayoutHostA; include LayoutNoIvarMixin; end")

    # Including a module that DOES carry ivars still refuses.
    repl.run_code("module LayoutWithIvarMixin; @y : Int32 = 0; end")
    repl.run_code("class LayoutHostB; @x : Int32 = 1; end")
    repl.run_code("LayoutHostB.new")
    expect_raises(Crystal::JIT::Session::LayoutChangeRefused, /LayoutHostB/) do
      repl.run_code("class LayoutHostB; include LayoutWithIvarMixin; end")
    end
  end
end
