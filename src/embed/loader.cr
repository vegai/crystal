{% skip_file unless flag?(:embed_compiler) %}

module Crystal::Embed
  # Raised when `Crystal::Embed.load` is called after a fork. The JIT-
  # mapped memory shared with the child process leads to UB if the child
  # tries to load — the API refuses post-fork loads instead.
  class PostForkLoadRefused < Exception
  end

  # First-call PID. Compared against `Process.pid` on each `load` to
  # detect the post-fork scenario. `nil` until the first load.
  @@first_load_pid : Int64? = nil

  # Serialises concurrent `load` / `reload` / `unload` calls. The JIT
  # `Session` is not designed for parallel codegen across modules, so
  # loaders run one at a time. The mutex is held for the duration of a
  # single load.
  @@mutex = Mutex.new

  # Lazily-allocated JIT REPL that hosts loaded modules. `nil` until the
  # first `load`; built under `@@mutex`.
  @@repl : Crystal::JIT::Repl? = nil

  # Map of canonical absolute path -> last successful load timestamp,
  # so subsequent `load` calls for the same path are recognised as
  # reloads (re-runs the file's top-level code; the registry helper
  # the host owns is expected to deduplicate).
  @@loaded_paths = {} of String => Time

  # Callbacks fired immediately before a reload re-runs a known path's
  # top-level code. Registries the host owns hook into this to drop
  # the prior instance before the new one registers.
  @@reload_hooks = [] of String -> Nil

  # Compiles *path* and runs its top-level code in-process. Subsequent
  # calls for the same *path* re-run the file (hot reload).
  #
  # Module identity is the canonicalised absolute file path; identical
  # contents at different paths are treated as distinct modules.
  #
  # Raises `PostForkLoadRefused` if called from a child process after
  # the first load happened in the parent.
  def self.load(path : String) : Nil
    canonical = File.expand_path(path)

    @@mutex.synchronize do
      check_fork_safety!

      if @@loaded_paths.has_key?(canonical)
        @@reload_hooks.each &.call(canonical)
      end

      repl = ensure_repl
      before_def_ids = snapshot_top_level_def_ids(repl)
      source = File.read(canonical)
      repl.run_code(source)
      fill_declared_slots(repl, canonical, before_def_ids)
      @@loaded_paths[canonical] = Time.utc
    end
  end

  # Registers a callback invoked with the canonical path right before
  # `load` re-runs a previously-loaded file. Registries pair this with
  # their `unregister(owner)` so reloading replaces the prior instance.
  def self.before_reload(&block : String ->) : Nil
    @@mutex.synchronize { @@reload_hooks << block }
  end

  # Re-walks the listed host source *paths* through the JIT `Program`
  # so types defined there become visible to subsequent `load`ed
  # modules. Each path is resolved against `Crystal::Embed::HostSources`
  # first, then against disk.
  #
  # The walk runs as a normal JIT submission, so any top-level code in
  # the listed files re-runs on materialisation. Files with side
  # effects should not be listed here — keep abstract class / type
  # definitions in dedicated files that are safe to re-execute.
  #
  # **Type identity caveat:** types re-walked through the JIT live in
  # the JIT `Program` and are distinct from the same source file's
  # AOT-compiled types in the host binary. The simplest workable
  # pattern is to define the `@[Embeddable]` abstract class in a
  # dedicated file, list it here, and have the host *only* reference
  # the type through `Crystal::Embed::Registry(T)` (parametrised on
  # the JIT-side type by going through the materialised version).
  # A full type-identity bridge is future work.
  def self.materialize_files(paths : Enumerable(String)) : Nil
    @@mutex.synchronize do
      check_fork_safety!
      repl = ensure_repl
      paths.each do |path|
        source = read_host_source(path)
        repl.run_code(source) if source
      end
    end
  end

  private def self.read_host_source(path : String) : String?
    if entry = Crystal::Embed::HostSources.find(path)
      return String.new(entry.content)
    end
    if File.exists?(path)
      return File.read(path)
    end
    nil
  end

  # Alias for `load`. Distinguishes intent at the call site; the
  # implementation is identical because every `load` of a known path
  # is a reload anyway.
  def self.reload(path : String) : Nil
    load(path)
  end

  # Drops the module's bookkeeping. The first cut does not free JIT
  # memory — Phase B6 introduces epoch-based draining. After `unload`,
  # subsequent `load` of the same path re-runs the top-level code.
  def self.unload(path : String) : Nil
    canonical = File.expand_path(path)
    @@mutex.synchronize do
      @@loaded_paths.delete(canonical)
    end
  end

  # Returns the set of paths currently considered loaded.
  def self.loaded_paths : Array(String)
    @@mutex.synchronize { @@loaded_paths.keys }
  end

  private def self.ensure_repl : Crystal::JIT::Repl
    @@repl ||= begin
      @@first_load_pid = Process.pid
      repl = Crystal::JIT::Repl.new
      # The JIT side intentionally does *not* carry the `embed_compiler`
      # flag. That flag tells AOT codegen to restrict dispatch indirection
      # to `@[Embeddable]` defs; on the JIT side we want the blanket
      # JIT REPL dispatch shape so reloads of plain top-level defs keep
      # working. Loaded modules that explicitly `require "embed"` would
      # see the embed source files no-op out (their `skip_file` gate
      # checks this flag) — that's a deliberate limit, since loaded
      # modules don't recursively embed-load each other in v1.
      repl
    end
  end

  private def self.check_fork_safety! : Nil
    pid = @@first_load_pid
    return if pid.nil?
    return if pid == Process.pid
    raise PostForkLoadRefused.new(
      "Crystal::Embed.load called from a forked child (parent pid=#{pid}, child pid=#{Process.pid}); " \
      "LLJIT-mapped memory shared via fork can't be safely extended in the child")
  end

  # Snapshots the AST `object_id`s of every top-level def known to the
  # JIT `Program` so the post-load slot-filler can spot defs the latest
  # submission introduced (or *replaced*, on redef). Comparing names
  # alone would miss "module B redefines a method previously filled by
  # module A" because the name persists across the swap; the object_id
  # set differs because each parse produces fresh `Def` AST nodes.
  private def self.snapshot_top_level_def_ids(repl : Crystal::JIT::Repl) : Hash(String, Set(UInt64))
    result = {} of String => Set(UInt64)
    defs = repl.program.defs
    return result unless defs
    defs.each do |name, defs_list|
      result[name] = defs_list.map(&.def.object_id).to_set
    end
    result
  end

  # After a successful `repl.run_code(source)`, walks every declared
  # slot, finds top-level defs introduced by this submission that match,
  # validates signatures, and installs the JIT-emitted function address
  # into the host's slot. A mismatch raises `SignatureMismatch` and
  # leaves the slot at its previous value (which is `nil` until first
  # successful fill).
  private def self.fill_declared_slots(repl : Crystal::JIT::Repl,
                                       canonical_path : String,
                                       before_def_ids : Hash(String, Set(UInt64))) : Nil
    return if Crystal::Embed::DeclaredSlots.empty?

    program = repl.program
    program_defs = program.defs
    return unless program_defs

    Crystal::Embed::DeclaredSlots.each do |slot|
      defs_entries = program_defs[slot.name]?
      next if defs_entries.nil? || defs_entries.empty?

      # The slot is in play for *this* load iff at least one def with
      # this name has an `object_id` the pre-load snapshot didn't see.
      # That captures fresh adds and redefs without spuriously filling
      # for unrelated modules whose load happened later than module A's
      # first fill.
      prior_ids = before_def_ids[slot.name]? || Set(UInt64).new
      current_ids = defs_entries.map(&.def.object_id).to_set
      next if (current_ids - prior_ids).empty?

      expected_arg_types = slot.arg_type_names.map do |type_name|
        resolved = program.types[type_name]?
        raise "Crystal::Embed: type `#{type_name}` not found while resolving slot `#{slot.name}`" unless resolved
        resolved.as(Crystal::Type)
      end
      expected_return_type = program.types[slot.return_type_name]?
      raise "Crystal::Embed: type `#{slot.return_type_name}` not found while resolving slot `#{slot.name}`" unless expected_return_type

      typed_def = find_def_instance(program, slot.name, expected_arg_types)
      if typed_def.nil?
        first_def = defs_entries.first?.try(&.def)
        actual_sig = first_def ? canonical_signature_from_def(first_def) : "(unknown)"
        raise Crystal::Embed::SignatureMismatch.new(slot.name, slot.canonical_signature, actual_sig)
      end

      actual_return = typed_def.type?
      if actual_return && actual_return != expected_return_type
        actual_sig = canonical_signature_from_typed_def(typed_def)
        raise Crystal::Embed::SignatureMismatch.new(slot.name, slot.canonical_signature, actual_sig)
      end

      mangled = typed_def.mangled_name(program, program)
      addr = repl.session.lljit.lookup(mangled)

      prior = slot.last_owner
      if prior && prior != canonical_path
        STDERR.puts "Crystal::Embed: slot `#{slot.name}` was previously filled by `#{prior}`; replacing with `#{canonical_path}`"
      end

      slot.setter.call(addr)
      slot.last_owner = canonical_path
    end
  end

  private def self.find_def_instance(program : Crystal::Program, slot_name : String,
                                     expected_arg_types : Array(Crystal::Type)) : Crystal::Def?
    program.def_instances.each do |key, candidate|
      next unless candidate.name == slot_name
      next unless key.arg_types == expected_arg_types
      return candidate
    end
    nil
  end

  # Builds a signature string from the AST restrictions on a parsed
  # `Def`. Matches the macro's canonical spelling when the user wrote
  # explicit primitive type restrictions; falls back to `_` for any
  # missing annotation so the error message reflects what the loader
  # actually saw on disk.
  private def self.canonical_signature_from_def(d : Crystal::Def) : String
    args_str = d.args.map { |a| (a.restriction || "_").to_s }.join(", ")
    ret_str = (d.return_type || "_").to_s
    "(#{args_str}) -> #{ret_str}"
  end

  # Same shape as `canonical_signature_from_def` but reads from the
  # post-semantic typed copy, used when a def was successfully matched
  # to an instance with the wrong return type.
  private def self.canonical_signature_from_typed_def(d : Crystal::Def) : String
    args_str = d.args.map { |a| a.type? ? a.type.to_s : "?" }.join(", ")
    ret_str = d.type? ? d.type.to_s : "?"
    "(#{args_str}) -> #{ret_str}"
  end
end
