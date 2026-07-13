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

## SPIR-V 1.4 upgrade (blocked — NOT fixable by a Dawn rebuild; WON'T-DO)
Blocked, not just deferred. Bumping the shader version word to `0x00010400` and
expanding every `OpEntryPoint` interface to list all referenced globals (the two
changes 1.4 requires) was implemented and tested — the prebuilt Dawn rejects it:
"Invalid SPIR-V binary version 1.4 for target environment SPIR-V 1.3 (under
Vulkan 1.1 semantics)". Changes were reverted.

Why do it (someday): the only capability 1.4 adds for us is `OpSelect` on
composite/array types (1.3 limits it to scalars/vectors), which would let
`$[cond;a;b]` return structs/arrays — we don't need that yet.

Why a Dawn upgrade CANNOT unblock it (investigated 2026-07-13). The earlier "to
unblock, rebuild Dawn against a newer target env" plan was wrong — it rested on a
misread of the error. ink submits SPIR-V via `ShaderModuleSPIRVDescriptor`
(`lib/gpu/gpu.zig`), which routes through Dawn's **Tint SPIR-V reader**. That
reader is the raw-SPIR-V *ingestion* path WebGPU exposes, and it is fixed to the
**Vulkan 1.1** validation environment (`spirv-val --target-env vulkan1.1`) — which
caps input at **SPIR-V 1.3** (Vulkan 1.1↔1.3; 1.4 would need Vulkan 1.2 env). Per
Dawn/Tint's own docs, "SPIR-V 1.4 and later are not supported in Tint's SPIR-V
reader." This is a property of the WebGPU ingestion path, **not** a build-time
target-env knob in this particular prebuilt, so no Dawn rebuild — and no newer
Dawn — accepts a 1.4 module. (The 1.4 support that "shipped on Android/ChromeOS"
is Tint's *writer*, WGSL→SPIR-V for the Vulkan backend — opposite direction,
irrelevant on macOS/Metal.)

Separately: the vendored `dawn_aarch64_macos` prebuilt (michal-z) has had no new
build since **July 2023** (3 commits total), so there is no newer prebuilt to
point at regardless. Alternative prebuilts exist (jspanchu/webgpu-dawn-binaries,
mach-gpu-dawn) but switching is a real integration project and still wouldn't
lift the reader's 1.3 cap.

The only routes that could ever run 1.4-era features: (a) emit/transpile to WGSL
instead of raw SPIR-V (no version cap, but rewrites the whole GPU back-end), or
(b) drop WebGPU for a raw Metal/Vulkan backend (abandons Dawn). Treat as WON'T-DO
*on WebGPU*. See `.plan/triage.md` "SPIR-V 1.4 upgrade" for evidence.

**If 1.4 IS wanted:** the only path is a SPIR-V-native runtime — full plan in
`doc/design/vulkan-migration.md`. Migrate the GPU host from Dawn/WebGPU to raw
Vulkan via MoltenVK (feeds dye.k's SPIR-V straight to `vkCreateShaderModule`, any
version). ~3–4 weeks; compute half (which delivers 1.4) reachable in week 1.
Mandatory Phase 0 spike proves MoltenVK accepts our 1.4 module before committing.
K-facing FFI stays frozen so all lib/*.k + test/*.k keep working.
