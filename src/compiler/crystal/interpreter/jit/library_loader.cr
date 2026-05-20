module Crystal::JIT
  # Dlopens `@[Link]` libraries so ORC's process resolver finds their
  # symbols at materialisation time. The dedup set keeps a dirty
  # submission from re-opening libraries that are already mapped.
  class LibraryLoader
    @loader : Crystal::Loader? = nil
    @loaded_lib_names = Set(String).new
    @bootstrapped = false

    def initialize(@program : Crystal::Program)
    end

    def bootstrapped? : Bool
      @bootstrapped
    end

    # First-submission bootstrap. Forks pkg-config via `program.lib_flags`
    # so it can race the MT/EC scheduler threads if called too early.
    def bootstrap : Nil
      lib_flags = @program.lib_flags
      lib_flags = lib_flags.gsub(/`(.*?)`/) { `#{$1}`.chomp }
      args = Process.parse_arguments(lib_flags)
      unless @program.has_flag?("win32") && @program.has_flag?("gnu")
        args.delete("-lgc")
      end

      extra_search_paths = [] of String
      libnames = [] of String
      partition_lib_link_tokens(args, extra_search_paths, libnames)

      search_paths = extra_search_paths + Crystal::Loader.default_search_paths
      loader = Crystal::Loader.new(search_paths)
      loader.load_current_program_handle
      libnames.each do |name|
        loader.load_library?(name)
        @loaded_lib_names << name
      end
      @loader = loader
      @bootstrapped = true
    end

    def pick_up_new_link_annotations : Nil
      libnames = [] of String
      extra_search_paths = [] of String
      @program.link_annotations.each do |ann|
        if ldflags = ann.ldflags
          partition_lib_link_tokens(ldflags.split, extra_search_paths, libnames)
        end
        if name = ann.lib
          libnames << name
        end
      end

      unless @program.has_flag?("win32") && @program.has_flag?("gnu")
        libnames.delete("gc")
      end

      loader = @loader.not_nil!
      extra_search_paths.each do |path|
        loader.search_paths << path unless loader.search_paths.includes?(path)
      end
      libnames.each do |name|
        next if @loaded_lib_names.includes?(name)
        loader.load_library?(name)
        @loaded_lib_names << name
      end
    end

    def loader? : Crystal::Loader?
      @loader
    end

    # Splits a flag stream into `-L<dir>` paths and `-l<name>` libnames,
    # appending to the two output accumulators. Other tokens are dropped.
    private def partition_lib_link_tokens(tokens, extra_search_paths : Array(String), libnames : Array(String)) : Nil
      tokens.each do |token|
        if token.starts_with?("-L")
          extra_search_paths << token[2..]
        elsif token.starts_with?("-l")
          libnames << token[2..]
        end
      end
    end
  end
end
