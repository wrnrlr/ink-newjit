# Tasks

## Rework library and namespaces
I want to change to way the module system works with auto-loading,
namespaces, variable resolution and fully qualified names.
From now on every k file in `./lib` should declared it's own namespace with the same name as the file. So image.k becomes the namespace image.
There should be one exception for the `./lib/_.k` file it should be added to the global namespace.
Other k files loaded with `\l filename.k` should also be in a namespace `filename`.
This means the ./src/cmd/module.zig and others should change.
Make sure the bundeling keeps working. The ./tools/zed-ink extension should also update.
The lsp should also be changed to it resolved the right variables.
There is the issue of public and private variable, add a extra command to do this.
Add the `\public var1 var2` command but also keep the other syntax.
Update existing libraries in `./lib`
The public command also needs support in the zig parser and tree-sitter parser.

## Improve tooling
Fix the following in the zed-ink extension and tree-sitter-ink parser.

## Resolve group vs freq

## Early returns
Implement early returns in a lambda using `:` (like the ngn/k).

## Ink Agent Skills
Help me write skills for developing ink code based on this codebase.
Add skills for the following task profiles.
- Ink development agent: skills, tools, ebnf, idioms, code style
  - parse tool
  - bytecode tool
  - snapshot tool
- Ink native module development

## Doc tool `ink doc`

## Remove `.blank` type

## New operators for colors: cube-root `cbrt`

## Paralle each adverb
Maybe we can use the digram form of the each adverb for parallel each.
There is already stencil and window, we can add `` `ncpu f'!1000 `` to mean
that the function f should be applied to `!1000` distributed over number of cpu cores.

## SPIR-V 1.4 upgrade (blocked — needs Dawn rebuild)
Blocked, not just deferred. Bumping the shader version word to `0x00010400` and
expanding every `OpEntryPoint` interface to list all referenced globals (the two
changes 1.4 requires) was implemented and tested — the prebuilt Dawn rejects it:
"Invalid SPIR-V binary version 1.4 for target environment SPIR-V 1.3 (under
Vulkan 1.1 semantics)". Dawn's SPIR-V ingestion here is pinned to 1.3 / Vulkan
1.1, so any 1.4 module is refused before it runs. Changes were reverted.

Why do it (someday): the only capability 1.4 adds for us is `OpSelect` on
composite/array types (1.3 limits it to scalars/vectors), which would let
`$[cond;a;b]` return structs/arrays — we don't need that yet.

To unblock: first rebuild the vendored `dawn_aarch64_macos` (patches/ + the
prebuilt lazy dep) against a newer SPIR-V/Vulkan target env, then redo the dye.k
edits (version word + per-emitter `iface` expansion — verified working locally,
just version-gated). Don't attempt the dye.k side before the Dawn side. See
`doc/triage.md` item 2 for the full evidence.
