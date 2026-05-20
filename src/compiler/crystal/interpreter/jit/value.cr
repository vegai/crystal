module Crystal::JIT
  # A typed snapshot of a JIT-executed result. The pointer references a
  # buffer the JIT wrote its return value into; the type describes how to
  # read those bytes back. Mirrors the shape of `Crystal::Repl::Value` so
  # the existing interpreter spec helper can compare values uniformly.
  struct Value
    # Reference layouts start with a `type_id` header slot; instance
    # vars sit after it.
    HEADER_SLOT_COUNT = 1

    alias Inspected = Nil | Bool | Char | Int::Primitive | Float::Primitive | String | Pointer(UInt8) | Crystal::Type

    getter pointer : Pointer(UInt8)
    getter type : Crystal::Type
    getter program : Crystal::Program

    def initialize(@pointer : Pointer(UInt8), @type : Crystal::Type, @program : Crystal::Program)
    end

    def value : Inspected
      type = @type
      string_type = @program.string
      case type
      when Crystal::NilType
        nil
      when Crystal::BoolType
        @pointer.as(Bool*).value
      when Crystal::CharType
        @pointer.as(Char*).value
      when Crystal::IntegerType
        case type.kind
        when .i8?   then @pointer.as(Int8*).value
        when .u8?   then @pointer.as(UInt8*).value
        when .i16?  then @pointer.as(Int16*).value
        when .u16?  then @pointer.as(UInt16*).value
        when .i32?  then @pointer.as(Int32*).value
        when .u32?  then @pointer.as(UInt32*).value
        when .i64?  then @pointer.as(Int64*).value
        when .u64?  then @pointer.as(UInt64*).value
        when .i128? then @pointer.as(Int128*).value
        when .u128? then @pointer.as(UInt128*).value
        else
          raise "BUG: missing handling of JIT::Value for #{type}"
        end
      when Crystal::FloatType
        case type.kind
        when .f32? then @pointer.as(Float32*).value
        when .f64? then @pointer.as(Float64*).value
        else
          raise "BUG: missing handling of JIT::Value for #{type}"
        end
      when Crystal::SymbolType
        sym_id = @pointer.as(Int32*).value
        name = @program.symbol_at?(sym_id)
        raise "BUG: JIT::Value symbol id #{sym_id} out of range (table size #{@program.symbols.size})" unless name
        ":#{name}"
      when string_type
        @pointer.as(UInt8**).value.unsafe_as(String)
      when Crystal::PointerInstanceType
        @pointer.as(UInt8**).value
      when Crystal::MetaclassType, Crystal::GenericClassInstanceMetaclassType, Crystal::VirtualMetaclassType
        # If the runtime id doesn't map back to a Type, fall through
        # to the declared (meta)class - same recovery as
        # `to_s_class_ivars`. Pretty-print should never crash even on
        # mismatched id tables.
        type_id = @pointer.as(Int32*).value
        @program.llvm_id.type_from_id(type_id) || type
      when Crystal::MixedUnionType
        # Codegen writes `(Int32 type_id, max-member bytes)` for a
        # union result; resolve to the active member's Value and
        # forward. Mirrors the bytecode interpreter (`interpreter/value.cr`).
        type_id = @pointer.as(Int32*).value
        runtime = @program.llvm_id.type_from_id(type_id) || type
        Value.new(@pointer + sizeof(Pointer(UInt8)), runtime, @program).value
      else
        @pointer
      end
    end

    def to_s(io : IO) : Nil
      type = @type
      string_type = @program.string
      case type
      when Crystal::CharType
        @pointer.as(Char*).value.inspect(io)
      when string_type
        @pointer.as(UInt8**).value.unsafe_as(String).inspect(io)
      when Crystal::TupleInstanceType
        io << "{"
        struct_ty = @program.llvm_typer.llvm_struct_type(type)
        type.tuple_types.each_with_index do |field_type, i|
          offset = @program.llvm_typer.offset_of(struct_ty, i)
          io << Value.new(@pointer + offset, field_type, @program)
          io << ", " unless i == type.tuple_types.size - 1
        end
        io << "}"
      when Crystal::NamedTupleInstanceType
        io << "{"
        struct_ty = @program.llvm_typer.llvm_struct_type(type)
        type.entries.each_with_index do |entry, i|
          offset = @program.llvm_typer.offset_of(struct_ty, i)
          io << entry.name
          io << ": "
          io << Value.new(@pointer + offset, entry.type, @program)
          io << ", " unless i == type.entries.size - 1
        end
        io << "}"
      when Crystal::InstanceVarContainer
        if type.struct?
          to_s_struct_ivars(type, io)
        else
          to_s_class_ivars(type, io)
        end
      else
        v = value
        case v
        when Nil    then io << "nil"
        else             io << v
        end
      end
    end

    private def to_s_struct_ivars(type : Crystal::Type, io : IO) : Nil
      io << type
      io << "("
      ivars = type.all_instance_vars
      struct_ty = @program.llvm_typer.llvm_struct_type(type)
      ivars.each_with_index do |(name, ivar), idx|
        offset = @program.llvm_typer.offset_of(struct_ty, idx)
        io << name
        io << '='
        io << Value.new(@pointer + offset, ivar.type, @program)
        io << ' ' unless idx == ivars.size - 1
      end
      io << ")"
    end

    private def to_s_class_ivars(type : Crystal::Type, io : IO) : Nil
      # `#<Type:0xADDR @ivar=...>`; class layout is `(Int32 type_id, ivars...)`.
      base_ptr = @pointer.as(UInt8**).value
      if base_ptr.null?
        io << "nil"
        return
      end
      type_id = base_ptr.as(Int32*).value
      runtime_type = @program.llvm_id.type_from_id(type_id) || type
      io << "#<"
      io << runtime_type
      io << ":0x"
      base_ptr.address.to_s(io, 16)
      ivars = type.all_instance_vars
      if ivars.size > 0
        instance_ty = @program.llvm_typer.llvm_struct_type(type)
        ivars.each_with_index do |(name, ivar), idx|
          offset = @program.llvm_typer.offset_of(instance_ty, idx + HEADER_SLOT_COUNT)
          io << ' '
          io << name
          io << '='
          io << Value.new(base_ptr + offset, ivar.type, @program)
        end
      end
      io << ">"
    end
  end
end
