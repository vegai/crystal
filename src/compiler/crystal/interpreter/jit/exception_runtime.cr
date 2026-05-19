module Crystal::JIT
  # Minimal libunwind exception runtime spliced into the `primitives`
  # prelude so begin/rescue and overflow checks unwind through libunwind.
  # Parser-friendly to the primitives prelude (no Enum methods, no
  # operator overloads, unchecked arithmetic).
  #
  # The body lives in `embedded_sources/exception_runtime_source.cr` so
  # editors give it full tooling and `crystal tool format` /
  # `crystal build --no-codegen` can syntax-check edits. The subdirectory
  # keeps it out of `require "./interpreter/jit/*"` so it isn't compiled
  # into the host compiler.
  EXCEPTION_RUNTIME_SOURCE = {{ read_file("#{__DIR__}/embedded_sources/exception_runtime_source.cr") }}
end
