{% skip_file if flag?(:without_interpreter) %}
require "../spec_helper"
require "compiler/crystal/interpreter/*"

JIT_BACKEND = ENV["CRYSTAL_INTERP_BACKEND"]? == "jit"

# Shared gate for opt-in JIT specs. `pending!`'s `file`/`line` defaults
# are evaluated at the call site, so the report points at the caller.
def jit_opt_in!(env_var : String, file = __FILE__, line = __LINE__) : Nil
  pending! "JIT backend only", file: file, line: line unless JIT_BACKEND
  pending! "opt in via #{env_var}=1", file: file, line: line unless ENV[env_var]? == "1"
end

# JIT-spec-only support; see `Crystal::JIT::SpecSupport`.
module Crystal::JIT::SpecSupport
  # Stubs for runtime helpers the `primitives` prelude omits. See
  # `EXCEPTION_RUNTIME_SOURCE` for the unwind side.
  STUBS = {
    "__crystal_raise_overflow"    => "fun __crystal_raise_overflow : NoReturn\n  while true; end\nend",
    "__crystal_raise_cast_failed" => "fun __crystal_raise_cast_failed(s1 : UInt8*, s2 : UInt8*, file : UInt8*, line : Int32, col : Int32) : NoReturn\n  while true; end\nend",
  }

  STUB_REGEXES = STUBS.map { |name, _| {name, /\bfun\s+#{Regex.escape(name)}\b/} }.to_h

  # Registers stubs as prelude extras so they keep their own synthetic
  # filename rather than shifting the user code's `__LINE__`.
  def self.apply_stubs(repl : Crystal::JIT::Repl, code : String) : Nil
    STUBS.each do |name, stub|
      next if code.matches?(STUB_REGEXES[name])
      repl.prelude_extra << {stub, "(jit-spec-stub-#{name})"}
    end
  end

  # Drops JIT-mapped pages for every alive Session. Used between examples
  # to bound RSS; production code disposes individual Sessions explicitly.
  def self.dispose_all_sessions : Nil
    Crystal::JIT::Session.each_alive(&.dispose)
  end
end

# Bound the JIT Session pin between examples; otherwise RSS climbs as
# `@@alive` keeps each instance for LLVM teardown safety.
if JIT_BACKEND
  Spec.before_each { Crystal::JIT::SpecSupport.dispose_all_sessions }
end

def interpret(code, *, prelude = "primitives", file = __FILE__, line = __LINE__)
  if prelude == "primitives"
    context, value = interpret_with_context(code)
    # Bytecode loader owns dlopened libraries directly; close them between
    # examples. The JIT backend keeps the loader on `Session`, which the
    # `before_each` `dispose_all_sessions` hook tears down.
    context.loader?.try &.close_all if context.is_a?(Crystal::Repl::Context)
    value.value
  else
    interpret_in_separate_process(code, prelude, file: file, line: line)
  end
end

def interpret_with_context(code)
  if JIT_BACKEND
    repl = Crystal::JIT::Repl.new
    repl.prelude = "primitives"
    Crystal::JIT::SpecSupport.apply_stubs(repl, code)
  else
    repl = Crystal::Repl.new
    repl.prelude = "primitives"
  end
  value = repl.run_code(code)
  {repl.context, value}
end

# FIXME: The following is a dirty hack to work around GC issues in interpreted programs. https://github.com/crystal-lang/crystal/issues/11602
# In a nutshell, `interpret_in_separate_process` below calls this same process with an extra option that causes
# the interpretation of the code from stdin, reading the output from stdout. That string is used as the result of
# the program being tested.
class Spec::CLI
  def option_parser
    option_parser = previous_def
    option_parser.on("", "--interpret-code PRELUDE", "Execute interpreted code") do |prelude|
      code = STDIN.gets_to_end

      repl = Crystal::Repl.new
      repl.prelude = prelude

      print repl.run_code(code)
      exit
    end
    option_parser
  end
end

def interpret_in_separate_process(code, prelude, file = __FILE__, line = __LINE__)
  input = IO::Memory.new(code)
  output = IO::Memory.new
  error = IO::Memory.new
  executable = Process.executable_path || fail "Can't find executable path of current process"
  process = Process.new(executable, ["--interpret-code", prelude], input: input, output: output, error: error)

  status = process.wait
  unless status.success?
    fail error.rewind.gets_to_end + output.rewind.gets_to_end, file: file, line: line
  end

  output.rewind.gets_to_end
end
