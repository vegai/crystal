{% skip_file unless flag?(:embed_compiler) %}

# Read-only accessor for the host's source set, bundled into the binary
# by `crystal build --embed-compiler`. The blob is emitted by
# `Crystal::CodeGenVisitor#emit_embedded_sources` and consumed here.

module Crystal::Embed::HostSources
  extend self

  # One entry from the bundled blob.
  #
  # `path` is the absolute path the host compiler resolved at build
  # time. `content` is a read-only view into the embedded blob (do not
  # mutate). `stdlib` distinguishes `Crystal::Config.path`-rooted files
  # from host source so a loaded module's `require "json"` lookup goes
  # to the stdlib slice first.
  record Entry,
    path : String,
    content : Bytes,
    stdlib : Bool

  # Returns the number of bundled entries. Equals the size of the
  # host's resolved require graph at build time.
  def size : Int32
    entries.size
  end

  def each(& : Entry ->) : Nil
    entries.each { |e| yield e }
  end

  # Returns the bundled entry whose `path` exactly matches *path*, or
  # `nil`. Callers wanting case-insensitive or canonicalised matching
  # should normalise *path* first.
  def find(path : String) : Entry?
    entries.find { |e| e.path == path }
  end

  # Returns only the stdlib slice. Used by the embedded compiler's
  # resolver to satisfy `require "json"` before falling back to disk.
  def stdlib_entries : Array(Entry)
    entries.select(&.stdlib)
  end

  # Returns only the host-source slice (non-stdlib).
  def host_entries : Array(Entry)
    entries.reject(&.stdlib)
  end

  @@entries : Array(Entry)? = nil

  private def entries : Array(Entry)
    @@entries ||= decode_blob
  end

  private def decode_blob : Array(Entry)
    size = LibCrystalEmbed.__crystal_embedded_sources_size
    return [] of Entry if size <= 0

    blob_ptr = pointerof(LibCrystalEmbed.__crystal_embedded_sources_data)
    blob = Bytes.new(blob_ptr, size.to_i32)
    io = IO::Memory.new(blob, writable: false)

    count = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    Array(Entry).new(count.to_i32) do
      path_len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i32
      kind = io.read_byte.not_nil!
      path_bytes = Bytes.new(path_len)
      io.read_fully(path_bytes)
      content_len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i32
      content = Bytes.new(content_len)
      io.read_fully(content)
      Entry.new(String.new(path_bytes), content, kind == 1_u8)
    end
  end
end

# C-level globals emitted by `Crystal::CodeGenVisitor#emit_embedded_sources`.
# `__crystal_embedded_sources_data` is the start of the blob (declared as
# a single `UInt8` here so `pointerof` returns the array address); the
# real array runs for `__crystal_embedded_sources_size` bytes.
lib LibCrystalEmbed
  $__crystal_embedded_sources_data : UInt8
  $__crystal_embedded_sources_size : Int64
end
