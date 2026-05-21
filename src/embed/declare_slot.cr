{% skip_file unless flag?(:embed_compiler) %}

module Crystal::Embed
  # Types allowed in `declare_slot` signatures. Cross-boundary types
  # (host-defined classes) hit the type-identity gap between the host's
  # AOT `Program` and the JIT `Program` — `materialize_files` + the
  # registry is the path for those. The allowlist keeps the secondary
  # bridge honest: a slot signature only reaches across the boundary
  # when both sides agree on a single shared type, which is true for
  # stdlib primitives, `String`, `Bytes`, and the symbol/nil scalars.
  EMBED_SAFE_TYPE_NAMES = %w(
    Int8 Int16 Int32 Int64 Int128
    UInt8 UInt16 UInt32 UInt64 UInt128
    Float32 Float64
    Bool Char Nil Symbol
    String Bytes
  )

  # Raised by `Crystal::Embed.load` when a loaded module's top-level def
  # matches a declared slot name but its signature does not match what
  # the host declared. The slot keeps its previous value.
  class SignatureMismatch < Exception
    getter slot_name : String
    getter expected : String
    getter actual : String

    def initialize(@slot_name : String, @expected : String, @actual : String)
      super("Crystal::Embed slot `#{@slot_name}` was declared as #{@expected} but the loaded module's top-level def has signature #{@actual}")
    end
  end

  # Bookkeeping for one slot the host declared via `declare_slot`.
  # Built at startup by macro expansions, consumed by the loader.
  class DeclaredSlot
    getter name : String
    getter arg_type_names : Array(String)
    getter return_type_name : String
    getter canonical_signature : String
    getter setter : Pointer(Void) -> Nil
    property last_owner : String?

    def initialize(@name, @arg_type_names, @return_type_name, @canonical_signature, @setter)
      @last_owner = nil
    end
  end

  # Process-wide registry of slots declared via `declare_slot`. Each
  # `declare_slot` macro expansion adds one entry at program startup;
  # `Crystal::Embed.load` walks the registry after each successful load
  # to install matching top-level defs from the loaded module.
  module DeclaredSlots
    extend self

    @@slots = {} of String => DeclaredSlot

    # The macro expansion is deterministic, so re-registering the same
    # name carries identical data — overwrite rather than dedup so a
    # rebuild that walks the host twice doesn't surface as a runtime
    # error.
    def register(name : String, arg_type_names : Array(String), return_type_name : String,
                 canonical_signature : String, setter : Pointer(Void) -> Nil) : Nil
      @@slots[name] = DeclaredSlot.new(name, arg_type_names, return_type_name,
        canonical_signature, setter)
    end

    def empty? : Bool
      @@slots.empty?
    end

    def each(& : DeclaredSlot ->) : Nil
      @@slots.each_value { |slot| yield slot }
    end

    def []?(name : String) : DeclaredSlot?
      @@slots[name]?
    end

    def size : Int32
      @@slots.size
    end
  end

  # Declares a typed slot a loaded module can fill with a matching
  # top-level def. The host calls through the generated typed accessor.
  #
  # ```
  # Crystal::Embed.declare_slot compute : (Int32, Int32) -> Int32
  #
  # # In a loaded module:
  # # def compute(a : Int32, b : Int32) : Int32
  # #   a + b
  # # end
  #
  # if proc = Crystal::Embed.compute
  #   proc.call(3, 4) # => 7
  # end
  # ```
  #
  # The signature is written as a `TypeDeclaration` (`name : ProcNotation`)
  # because Crystal's expression parser doesn't accept a bare
  # `(T...) -> R` in macro-arg position.
  #
  # The first cut restricts the signature to primitive types, `Symbol`,
  # `String`, and `Bytes`. A host-defined class in the signature would
  # cross the AOT/JIT type-identity boundary and silently produce UB on
  # call; the macro rejects it at expansion with a pointer to the
  # registry-based bridge that handles cross-boundary types safely.
  macro declare_slot(decl)
    {% unless decl.is_a?(TypeDeclaration) %}
      {% raise "Crystal::Embed.declare_slot expects `name : (T...) -> R`, got #{decl.class_name}: #{decl}" %}
    {% end %}

    {% name = decl.var %}
    {% signature = decl.type %}

    {% unless signature.is_a?(ProcNotation) %}
      {% raise "Crystal::Embed.declare_slot: signature must be a proc notation like `(Int32, Int32) -> Int32`, got #{signature.class_name}: #{signature}" %}
    {% end %}

    {% inputs = signature.inputs || [] of ASTNode %}
    {% output = signature.output %}
    {% if output.nil? %}
      {% raise "Crystal::Embed.declare_slot: signature must declare an explicit return type (use `Nil` for no-op procs)" %}
    {% end %}

    {% for t in inputs %}
      {% unless t.is_a?(Path) && Crystal::Embed::EMBED_SAFE_TYPE_NAMES.includes?(t.names.join("::")) %}
        {% raise "Crystal::Embed.declare_slot: argument type `#{t}` is not in the safe-types allowlist for the secondary bridge. Allowed: primitives, Symbol, String, Bytes. For cross-boundary types (host-defined classes), use materialize_files + Registry instead." %}
      {% end %}
    {% end %}
    {% unless output.is_a?(Path) && Crystal::Embed::EMBED_SAFE_TYPE_NAMES.includes?(output.names.join("::")) %}
      {% raise "Crystal::Embed.declare_slot: return type `#{output}` is not in the safe-types allowlist for the secondary bridge. Allowed: primitives, Symbol, String, Bytes. For cross-boundary types (host-defined classes), use materialize_files + Registry instead." %}
    {% end %}

    module ::Crystal::Embed
      @@__embed_slot_{{name.id}} : Atomic(Pointer(Void)) = Atomic(Pointer(Void)).new(Pointer(Void).null)

      # Typed accessor the host calls. Returns `nil` until a load
      # successfully fills the slot.
      def self.{{name.id}} : Proc({% for t in inputs %}{{t}}, {% end %}{{output}})?
        addr = @@__embed_slot_{{name.id}}.get(:acquire)
        return nil if addr.null?
        Proc({% for t in inputs %}{{t}}, {% end %}{{output}}).new(addr, Pointer(Void).null)
      end

      # Setter the loader writes through. Kept as a class method so the
      # macro can capture a stable method reference into the registry's
      # setter Proc without leaking the class var's symbol.
      def self.__embed_set_slot_{{name.id}}(addr : Pointer(Void)) : Nil
        @@__embed_slot_{{name.id}}.set(addr, :release)
      end
    end

    ::Crystal::Embed::DeclaredSlots.register(
      {{name.id.stringify}},
      [{% for t in inputs %}{{t.stringify}}, {% end %}] of String,
      {{output.stringify}},
      {{"(" + inputs.map(&.stringify).join(", ") + ") -> " + output.stringify}},
      ->(addr : Pointer(Void)) { ::Crystal::Embed.__embed_set_slot_{{name.id}}(addr); nil }
    )
  end
end
