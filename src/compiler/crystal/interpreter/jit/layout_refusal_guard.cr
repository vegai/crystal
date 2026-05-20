module Crystal::JIT
  class Session
    # Nested under `Session` so `Repl#with_rescue` and the layout
    # refusal spec keep using `Crystal::JIT::Session::LayoutChangeRefused`.
    class LayoutChangeRefused < Exception
    end
  end

  # Refuses layout-changing redefs of types that already have live
  # instances. Filters `LayoutChangeDetector` findings for false
  # positives (no-ivar `include`, restated superclass) before raising.
  class LayoutRefusalGuard
    def initialize(@program : Crystal::Program, @lljit : LLVM::Orc::LLJIT)
    end

    # Unresolved class paths fall through silently to normal semantic.
    def check(node : ASTNode, repl_state : Crystal::ReplState) : Nil
      findings = LayoutChangeDetector.detect(node)
      return if findings.empty?

      seen = Set(String).new
      findings.each do |finding|
        type_name = AstHelpers.path_to_string(finding.class_path).presence
        next unless type_name
        next if seen.includes?(type_name)
        existing = @program.types[type_name]?
        next unless existing.is_a?(Crystal::ModuleType)
        next unless type_has_live_instance?(existing, repl_state)

        # `include` with no ivars and a restated superclass do not change layout.
        case finding.kind
        when .include?
          next if include_module_brings_no_ivars?(finding.related_path)
        when .superclass?
          next if superclass_unchanged?(existing, finding.related_path)
        end

        seen << type_name
        raise Session::LayoutChangeRefused.new(
          "#{type_name} #{finding.reason_text}, but at least one instance has been allocated. " \
          "Hot reload can't relayout existing objects safely; call `Crystal::JIT::Repl#reset` " \
          "to drop the program state and start over.")
      end
    end

    private def type_has_live_instance?(type : Crystal::ModuleType, repl_state : Crystal::ReplState) : Bool
      flag_name = Crystal::CodeGenVisitor.repl_instantiated_flag_name(type)
      return false unless repl_state.flag_registered?(flag_name)
      flag_ptr = @lljit.lookup(flag_name)
      return false if flag_ptr.address == 0
      flag_ptr.as(UInt8*).value != 0
    end

    private def include_module_brings_no_ivars?(path : Crystal::Path?) : Bool
      return false unless path
      name = AstHelpers.path_to_string(path).presence
      return false unless name
      mod = @program.types[name]?
      return false unless mod.is_a?(Crystal::ModuleType)
      mod.instance_vars.empty?
    end

    private def superclass_unchanged?(existing : Crystal::ModuleType, path : Crystal::Path?) : Bool
      return false unless path
      name = AstHelpers.path_to_string(path).presence
      return false unless name
      ast_super = @program.types[name]?
      return false unless ast_super
      existing.superclass == ast_super
    end
  end
end
