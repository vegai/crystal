module Crystal::JIT
  # Libunwind exception runtime spliced into the `primitives` prelude
  # so begin/rescue unwinds work. Kept primitives-parser-friendly: no
  # Enum methods, no operator overloads, unchecked arithmetic only.
  EXCEPTION_RUNTIME_SOURCE = {{ read_file("#{__DIR__}/embedded_sources/exception_runtime_source.cr") }}
end
