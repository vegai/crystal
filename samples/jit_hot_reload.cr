# Demonstrates `crystal i --backend=jit`'s hot-reload story.
#
# Build the compiler with interpreter support, then run this file:
#
#   make crystal interpreter=1 progress=1
#   ./bin/crystal run samples/jit_hot_reload.cr
#
# The script drives a `Crystal::JIT::Repl` programmatically and prints
# each submission's value. The point is that the *caller* method is
# compiled only once but observes the new behavior of its callee on
# subsequent submissions, via the JIT's dispatch-slot indirection.
#
# Method bodies are written so the value isn't constant-folded at
# compile time (e.g. `["red"].first` rather than `"red"`); a literal
# body folds at codegen and the slot indirection is bypassed.

Crystal::Config.path = File.expand_path("../src", __DIR__)
require "compiler/crystal/interpreter"

repl = Crystal::JIT::Repl.new

def run(repl, code : String) : Nil
  value = repl.run_code(code)
  v = value.value
  printf "jit> %-55s => %s\n", code, v.nil? ? "nil" : v.inspect
end

puts "=== 1. Redefine a leaf method; existing caller picks up the new body ==="
run repl, %(def color; ["red"].first; end)
run repl, %(def banner; "The color is " + color; end; banner)
run repl, %(def color; ["blue"].first; end)
run repl, %(banner)
run repl, %(def color; ["green"].first; end)
run repl, %(banner)

puts
puts "=== 2. Redefine a constant; existing caller picks up the new value ==="
run repl, %(GREETING = "Hello")
run repl, %(def hi(name : String); GREETING + ", " + name + "!"; end)
run repl, %{hi("world")}
run repl, %(GREETING = "Goodbye")
run repl, %{hi("world")}

puts
puts "=== 3. Redefine an instance method; the class itself sees it ==="
run repl, %(class Counter; @@n = 7_i32; def self.show; "count=" + @@n.to_s; end; end)
run repl, %(Counter.show)
run repl, %(class Counter; def self.show; "[redacted: " + @@n.to_s + "]"; end; end)
run repl, %(Counter.show)
