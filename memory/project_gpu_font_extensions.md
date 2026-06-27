---
name: gpu-font-lib-extensions
description: New lib/gpu and lib/font extension modules for ink's low-level 2D rendering API
metadata:
  type: project
---

Graphics support is being rebuilt as third-party extensions in `lib/` rather than baked into the runtime.

**Why:** Old graphics API (src/graphics/, the `9:` verb) was high-level and tightly coupled. New design exposes the fill shader's data pipeline directly so K code can compute geometry (tessellation, bezier subdivision) itself.

**lib/gpu/** — GPU immediate-mode triangle renderer:
- `fill.wgsl` — WebGPU shader (type 0=solid/gradient, 1=image, 2=stencil, 3=textured, 4=blur)
- `render.zig` — Standalone `Renderer` (no Gx/paint.zig dependency); owns vertex list; `draw(verts, frag)` + `flush(pass, w, h)`
- `triangulate.zig` — Ear-clip polygon tessellator
- `gpu.zig` — C-ABI extension: `gpu_set_renderer(ptr, w, h)`, `gpu_tri(verts, n, frag)`, `gpu_tess(pts, n, out, cap)`, `gpu_tess_multi`

**lib/font/** — Font loading and glyph outline extraction:
- `font.zig`, `shape.zig`, `data.zig` — Copied from src/graphics/ (tatfi-based font system)
- `font_ext.zig` — C-ABI extension: `font_load(path)`, `font_metrics(h, size, out)`, `font_shape(h, text, ...)`, `font_glyph_outline(h, gid, size, ...)`

**Intended K API:**
```k
/ GPU
(gpu`tri)  (verts; frag)    / draw Nx4 f32 triangles
(gpu`tess) pts              / tessellate Nx2 f32 polygon → Mx4 f32

/ Font
h: (font`load) "/path/font.ttf"
(font`metrics) (h; 48.)     / → (ascent; descent; line_gap)
(font`shape)   (h; "text")  / → glyph id list
(font`outline) (h; gid; 48.)/ → list of Nx2 f32 contours
```

**K integration still needed:** `terse_init` currently is a no-op. Need to add a VM hook so extensions can register named verb namespaces (or add new built-in verb that dispatches to extension C-ABI functions).

**How to apply:** When working on graphics/rendering features, the new pipeline is lib/gpu → lib/font → K tessellation, not src/graphics/paint.zig.
