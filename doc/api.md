---
title: 'API reference'
kind: api-index
modules: 48
---

# API reference

Generated from `lib/*.k` by `ink tools/doc.k` — do not edit by hand.

A binding is listed here when it starts its own line and carries a comment
block directly above it; everything else is private.

| Module | API | Summary |
| --- | --- | --- |
| [agent](api/agent.md) | 0 |  |
| [asr](api/asr.md) | 16 | the ASR-specific layer: conv subsampling, TDT greedy decode, |
| [audio](api/audio.md) | 39 | audio module (native miniaudio extension). |
| [bits](api/bits.md) | 12 | the `bits` CPU backend (kk.md §3.2, kk2 §4). |
| [camera](api/camera.md) | 4 | orbit camera for the isometric demos. |
| [canvas](api/canvas.md) | 13 | a Canvas/Gio-style 2D recorder over an ops table (Phase 0). |
| [color](api/color.md) | 7 |  |
| [compress](api/compress.md) | 8 | DEFLATE compression module (native Zig std.compress.flate). |
| [conformer](api/conformer.md) | 7 | Conformer convolution module, block and encoder stack. |
| [crypto](api/crypto.md) | 31 | crypto module (native Zig std.crypto extension). |
| [csv](api/csv.md) | 1 | CSV extension |
| [doc](api/doc.md) | 33 | extract API documentation from ink source. |
| [dye](api/dye.md) | 167 | the dye compiler: ink shader front-end + optimizer + SPIR-V codegen. |
| [fbx](api/fbx.md) | 28 | binary FBX reader (pure k) |
| [feat](api/feat.md) | 15 | audio samples → log-mel features. |
| [fft](api/fft.md) | 12 | Cooley-Tukey radix-2 DIT (decimation-in-time). |
| [fmt](api/fmt.md) | 5 | number → string formatting helpers (the `fmt` namespace). |
| [font](api/font.md) | 9 | native sfnt font reader + outline/shape/metrics |
| [fts](api/fts.md) | 0 | FTS |
| [geometry](api/geometry.md) | 17 | the uniform polyhedra from Coxeter groups (Wythoff) |
| [gltf](api/gltf.md) | 15 | glTF 2.0 / GLB reader (pure k, on top of the JSON extension) |
| [gpu](api/gpu.md) | 40 | load GPU extension |
| [http](api/http.md) | 5 | HTTP client module (native Zig std.http.Client). |
| [image](api/image.md) | 15 | format-agnostic image front end (native libimage extension). |
| [json](api/json.md) | 2 | JSON extension |
| [kk](api/kk.md) | 29 | the kk array-level GPU surface (doc/design/kk.md, kk2 §2/§6). |
| [layout](api/layout.md) | 0 | DEPRECATED. Merged into lib/ui.k (2026-07-22): the layout engine + widgets now |
| [lin](api/lin.md) | 7 | PLU decomposition and linear system solver. |
| [llm](api/llm.md) | 22 | LLM chat + streaming for Anthropic and xAI (Grok). |
| [math](api/math.md) | 6 |  |
| [nn](api/nn.md) | 57 | GPU neural-net primitives on the resident-compute stack. |
| [parquet](api/parquet.md) | 1 | Parquet extension |
| [pbr](api/pbr.md) | 2 | physically based renderer (Cook-Torrance) for the ink std lib |
| [pga](api/pga.md) | 16 | Projective Geometric Algebra G(3,0,1) |
| [prelude](api/prelude.md) | 0 | CPU builtins, loaded into every VM at init (see VM.create). |
| [recs](api/recs.md) | 11 | a relational ECS. An archetype is a TABLE [[]id:…;cols…]; an entity is a |
| [regex](api/regex.md) | 0 | Pure-k regex engine (Thompson NFA / Pike VM) |
| [rope](api/rope.md) | 21 | a SumTree rope: a B-tree over text chunks, keyed by summaries. |
| [safetensors](api/safetensors.md) | 1 | Safetensors extension |
| [slug](api/slug.md) | 15 | GPU analytic vector coverage (Slug-style), Phase 1 + band acceleration. |
| [spirv](api/spirv.md) | 98 | SPIR-V instruction stencils (the copy-and-patch "stencil library"). |
| [stats](api/stats.md) | 7 | Statistical functions translated from kyte dialect to ink dialect. |
| [svd](api/svd.md) | 12 | Singular Value Decomposition via the Jacobi-Hestenes algorithm. |
| [syntax](api/syntax.md) | 12 | configurable syntax highlighting. |
| [ui](api/ui.md) | 40 | a tables-as-ECS immediate-mode UI toolkit (widgets + flexbox + input, one `ui` |
| [uitest](api/uitest.md) | 36 | a deterministic, replayable test harness for lib/ui.k apps (one `t` namespace). |
| [usd](api/usd.md) | 22 | binary USDC (Pixar "crate") reader (pure k) |
| [zip](api/zip.md) | 4 | ZIP archive module (native Zig std.zip + std.compress.flate). |
