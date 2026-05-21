{% skip_file unless flag?(:embed_compiler) %}

module Crystal::Embed
  # Typed registry of instances created by loaded modules. Hosts own
  # one or more registries parameterised on an `@[Embeddable] abstract
  # class` or module. Loaded modules subclass the abstract type and
  # call `register` to register their instance.
  #
  # `Crystal::Embed.load(path)` fires the registered `before_reload`
  # hooks before re-running a previously-loaded file, so registries
  # the host owns get their stale instance dropped before the new
  # one registers.
  #
  # ```
  # @[Embeddable]
  # abstract class Plugin
  #   abstract def name : String
  # end
  #
  # PLUGINS = Crystal::Embed::Registry(Plugin).new
  # Crystal::Embed.before_reload { |path| PLUGINS.unregister(path) }
  # ```
  #
  # NOTE: cross-boundary subclassing (a loaded module subclasses a
  # host-side `@[Embeddable]` abstract class and calls
  # `PLUGINS.register(...)` itself) needs the embedded compiler to
  # re-walk the host source on first load so host types are visible
  # to loaded modules. That `Program` materialisation step is a
  # separate, larger piece of work; until it lands, this registry
  # holds instances the host registers directly.
  class Registry(T)
    def initialize
      @instances = {} of String => T
    end

    # Adds *instance* under *owner* (the loading module's canonical
    # path). A later `register(_, same_owner)` replaces the prior
    # entry; pair with `Crystal::Embed.before_reload` for the typical
    # reload-replaces-old-instance flow.
    def register(instance : T, owner : String) : Nil
      @instances[owner] = instance
    end

    # Drops the entry owned by *owner*. No-op if the owner has no
    # registered instance.
    def unregister(owner : String) : Nil
      @instances.delete(owner)
    end

    # Yields each registered instance in undefined order. The order is
    # currently insertion order (Crystal `Hash` is ordered) but
    # callers should not depend on it.
    def each(& : T ->) : Nil
      @instances.each_value { |v| yield v }
    end

    def size : Int32
      @instances.size
    end

    def empty? : Bool
      @instances.empty?
    end

    # Returns the entry for *owner* or `nil`.
    def [](owner : String) : T?
      @instances[owner]?
    end
  end
end
