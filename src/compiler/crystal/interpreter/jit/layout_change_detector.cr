module Crystal::JIT
  # walks the user input AST for shapes that would change a
  # class's instance-var layout: declaring or assigning instance vars
  # inside a `class Foo ... end` body, switching the superclass when
  # `Foo` already exists, or `include`-ing a module that may bring its
  # own ivars. Each finding pairs a class path with a `Reason` so
  # `Session#compile` can format the right error and `Repl#reset` hint
  # if the class is already instantiated.
  #
  # The class path here is the AST `Path` as written; resolution against
  # `Program#types` happens in `Session` once semantic visibility for
  # this scope is in place. We only flag top-level `class` declarations
  # plus their direct nested bodies. Generic instantiations and
  # cross-scope reopens are out of scope and fall through silently.
  module LayoutChangeDetector
    extend self

    abstract struct Finding
      getter class_path : Crystal::Path
      getter location : Crystal::Location?

      def initialize(@class_path : Crystal::Path, @location : Crystal::Location?)
      end

      abstract def reason_text : String
    end

    struct IvarDeclFinding < Finding
      def reason_text : String
        "declares a new instance variable"
      end
    end

    struct IvarAssignFinding < Finding
      def reason_text : String
        "assigns a new instance variable"
      end
    end

    # `superclass_path` carries the AST `Path` so Session can resolve it and
    # skip the refusal when it matches the existing superclass. Non-Path
    # superclasses (e.g. `Bar(Int32)`) pass nil and the refusal stays.
    struct SuperclassDeclarationFinding < Finding
      getter superclass_path : Crystal::Path?

      def initialize(@class_path : Crystal::Path, @location : Crystal::Location?, @superclass_path : Crystal::Path?)
      end

      def reason_text : String
        "changes the superclass"
      end
    end

    # The `include` path lets `Session` resolve the included module and
    # skip the refusal when the module brings no instance vars
    # (`include Comparable(self)`, mixin modules that only add methods).
    struct IncludeFinding < Finding
      getter include_path : Crystal::Path?

      def initialize(@class_path : Crystal::Path, @location : Crystal::Location?, @include_path : Crystal::Path?)
      end

      def reason_text : String
        "includes a module that brings instance variables"
      end
    end

    def detect(node : Crystal::ASTNode) : Array(Finding)
      visitor = Visitor.new
      node.accept(visitor)
      visitor.findings
    end

    private class Visitor < Crystal::Visitor
      getter findings : Array(Finding) = [] of Finding

      def visit(node : Crystal::ClassDef) : Bool
        cls_path = node.name
        if super_node = node.superclass
          @findings << SuperclassDeclarationFinding.new(cls_path, node.location, super_node.as?(Crystal::Path))
        end

        scan_body(cls_path, node.body)
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        # Modules can't be instantiated directly, but adding ivars to a
        # module that's included by an instantiated class changes the
        # class's layout. Scan the body the same way - Session resolves
        # the affected classes through `including_types` when needed.
        scan_body(node.name, node.body)
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def scan_body(cls_path : Crystal::Path, body : Crystal::ASTNode)
        case body
        when Crystal::Expressions
          body.expressions.each { |e| scan_one(cls_path, e) }
        else
          scan_one(cls_path, body)
        end
      end

      private def scan_one(cls_path : Crystal::Path, e : Crystal::ASTNode)
        case e
        when Crystal::TypeDeclaration
          var = e.var
          if var.is_a?(Crystal::InstanceVar)
            @findings << IvarDeclFinding.new(cls_path, e.location)
          end
        when Crystal::Assign
          target = e.target
          if target.is_a?(Crystal::InstanceVar)
            @findings << IvarAssignFinding.new(cls_path, e.location)
          end
        when Crystal::Include
          inc_path = e.name.as?(Crystal::Path)
          @findings << IncludeFinding.new(cls_path, e.location, inc_path)
        end
      end
    end
  end
end
