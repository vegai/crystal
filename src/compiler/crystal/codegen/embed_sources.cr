# Codegen-time emission of the host's resolved source set so loaded
# modules under `--embed-compiler` can resolve `require` lookups against
# the bundled blob instead of the disk paths the host was built against.
#
# Layout of the emitted `__crystal_embedded_sources_data` byte array:
#
#   u32 little-endian: count
#   for each entry:
#     u32 little-endian: path_length (in bytes)
#     u8:                kind (0 = host source, 1 = stdlib source)
#     path_length × u8:  utf-8 path bytes
#     u32 little-endian: content_length (in bytes)
#     content_length × u8: utf-8 content bytes
#
# `__crystal_embedded_sources_size` carries the byte length so the
# runtime can construct a `Bytes` view without knowing the layout.
#
# Bundling is intentionally raw (not gzipped) because the compiler is
# built with `-Dwithout_zlib` today; adding compression is a follow-up
# once Phase B3 plumbs the compiler library into user binaries that can
# pull in `compress/gzip`.

class Crystal::CodeGenVisitor
  EMBED_SOURCES_DATA_SYMBOL = "__crystal_embedded_sources_data"
  EMBED_SOURCES_SIZE_SYMBOL = "__crystal_embedded_sources_size"

  # Builds the source-set blob and emits it as two `LinkOnceODR` globals
  # on the main module. No-op outside `--embed-compiler`.
  def emit_embedded_sources : Nil
    return unless @program.has_flag?("embed_compiler")
    return if @main_mod.globals[EMBED_SOURCES_DATA_SYMBOL]?

    # The resolved CRYSTAL_PATH entries (stdlib + shards). Any required
    # file under one of these is bundled as `kind=1` so the embedded
    # compiler's resolver can satisfy `require "json"`-style lookups
    # against the blob first, before falling back to disk.
    crystal_roots = @program.crystal_path.entries.map(&.rstrip(File::SEPARATOR))

    blob = build_embedded_sources_blob(crystal_roots)
    emit_embedded_sources_globals(blob)
  end

  private def build_embedded_sources_blob(crystal_roots : Array(String)) : Bytes
    paths = @program.requires.to_a.sort!
    entries = [] of {String, UInt8, Bytes}

    paths.each do |path|
      next unless File.exists?(path)
      content = File.read(path)
      kind = embedded_source_kind(path, crystal_roots)
      entries << {path, kind, content.to_slice}
    end

    io = IO::Memory.new
    io.write_bytes(entries.size.to_u32, IO::ByteFormat::LittleEndian)
    entries.each do |path, kind, content|
      io.write_bytes(path.bytesize.to_u32, IO::ByteFormat::LittleEndian)
      io.write_byte(kind)
      io.write(path.to_slice)
      io.write_bytes(content.size.to_u32, IO::ByteFormat::LittleEndian)
      io.write(content)
    end
    io.to_slice
  end

  private def embedded_source_kind(path : String, crystal_roots : Array(String)) : UInt8
    crystal_roots.any? { |root| !root.empty? && path.starts_with?(root) } ? 1_u8 : 0_u8
  end

  private def emit_embedded_sources_globals(blob : Bytes) : Nil
    i8 = @main_llvm_context.int8
    i64 = @main_llvm_context.int64

    elements = Array(LLVM::Value).new(blob.size)
    blob.each { |byte| elements << i8.const_int(byte) }

    data = @main_mod.globals.add(i8.array(blob.size), EMBED_SOURCES_DATA_SYMBOL)
    data.linkage = LLVM::Linkage::LinkOnceODR
    data.initializer = i8.const_array(elements)
    data.global_constant = true

    size = @main_mod.globals.add(i64, EMBED_SOURCES_SIZE_SYMBOL)
    size.linkage = LLVM::Linkage::LinkOnceODR
    size.initializer = i64.const_int(blob.size.to_i64)
    size.global_constant = true
  end
end
