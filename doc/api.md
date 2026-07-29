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
| [agent](api/agent.md) | 0 | A sketch of an agent loop: run a task until it reports done. |
| [asr](api/asr.md) | 16 | Speech recognition on top of lib/nn.k: conv subsampling, encoder, TDT greedy decode. |
| [audio](api/audio.md) | 39 | Play, stream, record and decode audio, with 3D positioning. |
| [bits](api/bits.md) | 12 | Runs a dye compute kernel on the CPU by interpreting its neutral IR. |
| [camera](api/camera.md) | 4 | An orbit camera: folds one frame of input into a camera-state dict. |
| [canvas](api/canvas.md) | 13 | A retained 2D drawing surface: record shapes into an ops table, then replay them. |
| [color](api/color.md) | 7 | Colour conversion and the full Tailwind palette as OKLCh constants. |
| [compress](api/compress.md) | 8 | DEFLATE, gzip and zlib compression, plus crc32/adler32 checksums. |
| [conformer](api/conformer.md) | 7 | Conformer blocks — convolution module, block and encoder stack. |
| [crypto](api/crypto.md) | 31 | Hashes, MACs, key derivation, authenticated encryption and signatures. |
| [csv](api/csv.md) | 1 | Reads a CSV file into a dict of typed column arrays. |
| [doc](api/doc.md) | 40 | Extracts an API reference from ink source, off the parse CST. |
| [dye](api/dye.md) | 167 | Compiles ink lambdas to SPIR-V shaders — the GPU language layer. |
| [fbx](api/fbx.md) | 28 | Reads binary FBX scene files, including their DEFLATE-compressed arrays. |
| [feat](api/feat.md) | 15 | Turns raw audio samples into log-mel spectrogram features. |
| [fft](api/fft.md) | 12 | Fast Fourier transform — Cooley-Tukey radix-2, decimation in time. |
| [fmt](api/fmt.md) | 5 | Formats numbers as fixed-width strings that do not jitter frame to frame. |
| [font](api/font.md) | 9 | Reads sfnt (TTF/OTF/TTC) fonts: outlines, shaping, metrics. |
| [fts](api/fts.md) | 0 | Full-text search: an inverted index over tokenised documents. |
| [geometry](api/geometry.md) | 17 | Generates the uniform polyhedra from Coxeter groups by Wythoff construction. |
| [gltf](api/gltf.md) | 15 | Reads glTF 2.0 and GLB scene files, with accessor and mesh helpers. |
| [gpu](api/gpu.md) | 40 | Opens a window, drives the frame loop, and owns every GPU resource. |
| [http](api/http.md) | 5 | An HTTP client for web and JSON APIs, with TLS, redirects and decompression. |
| [image](api/image.md) | 15 | Reads, writes and scales images, dispatching on the file's magic bytes. |
| [json](api/json.md) | 2 | Parses and generates JSON, columnarising object arrays into tables. |
| [kk](api/kk.md) | 29 | Compiles idiomatic whole-array k to GPU pipelines that run on resident buffers. |
| [layout](api/layout.md) | 0 | DEPRECATED — merged into lib/ui.k; use `ui.row` / `ui.col` / `ui.button` instead. |
| [lin](api/lin.md) | 7 | Solves linear systems by PLU decomposition. |
| [llm](api/llm.md) | 22 | Chat with Anthropic and xAI models, with live token streaming and tool use. |
| [math](api/math.md) | 6 | Small numeric helpers: combinatorics, sequences and bit-pattern generators. |
| [nn](api/nn.md) | 57 | Neural-net primitives that keep their weights and activations on the GPU. |
| [parquet](api/parquet.md) | 1 | Reads Parquet files into tables, across encodings, codecs and row groups. |
| [pbr](api/pbr.md) | 2 | A physically based (Cook-Torrance) shader pair for lit 3D meshes. |
| [pga](api/pga.md) | 16 | Projective geometric algebra G(3,0,1): points, lines, planes and motors. |
| [prelude](api/prelude.md) | 0 | The CPU builtins every VM gets at startup — math names and monadic verbs. |
| [recs](api/recs.md) | 11 | A relational ECS: an archetype is a table, an entity is a row. |
| [regex](api/regex.md) | 0 | A regex engine in pure k — Thompson NFA construction, Pike VM matching. |
| [rope](api/rope.md) | 21 | A SumTree rope: a B-tree over text chunks, indexed by summaries. |
| [safetensors](api/safetensors.md) | 1 | Reads safetensors weight files into a dict of named tensors. |
| [slug](api/slug.md) | 15 | Analytic vector coverage on the GPU: resolution-independent curves and text. |
| [spirv](api/spirv.md) | 98 | The SPIR-V instruction stencils dye patches to emit shader words. |
| [stats](api/stats.md) | 7 | Descriptive statistics: moments, correlation, regression and distributions. |
| [svd](api/svd.md) | 12 | Singular value decomposition by the Jacobi-Hestenes algorithm. |
| [syntax](api/syntax.md) | 12 | Syntax highlighting over the parse CST, with swappable themes and languages. |
| [ui](api/ui.md) | 40 | An immediate-mode UI toolkit where a widget is a row and a frame is three passes. |
| [uitest](api/uitest.md) | 36 | A deterministic, replayable harness that drives a real UI app headlessly. |
| [usd](api/usd.md) | 22 | Reads binary USDC (Pixar 'crate') scene files in pure k. |
| [zip](api/zip.md) | 4 | Reads and writes ZIP archives (store and deflate). |
