{% skip_file unless flag?(:embed_compiler) %}

# `Crystal::Embed` is the user-facing entry point for in-process module
# loading in `--embed-compiler` builds. See `hot-reload-plan.md` for the
# full design. The actual `load`/`reload`/`unload` surface is built up
# in later phases; this file currently exposes only `HostSources`.
#
# Requiring `embed` pulls in the Crystal compiler + JIT machinery so the
# resulting binary can compile and execute loaded modules in-process.
# The cost is large (build time grows by minutes, binary size by ~50 MB),
# so this require is opt-in instead of auto-injected by the build flag.

require "compiler/crystal/interpreter"
require "./embed/host_sources"
require "./embed/declare_slot"
require "./embed/loader"
require "./embed/registry"
