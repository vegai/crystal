# Crystal

[![Linux CI Build Status](https://github.com/crystal-lang/crystal/workflows/Linux%20CI/badge.svg)](https://github.com/crystal-lang/crystal/actions?query=workflow%3A%22Linux+CI%22+event%3Apush+branch%3Amaster)
[![macOS CI Build Status](https://github.com/crystal-lang/crystal/workflows/macOS%20CI/badge.svg)](https://github.com/crystal-lang/crystal/actions?query=workflow%3A%22macOS+CI%22+event%3Apush+branch%3Amaster)
[![AArch64 CI Build Status](https://github.com/crystal-lang/crystal/workflows/AArch64%20CI/badge.svg)](https://github.com/crystal-lang/crystal/actions?query=workflow%3A%22AArch64+CI%22+event%3Apush+branch%3Amaster)
[![Windows CI Build Status](https://github.com/crystal-lang/crystal/workflows/Windows%20CI/badge.svg)](https://github.com/crystal-lang/crystal/actions?query=workflow%3A%22Windows+CI%22+event%3Apush+branch%3Amaster)
[![CircleCI Build Status](https://circleci.com/gh/crystal-lang/crystal/tree/master.svg?style=shield)](https://circleci.com/gh/crystal-lang/crystal)
[![Join the chat at https://gitter.im/crystal-lang/crystal](https://badges.gitter.im/crystal-lang/crystal.svg)](https://gitter.im/crystal-lang/crystal)
[![Code Triagers Badge](https://www.codetriage.com/crystal-lang/crystal/badges/users.svg)](https://www.codetriage.com/crystal-lang/crystal)

---

## Branch note: experimental JIT interpreter

This `interpreter-experiments` branch adds a second backend for `crystal i`:
`crystal i --backend=jit` routes user code through the existing AOT codegen
pipeline and runs it via LLVM ORC's `LLJIT`, instead of through the bytecode
compiler and VM. Each submission is compiled into LLVM IR by the same
`CodeGenVisitor` the AOT compiler uses, added to a single long-lived
`JITDylib`, materialized by ORC, and invoked via symbol lookup. Design
notes and per-phase progress live in
[`PROTOTYPE_STATUS.md`](PROTOTYPE_STATUS.md).

### Cross-submission state

A `CodeGenVisitor#repl_mode` flag changes how globals and previously-emitted
functions are linked. Already-emitted `target_def`s and `FunDef` externals
become signature-only declarations in later submissions, with the canonical
body kept alive via `LinkOnceODR` linkage so ORC keeps one copy across
modules; class-var storage, type-id tables, slice constants, and once-init
state get the same treatment. Top-level locals are lifted to class vars on a
synthetic `__REPLState` module, and top-level `def`s become class methods on
it, so both persist across submissions.

### Hot reload

Every user `target_def` is emitted as a stub + `:slot` global + versioned
body: callers jump through the stub, which loads the slot pointer and
tail-calls into the current body. Redefining the method emits a new `:vN`
body and writes its address into the slot with an acquire / release pair.
Constants can also be redefined; the global is left mutable in `repl_mode`
and `read_const` goes through a runtime load. Layout-incompatible class
changes are detected pre-semantic and refused with a `reset` hint. State
survives a hot redef; a cold `Repl#reset` drops the program and re-runs
whatever files seeded the Repl.

### What works

- Full `prelude`; FFI to shared libs via `program.lib_flags`. Canonical
  smoke test: `require "big"; puts BigInt.new("999...") * 7` produces
  identical output under JIT and AOT.
- Interactive REPL with `Reply::Reader` line editing, history,
  autocomplete, and multi-line autoindent.
- One-shot mode (`crystal i --backend=jit -e SOURCE`) matching `crystal
  eval`'s exit semantics.
- 783 / 783 interpreter spec parity with the bytecode backend under
  `CRYSTAL_INTERP_BACKEND=jit`.

### Sharing and removability

The JIT side is ~2.6k new LOC under `src/compiler/crystal/interpreter/jit/`,
reuses the AOT codegen at `src/compiler/crystal/codegen/` rather than the
bytecode VM, and shares only `repl_reader.cr` (141 LOC) with the older
interpreter tree. If the JIT replaced the bytecode backend, roughly 11,200
LOC across `src/compiler/crystal/interpreter/` would become removable.

---

[![Crystal - Born and raised at Manas](doc/assets/crystal-born-and-raised.svg)](https://manas.tech/)

Crystal is a programming language with the following goals:

- Have a syntax similar to Ruby (but compatibility with it is not a goal)
- Statically type-checked but without having to specify the type of variables or method arguments.
- Be able to call C code by writing bindings to it in Crystal.
- Have compile-time evaluation and generation of code, to avoid boilerplate code.
- Compile to efficient native code.

## Why?

We love Ruby's efficiency for writing code.

We love C's efficiency for running code.

We want the best of both worlds.

We want the compiler to understand what we mean without having to specify types everywhere.

We want full OOP.

Oh, and we don't want to write C code to make the code run faster.

## Project Status

Within a major version, language features won't be removed or changed in any way that could prevent a Crystal program written with that version from compiling and working. The built-in standard library might be enriched, but it will always be done with backwards compatibility in mind.

Development of the Crystal language is possible thanks to the community's effort and the continued support of [84codes](https://www.84codes.com/) and every other [sponsor](https://crystal-lang.org/sponsors).

## Installing

[Follow these installation instructions](https://crystal-lang.org/install)

## Try it online

[play.crystal-lang.org](https://play.crystal-lang.org/)

## Documentation

- [Language Reference](http://crystal-lang.org/reference)
- [Standard library API](https://crystal-lang.org/api)
- [Roadmap](https://github.com/crystal-lang/crystal/wiki/Roadmap)

## Community

Have any questions or suggestions? Ask on the [Crystal Forum](https://forum.crystal-lang.org), on our [Gitter channel](https://gitter.im/crystal-lang/crystal) or IRC channel [#crystal-lang](https://web.libera.chat/#crystal-lang) at irc.libera.chat, or on Stack Overflow under the [crystal-lang](http://stackoverflow.com/questions/tagged/crystal-lang) tag. There is also an archived [Google Group](https://groups.google.com/forum/?fromgroups#!forum/crystal-lang).

## Contributing

The Crystal repository is hosted at [crystal-lang/crystal](https://github.com/crystal-lang/crystal) on GitHub.

Read the general [Contributing guide](https://github.com/crystal-lang/crystal/blob/master/CONTRIBUTING.md), and then:

1. Fork it (<https://github.com/crystal-lang/crystal/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
