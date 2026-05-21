require "../../../spec_helper"

describe Crystal::Compiler do
  describe "embed_compiler_mode" do
    it "defaults to nil" do
      Crystal::Compiler.new.embed_compiler?.should be_false
    end

    it "is set via the property" do
      compiler = Crystal::Compiler.new
      compiler.embed_compiler_mode = Crystal::Compiler::EmbedCompilerMode::Dynamic
      compiler.embed_compiler?.should be_true
      compiler.embed_compiler_mode.should eq(Crystal::Compiler::EmbedCompilerMode::Dynamic)
    end
  end

  describe "EmbedCompilerMode.parse?" do
    it "parses dynamic" do
      Crystal::Compiler::EmbedCompilerMode.parse?("dynamic").should eq(Crystal::Compiler::EmbedCompilerMode::Dynamic)
    end

    it "parses static" do
      Crystal::Compiler::EmbedCompilerMode.parse?("static").should eq(Crystal::Compiler::EmbedCompilerMode::Static)
    end

    it "returns nil for unknown values" do
      Crystal::Compiler::EmbedCompilerMode.parse?("invalid").should be_nil
      Crystal::Compiler::EmbedCompilerMode.parse?("").should be_nil
    end
  end
end

describe Crystal::Command do
  describe "build --embed-compiler" do
    crystal_bin = ENV["CRYSTAL_SPEC_COMPILER_BIN"]? || "bin/crystal"
    sample = File.tempname("embed_b0_", ".cr")
    File.write(sample, "nil\n")
    output = File.tempname("embed_b0_out")

    Spec.after_suite do
      File.delete?(sample)
      File.delete?(output)
    end

    it "accepts bare --embed-compiler as dynamic" do
      status = Process.run(crystal_bin,
        ["build", "--embed-compiler", "--prelude=empty", sample, "-o", output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      status.exit_code.should eq(0)
    end

    it "accepts --embed-compiler=dynamic" do
      status = Process.run(crystal_bin,
        ["build", "--embed-compiler=dynamic", "--prelude=empty", sample, "-o", output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      status.exit_code.should eq(0)
    end

    it "accepts --embed-compiler=static" do
      status = Process.run(crystal_bin,
        ["build", "--embed-compiler=static", "--prelude=empty", sample, "-o", output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      status.exit_code.should eq(0)
    end

    it "rejects an unknown mode" do
      stderr_io = IO::Memory.new
      status = Process.run(crystal_bin,
        ["build", "--embed-compiler=invalid", sample],
        output: Process::Redirect::Close,
        error: stderr_io)
      status.exit_code.should_not eq(0)
      stderr_io.to_s.should contain("Invalid --embed-compiler mode")
    end

    it "rejects --embed-compiler with --static" do
      stderr_io = IO::Memory.new
      status = Process.run(crystal_bin,
        ["build", "--embed-compiler", "--static", sample],
        output: Process::Redirect::Close,
        error: stderr_io)
      status.exit_code.should_not eq(0)
      stderr_io.to_s.should contain("incompatible with --static")
    end

    it "rejects --embed-compiler with --cross-compile" do
      stderr_io = IO::Memory.new
      status = Process.run(crystal_bin,
        ["build", "--embed-compiler", "--cross-compile", sample],
        output: Process::Redirect::Close,
        error: stderr_io)
      status.exit_code.should_not eq(0)
      stderr_io.to_s.should contain("incompatible with --cross-compile")
    end

    it "rejects --static --embed-compiler (order-independent)" do
      stderr_io = IO::Memory.new
      status = Process.run(crystal_bin,
        ["build", "--static", "--embed-compiler", sample],
        output: Process::Redirect::Close,
        error: stderr_io)
      status.exit_code.should_not eq(0)
      stderr_io.to_s.should contain("incompatible with --static")
    end
  end

  describe "build --embed-compiler (B1a: AOT dispatch indirection)" do
    crystal_bin = ENV["CRYSTAL_SPEC_COMPILER_BIN"]? || "bin/crystal"

    pending! "requires `nm` in PATH" unless Process.find_executable("nm")

    program = <<-CRYSTAL
      def greet(name)
        "hi \#{name}"
      end

      class Container
        def initialize(@v : Int32)
        end

        def value
          @v
        end
      end

      puts greet("world")
      puts Container.new(7).value
      CRYSTAL

    sample = File.tempname("embed_b1a_", ".cr")
    File.write(sample, program)

    normal_output = File.tempname("embed_b1a_normal")
    embed_output = File.tempname("embed_b1a_embed")

    Spec.after_suite do
      File.delete?(sample)
      File.delete?(normal_output)
      File.delete?(embed_output)
    end

    it "emits no slot symbols without --embed-compiler" do
      Process.run(crystal_bin,
        ["build", sample, "-o", normal_output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close).success?.should be_true
      slot_count = `nm "#{normal_output}" 2>/dev/null | grep -c ':slot'`.strip.to_i
      slot_count.should eq(0)
    end

    it "emits slot symbols with --embed-compiler" do
      Process.run(crystal_bin,
        ["build", "--embed-compiler", sample, "-o", embed_output],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close).success?.should be_true
      slot_count = `nm "#{embed_output}" 2>/dev/null | grep -c ':slot'`.strip.to_i
      slot_count.should be > 0
    end

    it "produces identical output with and without --embed-compiler" do
      [normal_output, embed_output].each do |path|
        File.exists?(path).should be_true
      end

      normal_out = IO::Memory.new
      embed_out = IO::Memory.new
      Process.run(normal_output, output: normal_out, error: Process::Redirect::Close)
      Process.run(embed_output, output: embed_out, error: Process::Redirect::Close)
      embed_out.to_s.should eq(normal_out.to_s)
      normal_out.to_s.should eq("hi world\n7\n")
    end

    it "B1b: restricts indirection to @[Embeddable] defs/types" do
      annotated_sample = File.tempname("embed_b1b_", ".cr")
      annotated_output = File.tempname("embed_b1b_out")
      File.write(annotated_sample, <<-CRYSTAL)
        @[Embeddable]
        class Tagged
          def initialize(@a : Int32)
          end

          def add(other : Int32)
            @a += other
            self
          end

          def value
            @a
          end
        end

        class Plain
          def initialize(@x : Int32)
          end

          def mul(other : Int32)
            @x *= other
            self
          end
        end

        t = Tagged.new(10)
        t.add(5)
        puts t.value

        p = Plain.new(3)
        p.mul(4)
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", annotated_sample, "-o", annotated_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        slot_lines = `nm "#{annotated_output}" 2>/dev/null | grep ':slot'`.lines
        tagged_slots = slot_lines.count(&.includes?("Tagged"))
        plain_slots = slot_lines.count(&.includes?("Plain"))
        tagged_slots.should be > 0
        plain_slots.should eq(0)
      ensure
        File.delete?(annotated_sample)
        File.delete?(annotated_output)
      end
    end

    it "B1b: propagates @[Embeddable] from ancestor classes" do
      ancestor_sample = File.tempname("embed_b1b_ancestor_", ".cr")
      ancestor_output = File.tempname("embed_b1b_ancestor_out")
      File.write(ancestor_sample, <<-CRYSTAL)
        @[Embeddable]
        abstract class Plugin
          abstract def name : String
        end

        class MyPlugin < Plugin
          def name : String
            "loaded"
          end

          def helper(x : Int32)
            x + 1
          end
        end

        p = MyPlugin.new
        puts p.name
        puts p.helper(42)
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", ancestor_sample, "-o", ancestor_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        slot_lines = `nm "#{ancestor_output}" 2>/dev/null | grep ':slot'`.lines
        myplugin_slots = slot_lines.count(&.includes?("MyPlugin"))
        myplugin_slots.should be > 0
      ensure
        File.delete?(ancestor_sample)
        File.delete?(ancestor_output)
      end
    end

    it "Symbol#to_s works without a Session under --embed-compiler" do
      sym_sample = File.tempname("embed_sym_", ".cr")
      sym_output = File.tempname("embed_sym_out")
      File.write(sym_sample, <<-CRYSTAL)
        # `Symbol#to_s` reads through `:symbol_table:slot`; AOT builds have no
        # `Session#repoint_slot` to populate the slot at runtime, so codegen
        # must prime it at link time. Calling `.to_s` would dereference NULL
        # without the fix.
        puts :hello.to_s
        puts :world.to_s
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", sym_sample, "-o", sym_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(sym_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("hello\nworld\n")
      ensure
        File.delete?(sym_sample)
        File.delete?(sym_output)
      end
    end

    it "B1c: slot symbols are dlsym-resolvable from the host binary" do
      dlsym_sample = File.tempname("embed_b1c_", ".cr")
      dlsym_output = File.tempname("embed_b1c_out")
      File.write(dlsym_sample, <<-CRYSTAL)
        @[Embeddable]
        class Tagged
          def initialize(@a : Int32)
          end

          def add(other : Int32)
            @a += other
            self
          end
        end

        t = Tagged.new(10)
        t.add(5)

        @[Link("dl")]
        lib LibDL
          RTLD_DEFAULT = Pointer(Void).null
          fun dlsym(handle : Void*, name : LibC::Char*) : Void*
        end

        slot_name = "*Tagged::new<Int32>:Tagged:slot"
        slot_addr = LibDL.dlsym(LibDL::RTLD_DEFAULT, slot_name)
        if slot_addr.null?
          puts "missing"
        else
          puts "found"
        end
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", dlsym_sample, "-o", dlsym_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(dlsym_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("found\n")
      ensure
        File.delete?(dlsym_sample)
        File.delete?(dlsym_output)
      end
    end

    it "B2: emits __crystal_embedded_sources symbols when --embed-compiler is set" do
      b2_sample = File.tempname("embed_b2_", ".cr")
      b2_output = File.tempname("embed_b2_out")
      File.write(b2_sample, %(puts "hi"\n))
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", b2_sample, "-o", b2_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        nm = `nm "#{b2_output}" 2>/dev/null`
        nm.should contain("__crystal_embedded_sources_data")
        nm.should contain("__crystal_embedded_sources_size")
      ensure
        File.delete?(b2_sample)
        File.delete?(b2_output)
      end
    end

    it "B2: HostSources reports a non-empty source set under --embed-compiler" do
      b2_sample = File.tempname("embed_b2_use_", ".cr")
      b2_output = File.tempname("embed_b2_use_out")
      File.write(b2_sample, <<-CRYSTAL)
        require "embed"

        total = Crystal::Embed::HostSources.size
        stdlib = Crystal::Embed::HostSources.stdlib_entries.size
        host = Crystal::Embed::HostSources.host_entries.size

        puts "total=\#{total} stdlib=\#{stdlib} host=\#{host}"
        puts "ok" if total > 0 && stdlib > 0 && host >= 1 && total == stdlib + host
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", b2_sample, "-o", b2_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(b2_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should contain("ok")
      ensure
        File.delete?(b2_sample)
        File.delete?(b2_output)
      end
    end

    it "B2: HostSources content is byte-for-byte identical to disk" do
      b2_sample = File.tempname("embed_b2_content_", ".cr")
      b2_output = File.tempname("embed_b2_content_out")
      File.write(b2_sample, <<-CRYSTAL)
        require "embed"

        # Try to find any entry and compare against disk
        Crystal::Embed::HostSources.each do |entry|
          next unless File.exists?(entry.path)
          embedded = String.new(entry.content)
          disk = File.read(entry.path)
          if embedded == disk
            puts "match"
            exit 0
          else
            puts "mismatch"
            exit 1
          end
        end
        puts "no_entry_found"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", b2_sample, "-o", b2_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(b2_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("match\n")
      ensure
        File.delete?(b2_sample)
        File.delete?(b2_output)
      end
    end

    it "B3: requiring embed links libLLVM into the user binary (dynamic mode)" do
      pending! "requires `ldd` in PATH" unless Process.find_executable("ldd")

      b3_sample = File.tempname("embed_b3_", ".cr")
      b3_output = File.tempname("embed_b3_out")
      File.write(b3_sample, <<-CRYSTAL)
        require "embed"
        puts "booted"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", b3_sample, "-o", b3_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true

        # Boots cleanly without invoking the compiler.
        out_io = IO::Memory.new
        Process.run(b3_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("booted\n")

        # libLLVM is dynamically linked under the default mode.
        ldd_out = IO::Memory.new
        Process.run("ldd", [b3_output], output: ldd_out, error: Process::Redirect::Close)
        ldd_out.to_s.should match(/libLLVM/i)
      ensure
        File.delete?(b3_sample)
        File.delete?(b3_output)
      end
    end

    it "B4: Crystal::Embed.load runs a script's top-level code in-process" do
      b4_sample = File.tempname("embed_b4_", ".cr")
      b4_output = File.tempname("embed_b4_out")
      plugin_path = File.tempname("embed_b4_plugin_", ".cr")
      File.write(plugin_path, %(puts "plugin loaded"))
      File.write(b4_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.load(#{plugin_path.inspect})
        puts "after load"
        puts "tracked: \#{Crystal::Embed.loaded_paths.size}"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", b4_sample, "-o", b4_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(b4_output, output: out_io, error: Process::Redirect::Close)
        output_str = out_io.to_s
        output_str.should contain("plugin loaded")
        output_str.should contain("after load")
        output_str.should contain("tracked: 1")
      ensure
        File.delete?(b4_sample)
        File.delete?(b4_output)
        File.delete?(plugin_path)
      end
    end

    it "B4: reload picks up file content changes" do
      b4_sample = File.tempname("embed_b4_reload_", ".cr")
      b4_output = File.tempname("embed_b4_reload_out")
      plugin_path = File.tempname("embed_b4_plugin_dyn_", ".cr")
      File.write(b4_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        plugin = #{plugin_path.inspect}
        File.write(plugin, "puts \\"version A\\"")
        Crystal::Embed.load(plugin)
        File.write(plugin, "puts \\"version B\\"")
        Crystal::Embed.reload(plugin)
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", b4_sample, "-o", b4_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(b4_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("version A\nversion B\n")
      ensure
        File.delete?(b4_sample)
        File.delete?(b4_output)
        File.delete?(plugin_path)
      end
    end

    it "B4: unload drops the path from loaded_paths" do
      b4_sample = File.tempname("embed_b4_unload_", ".cr")
      b4_output = File.tempname("embed_b4_unload_out")
      plugin_path = File.tempname("embed_b4_unload_plug_", ".cr")
      File.write(plugin_path, "x = 1")
      File.write(b4_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.load(#{plugin_path.inspect})
        before = Crystal::Embed.loaded_paths.size
        Crystal::Embed.unload(#{plugin_path.inspect})
        after = Crystal::Embed.loaded_paths.size
        puts "before=\#{before} after=\#{after}"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", b4_sample, "-o", b4_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(b4_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("before=1 after=0\n")
      ensure
        File.delete?(b4_sample)
        File.delete?(b4_output)
        File.delete?(plugin_path)
      end
    end

    it "B5a: Registry stores, iterates, replaces, and unregisters" do
      b5_sample = File.tempname("embed_b5a_", ".cr")
      b5_output = File.tempname("embed_b5a_out")
      File.write(b5_sample, <<-CRYSTAL)
        require "embed"

        reg = Crystal::Embed::Registry(String).new
        reg.register("a", "owner_1")
        reg.register("b", "owner_2")
        puts "size=\#{reg.size}"

        names = [] of String
        reg.each { |v| names << v }
        puts "values=\#{names.sort.join(",")}"

        # Replace an entry
        reg.register("a2", "owner_1")
        puts "after-replace size=\#{reg.size}"
        puts "owner_1=\#{reg["owner_1"]}"

        reg.unregister("owner_1")
        puts "after-unregister size=\#{reg.size}"
        puts "owner_1=\#{reg["owner_1"].inspect}"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", b5_sample, "-o", b5_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(b5_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq(<<-OUT + "\n")
          size=2
          values=a,b
          after-replace size=2
          owner_1=a2
          after-unregister size=1
          owner_1=nil
          OUT
      ensure
        File.delete?(b5_sample)
        File.delete?(b5_output)
      end
    end

    it "B5a: before_reload hook fires only on reload of known paths" do
      b5_sample = File.tempname("embed_b5a_hook_", ".cr")
      b5_output = File.tempname("embed_b5a_hook_out")
      plugin_path = File.tempname("embed_b5a_plug_", ".cr")
      File.write(plugin_path, "x = 1")
      File.write(b5_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        hook_fired = [] of String
        Crystal::Embed.before_reload do |path|
          hook_fired << path
        end

        Crystal::Embed.load(#{plugin_path.inspect})
        puts "after-first-load: fired=\#{hook_fired.size}"

        Crystal::Embed.load(#{plugin_path.inspect})  # reload
        puts "after-reload: fired=\#{hook_fired.size}"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", b5_sample, "-o", b5_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(b5_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("after-first-load: fired=0\nafter-reload: fired=1\n")
      ensure
        File.delete?(b5_sample)
        File.delete?(b5_output)
        File.delete?(plugin_path)
      end
    end

    it "B5b/partial: materialize_files lets loaded modules subclass walked types" do
      mat_sample = File.tempname("embed_mat_", ".cr")
      mat_output = File.tempname("embed_mat_out")
      base_path = File.tempname("embed_mat_base_", ".cr")
      impl_path = File.tempname("embed_mat_impl_", ".cr")
      File.write(base_path, <<-CR)
        abstract class Pluggable
          abstract def label : String
        end
        CR
      File.write(impl_path, <<-CR)
        class Hello < Pluggable
          def label : String
            "hello from impl"
          end
        end
        puts Hello.new.label
        CR
      File.write(mat_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.materialize_files([#{base_path.inspect}])
        Crystal::Embed.load(#{impl_path.inspect})
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", mat_sample, "-o", mat_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(mat_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("hello from impl\n")
      ensure
        File.delete?(mat_sample)
        File.delete?(mat_output)
        File.delete?(base_path)
        File.delete?(impl_path)
      end
    end

    it "B5c: loaded modules resolve stdlib + GC + exception symbols through JIT linker" do
      # End-to-end audit: a loaded module exercises stdlib (puts, string
      # interpolation), allocation (the GC path), and exception handling
      # (begin/rescue). If any host-provided symbol in those code paths
      # were missing from the JIT's resolver, the load would fail.
      audit_sample = File.tempname("embed_b5c_", ".cr")
      audit_output = File.tempname("embed_b5c_out")
      plugin_path = File.tempname("embed_b5c_plug_", ".cr")
      File.write(plugin_path, <<-CR)
        # Exercises: GC (Array allocation), exception unwind (rescue),
        # string interpolation (stdlib), iteration (block dispatch).
        arr = [1, 2, 3, 4, 5]
        squared = arr.map { |x| x * x }
        puts "squared: \#{squared}"

        result = begin
          raise "boom"
        rescue ex
          "rescued: \#{ex.message}"
        end
        puts result
        CR
      File.write(audit_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.load(#{plugin_path.inspect})
        puts "host-after-load"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", audit_sample, "-o", audit_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(audit_output, output: out_io, error: Process::Redirect::Close)
        text = out_io.to_s
        text.should contain("squared: [1, 4, 9, 16, 25]")
        text.should contain("rescued: boom")
        text.should contain("host-after-load")
      ensure
        File.delete?(audit_sample)
        File.delete?(audit_output)
        File.delete?(plugin_path)
      end
    end

    it "B7: integration — load, materialize, subclass, register, reload" do
      base_path = File.tempname("embed_b7_base_", ".cr")
      plug_path = File.tempname("embed_b7_plug_", ".cr")
      host_path = File.tempname("embed_b7_host_", ".cr")
      host_output = File.tempname("embed_b7_host_out")

      File.write(base_path, <<-CR)
        abstract class Adapter
          abstract def label : String
        end
        CR

      File.write(host_path, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.materialize_files([#{base_path.inspect}])

        # First load: defines a subclass and prints its label.
        File.write(#{plug_path.inspect}, <<-CR)
          class V1 < Adapter
            def label : String
              "version-1"
            end
          end
          puts V1.new.label
          CR
        Crystal::Embed.load(#{plug_path.inspect})

        # Reload with a different body picks up the new label.
        File.write(#{plug_path.inspect}, <<-CR)
          class V2 < Adapter
            def label : String
              "version-2"
            end
          end
          puts V2.new.label
          CR
        Crystal::Embed.reload(#{plug_path.inspect})

        # Unload drops the tracking but leaves the JIT state.
        Crystal::Embed.unload(#{plug_path.inspect})
        puts "tracked-after-unload: \#{Crystal::Embed.loaded_paths.size}"

        # Stdlib + GC + iteration from a loaded module.
        File.write(#{plug_path.inspect}, <<-CR)
          values = (1..5).to_a
          puts values.sum
          CR
        Crystal::Embed.load(#{plug_path.inspect})
        CRYSTAL

      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", host_path, "-o", host_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(host_output, output: out_io, error: Process::Redirect::Close)
        text = out_io.to_s
        text.should contain("version-1")
        text.should contain("version-2")
        text.should contain("tracked-after-unload: 0")
        text.should contain("15")  # sum of 1..5
      ensure
        File.delete?(base_path)
        File.delete?(plug_path)
        File.delete?(host_path)
        File.delete?(host_output)
      end
    end

    it "sets the embed_compiler macro flag" do
      flag_check_sample = File.tempname("embed_b1a_flag_", ".cr")
      flag_check_output = File.tempname("embed_b1a_flag_output")
      File.write(flag_check_sample, <<-CRYSTAL)
        {% if flag?(:embed_compiler) %}
          puts "embed"
        {% else %}
          puts "plain"
        {% end %}
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", flag_check_sample, "-o", flag_check_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(flag_check_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("embed\n")
      ensure
        File.delete?(flag_check_sample)
        File.delete?(flag_check_output)
      end
    end

    it "B5b: declare_slot returns nil before any module fills the slot" do
      ds_sample = File.tempname("embed_ds_nil_", ".cr")
      ds_output = File.tempname("embed_ds_nil_out")
      File.write(ds_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.declare_slot compute : (Int32, Int32) -> Int32

        puts "count=\#{Crystal::Embed::DeclaredSlots.size}"
        puts "value=\#{Crystal::Embed.compute.inspect}"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", ds_sample, "-o", ds_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(ds_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("count=1\nvalue=nil\n")
      ensure
        File.delete?(ds_sample)
        File.delete?(ds_output)
      end
    end

    it "B5b: declare_slot fills from a loaded module's top-level def" do
      ds_sample = File.tempname("embed_ds_fill_", ".cr")
      ds_output = File.tempname("embed_ds_fill_out")
      plugin_path = File.tempname("embed_ds_fill_plug_", ".cr")
      File.write(plugin_path, <<-CR)
        def compute(a : Int32, b : Int32) : Int32
          a + b
        end
        CR
      File.write(ds_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.declare_slot compute : (Int32, Int32) -> Int32

        Crystal::Embed.load(#{plugin_path.inspect})
        proc = Crystal::Embed.compute
        if proc
          puts "filled: \#{proc.call(3, 4)}"
        else
          puts "unfilled"
        end
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", ds_sample, "-o", ds_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(ds_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("filled: 7\n")
      ensure
        File.delete?(ds_sample)
        File.delete?(ds_output)
        File.delete?(plugin_path)
      end
    end

    it "B5b: declare_slot raises SignatureMismatch when the def's types differ" do
      ds_sample = File.tempname("embed_ds_mis_", ".cr")
      ds_output = File.tempname("embed_ds_mis_out")
      plugin_path = File.tempname("embed_ds_mis_plug_", ".cr")
      File.write(plugin_path, <<-CR)
        def compute(s : String) : String
          s + "!"
        end
        CR
      File.write(ds_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.declare_slot compute : (Int32, Int32) -> Int32

        begin
          Crystal::Embed.load(#{plugin_path.inspect})
          puts "unexpected: load succeeded"
        rescue ex : Crystal::Embed::SignatureMismatch
          puts "slot=\#{ex.slot_name}"
          puts "expected=\#{ex.expected}"
          puts "actual=\#{ex.actual}"
          puts "still-nil=\#{Crystal::Embed.compute.nil?}"
        end
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", ds_sample, "-o", ds_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(ds_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq(<<-OUT + "\n")
          slot=compute
          expected=(Int32, Int32) -> Int32
          actual=(String) -> String
          still-nil=true
          OUT
      ensure
        File.delete?(ds_sample)
        File.delete?(ds_output)
        File.delete?(plugin_path)
      end
    end

    it "B5b: declare_slot reload picks up the new body" do
      ds_sample = File.tempname("embed_ds_reload_", ".cr")
      ds_output = File.tempname("embed_ds_reload_out")
      plugin_path = File.tempname("embed_ds_reload_plug_", ".cr")
      File.write(ds_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.declare_slot compute : (Int32, Int32) -> Int32

        plugin = #{plugin_path.inspect}
        File.write(plugin, <<-CR)
          def compute(a : Int32, b : Int32) : Int32
            a + b
          end
          CR
        Crystal::Embed.load(plugin)
        puts "v1: \#{Crystal::Embed.compute.try &.call(10, 5)}"

        File.write(plugin, <<-CR)
          def compute(a : Int32, b : Int32) : Int32
            a * b
          end
          CR
        Crystal::Embed.reload(plugin)
        puts "v2: \#{Crystal::Embed.compute.try &.call(10, 5)}"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", ds_sample, "-o", ds_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        out_io = IO::Memory.new
        Process.run(ds_output, output: out_io, error: Process::Redirect::Close)
        out_io.to_s.should eq("v1: 15\nv2: 50\n")
      ensure
        File.delete?(ds_sample)
        File.delete?(ds_output)
        File.delete?(plugin_path)
      end
    end

    it "B5b: declare_slot warns when a second module overwrites a previously-filled slot" do
      ds_sample = File.tempname("embed_ds_multi_", ".cr")
      ds_output = File.tempname("embed_ds_multi_out")
      plug_a = File.tempname("embed_ds_multi_a_", ".cr")
      plug_b = File.tempname("embed_ds_multi_b_", ".cr")
      File.write(plug_a, <<-CR)
        def greet(name : String) : String
          "hello, " + name
        end
        CR
      File.write(plug_b, <<-CR)
        def greet(name : String) : String
          "hi, " + name
        end
        CR
      File.write(ds_sample, <<-CRYSTAL)
        require "embed"
        Crystal::Config.path = "/home/vegai/git/crystal/src"

        Crystal::Embed.declare_slot greet : (String) -> String

        Crystal::Embed.load(#{plug_a.inspect})
        puts "A: \#{Crystal::Embed.greet.try &.call("world")}"
        Crystal::Embed.load(#{plug_b.inspect})
        puts "B: \#{Crystal::Embed.greet.try &.call("world")}"
        CRYSTAL
      begin
        Process.run(crystal_bin,
          ["build", "--embed-compiler", ds_sample, "-o", ds_output],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close).success?.should be_true
        stdout_io = IO::Memory.new
        stderr_io = IO::Memory.new
        Process.run(ds_output, output: stdout_io, error: stderr_io)
        stdout_io.to_s.should eq("A: hello, world\nB: hi, world\n")
        stderr_io.to_s.should contain("previously filled")
        stderr_io.to_s.should contain("greet")
      ensure
        File.delete?(ds_sample)
        File.delete?(ds_output)
        File.delete?(plug_a)
        File.delete?(plug_b)
      end
    end

    it "B5b: declare_slot rejects host-defined classes in the signature at macro expansion" do
      ds_sample = File.tempname("embed_ds_bad_", ".cr")
      File.write(ds_sample, <<-CRYSTAL)
        require "embed"

        class Order; end

        Crystal::Embed.declare_slot process : (Order) -> Nil
        CRYSTAL
      begin
        stderr_io = IO::Memory.new
        status = Process.run(crystal_bin,
          ["build", "--embed-compiler", ds_sample, "-o", File.tempname("embed_ds_bad_out")],
          output: Process::Redirect::Close,
          error: stderr_io)
        status.success?.should be_false
        msg = stderr_io.to_s
        msg.should contain("not in the safe-types allowlist")
        msg.should contain("materialize_files")
      ensure
        File.delete?(ds_sample)
      end
    end
  end
end
