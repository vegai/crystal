# JIT-internal exception runtime, read by exception_runtime.cr via
# `{{ read_file }}` and spliced into the `primitives` prelude. Not
# `require`d directly; it depends on declarations the primitives prelude
# provides at splice time, not on this file's own context.

lib LibC
  fun exit(status : Int32) : NoReturn
end

lib LibUnwind
  struct Exception
    exception_class : UInt64
    exception_cleanup : UInt64
    private1 : UInt64
    private2 : UInt64
    exception_object : Void*
    exception_type_id : Int32
  end

  fun get_language_specific_data = _Unwind_GetLanguageSpecificData(context : Void*) : UInt8*
  fun get_region_start = _Unwind_GetRegionStart(context : Void*) : UInt64
  fun get_ip = _Unwind_GetIP(context : Void*) : UInt64
  fun set_ip = _Unwind_SetIP(context : Void*, ip : UInt64) : UInt64
  fun set_gr = _Unwind_SetGR(context : Void*, index : Int32, value : UInt64)
  fun raise_exception = _Unwind_RaiseException(ex : Exception*) : Int32
end

EH_ACTION_SEARCH_PHASE  = 1
EH_ACTION_HANDLER_FRAME = 4

EH_REASON_HANDLER_FOUND   = 6
EH_REASON_INSTALL_CONTEXT = 7
EH_REASON_CONTINUE_UNWIND = 8

EH_REGISTER_0 = 0
EH_REGISTER_1 = 1

private struct Crystal__JIT__LEBReader
  def initialize(@data : UInt8*)
  end

  def data : UInt8*
    @data
  end

  def read_uint8 : UInt8
    value = @data.value
    @data = @data + 1_i64
    value
  end

  def read_uint32 : UInt32
    value = @data.as(UInt32*).value
    @data = @data + 4_i64
    value
  end

  def read_uleb128 : UInt64
    result = 0_u64
    shift = 0_i32
    while true
      byte = read_uint8
      result = result | (0x7f_u64 & byte.to_u64).unsafe_shl(shift)
      break if (byte & 0x80_u8).to_i32 == 0_i32
      shift = shift &+ 7_i32
    end
    result
  end
end

private def crystal_jit_traverse_eh_table(leb, start, ip, actions, &)
  throw_offset = (ip &- 1_u64) &- start

  lp_start_encoding = leb.read_uint8
  LibC.exit(1_i32) if lp_start_encoding.to_i32 != 0xff_i32

  tt_encoding = leb.read_uint8
  if tt_encoding.to_i32 != 0xff_i32
    leb.read_uleb128
  end

  cs_encoding = leb.read_uint8
  cs_enc = cs_encoding.to_i32
  LibC.exit(1_i32) if cs_enc != 1_i32 && cs_enc != 3_i32

  cs_table_length = leb.read_uleb128
  cs_table_end_addr = leb.data.address &+ cs_table_length

  while leb.data.address < cs_table_end_addr
    cs_offset = cs_enc == 3_i32 ? leb.read_uint32.to_u64 : leb.read_uleb128
    cs_length = cs_enc == 3_i32 ? leb.read_uint32.to_u64 : leb.read_uleb128
    cs_addr   = cs_enc == 3_i32 ? leb.read_uint32.to_u64 : leb.read_uleb128
    leb.read_uleb128

    if cs_addr != 0_u64
      range_end = cs_offset &+ cs_length
      if cs_offset <= throw_offset && throw_offset <= range_end
        if (actions & EH_ACTION_SEARCH_PHASE) != 0_i32
          return EH_REASON_HANDLER_FOUND
        end

        if (actions & EH_ACTION_HANDLER_FRAME) != 0_i32
          unwind_ip = start &+ cs_addr
          yield unwind_ip
          return EH_REASON_INSTALL_CONTEXT
        end
      end
    end
  end

  0_i32
end

# :nodoc:
fun __crystal_personality(
  version : Int32, actions : Int32, exception_class : UInt64, exception_object : LibUnwind::Exception*, context : Void*,
) : Int32
  start = LibUnwind.get_region_start(context)
  ip = LibUnwind.get_ip(context)
  lsd = LibUnwind.get_language_specific_data(context)

  leb = Crystal__JIT__LEBReader.new(lsd)
  reason = crystal_jit_traverse_eh_table(leb, start, ip, actions) do |unwind_ip|
    LibUnwind.set_gr(context, EH_REGISTER_0, exception_object.address)
    LibUnwind.set_gr(context, EH_REGISTER_1, exception_object.value.exception_type_id.to_u64)
    LibUnwind.set_ip(context, unwind_ip)
  end
  return reason if reason != 0_i32

  EH_REASON_CONTINUE_UNWIND
end

# :nodoc:
@[Raises]
fun __crystal_raise(unwind_ex : LibUnwind::Exception*) : NoReturn
  LibUnwind.raise_exception(unwind_ex)
  LibC.exit(1_i32)
end

# :nodoc:
fun __crystal_get_exception(unwind_ex : LibUnwind::Exception*) : UInt64
  unwind_ex.value.exception_object.address
end

# :nodoc:
@[Raises]
fun __crystal_interpreter_raise_without_backtrace(exception_ptr : Void*) : NoReturn
  unwind_ex = Pointer(LibUnwind::Exception).malloc(1_u64)
  unwind_ex.value.exception_class = 0_u64
  unwind_ex.value.exception_cleanup = 0_u64
  unwind_ex.value.exception_object = exception_ptr
  unwind_ex.value.exception_type_id = exception_ptr.as(Int32*).value
  __crystal_raise(unwind_ex)
end

# Resolves the closure-to-C diagnostic's synthesized `raise(String)`
# without pulling the full Exception machinery into `primitives`.
def raise(message : String) : NoReturn
  LibC.exit(1_i32)
end
