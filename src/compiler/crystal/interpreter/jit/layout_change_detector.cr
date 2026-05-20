module Crystal::JIT
  # walks the user input AST for shapes that would change a
  # class's instance-var layout: declaring or assigning instance vars
  # inside a `class Foo ... end` body, switching the superclass when
  # `Foo` already exists, or `include`-ing a module that may bring its
  # own ivars. Each finding pairs a class path with a `Kind` so
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

    enum Kind
      IvarDecl
      IvarAssign
      Superclass
      Include
    end

    # `related_path` carries the AST `Path` for `Superclass` (the new
    # superclass) and `Include` (the included module). `Session` resolves
    # it against `Program#types` to filter out no-op shapes (restated
    # superclass, mixin module with no ivars). Ivar findings leave it nil.
    record Finding,
      kind : Kind,
      class_path : Crystal::Path,
      location : Crystal::Location?,
      related_path : Crystal::Path? = nil do
      def reason_text : String
        case kind
        in .ivar_decl?   then "declares a new instance variable"
        in .ivar_assign? then "assigns a new instance variable"
        in .superclass?  then "changes the superclass"
        in .include?     then "includes a module that brings instance variables"
        end
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
          @findings << Finding.new(Kind::Superclass, cls_path, node.location, super_node.as?(Crystal::Path))
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
            @findings << Finding.new(Kind::IvarDecl, cls_path, e.location)
          end
        when Crystal::Assign
          target = e.target
          if target.is_a?(Crystal::InstanceVar)
            @findings << Finding.new(Kind::IvarAssign, cls_path, e.location)
          end
        when Crystal::Include
          inc_path = e.name.as?(Crystal::Path)
          @findings << Finding.new(Kind::Include, cls_path, e.location, inc_path)
        end
      end
    end
  end
end
