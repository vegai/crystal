module Crystal::JIT
  # Persistent C-style argv block that the JIT wrapper hands to
  # `__crystal_main`. Storage is `malloc_atomic` so Boehm does not chase
  # stray bit-patterns as Crystal heap pointers; `storage` is the
  # Boehm-traced root keeping the malloc alive while the session uses it.
  struct CArgv
    getter argv : Pointer(Pointer(UInt8))
    getter argc : Int32
    getter storage : Pointer(UInt8)

    EMPTY = new(Pointer(Pointer(UInt8)).null, 0, Pointer(UInt8).null)

    def self.build(args : Array(String)) : CArgv
      argv_array_bytes = (args.size + 1) * sizeof(Pointer(UInt8))
      total_string_bytes = args.sum(0) { |s| s.bytesize + 1 }
      buffer = GC.malloc_atomic(argv_array_bytes + total_string_bytes).as(UInt8*)
      argv_ptrs = buffer.as(Pointer(Pointer(UInt8)))
      string_cursor = buffer + argv_array_bytes
      args.each_with_index do |str, i|
        argv_ptrs[i] = string_cursor
        str.to_unsafe.copy_to(string_cursor, str.bytesize)
        string_cursor[str.bytesize] = 0u8
        string_cursor += str.bytesize + 1
      end
      argv_ptrs[args.size] = Pointer(UInt8).null
      new(argv_ptrs, args.size, buffer)
    end

    def initialize(@argv : Pointer(Pointer(UInt8)), @argc : Int32, @storage : Pointer(UInt8))
    end
  end
end
