# Canvas + Slug: 2D vector graphics stack

Status doc / handoff. The 2D graphics stack: an immediate-mode **Canvas** API
recording into a retained ops table, rendered by two backends — the legacy
**tessellation + NanoVG** path and the new analytic **Slug** GPU renderer.
Goal in flight: unify everything onto Slug (one resolution-independent backend,
same API).

Related: `dye.md` (the ink→SPIR-V compiler), `kk.md`/`kk2.md` (compute), the
`ink-canvas-graphics-stack` auto-memory (running notes).

---

## 1. Big picture

```
  user code
    │  cnv.moveTo/lineTo/quadTo/cubicTo/close, fill/stroke/text, gradients, clip
    ▼
  lib/canvas.k  ── records a columnar OPS TABLE (curves = quadratics, per-draw 2×3 xform)
    │  cnv.render[w;h]  (accumulate every draw's curves+paint → flush once → draw)
    └── fills · gradients · clips · strokes · text ─► lib/slug.k ONE scene-buffer path
                                                       (analytic coverage × per-pixel paint)
```

**ONE BACKEND.** Everything routes through the single Slug scene buffer now. Each draw bins
its quadratic curves AND its 44-float NanoVG paint block (gradient/solid + baked clip) into
one resident buffer; the fragment reads the curves for analytic coverage and evaluates the
paint (rounded-rect gradient SDF + scissor) at its screen position, folding paint×coverage
into the alpha. Strokes become fill outlines (miter joins, `canvas.miterContour`). No
tessellation. See §3 (tasks 1–3, done) for how, and §4 for the gotchas.

- **Canvas** (`lib/canvas.k`) is the API + scene model. Every path reduces to
  **quadratic Béziers** (lines = degenerate quads, cubics split to two quads),
  stored columnar with a per-draw 2×3 affine. Because the ops table is already
  quadratics, fills map *directly* onto Slug — no new geometry.
- **Slug** (`lib/slug.k`) computes vector coverage **analytically per pixel**
  (horizontal-ray winding over the quadratics in a fragment shader), band-
  accelerated, antialiased, resolution-independent, no tessellation. Same family
  as Eric Lengyel's Slug (patent released) and Loop-Blinn / Dobbie GPU fonts.
- **Tessellation** is the older path: CPU ear-clip (`triangulate.zig`) → the
  NanoVG uber-shader (`lib/gpu/fill.frag` — scissor/paint matrices, gradient,
  image, blur). Handles gradients/clip/image/strokes but curves are polygonal.

---

## 2. What is DONE (this session)

### Canvas API — `lib/canvas.k`
- Immediate-mode path recorder into a **columnar ops table** (`cnv.scene[]`):
  `draws` table + flat `curves` (6 floats/quad seg, local space) + `conlen` CSR
  + `xf` (6/draw affine) + `paints` (44-float NanoVG uniform blocks).
- API: `new save restore translate scale rotate xform moveTo lineTo quadTo
  cubicTo close text fill stroke rgba linearGradient radialGradient boxGradient
  clip noClip render scene draws ndraws`.
- **Per-draw 2×3 transform** carried alongside local-space curves (so a GPU
  backend can transform on-device).
- Gradients/clip are thin wrappers over the existing NanoVG uber-shader's 44-float
  `FragUniforms` (paint/scissor matrices are *inverse* affines; clip is canvas
  state baked into each paint at register time via `applyClip`).
- `cnv.render[w;h]` is a **3-pass** renderer (solid fills→Slug, gradient/clipped
  fills+strokes→tessellation, text→Slug). `w,h` = framebuffer size.

### Slug renderer — `lib/slug.k`
- Analytic per-pixel coverage: for each quadratic, solve `B_y(t)=py` for both
  roots (branchless line fallback for `a≈0` via `isLine`), signed winding with
  turning-point cancellation, `x_cross` from the full quadratic `B_x` → smooth at
  any zoom; `clamp(|Σ signed|)` = nonzero-winding fill (holes work).
- **Band acceleration**: y split into `slugNB=16` bands; a curve stored in every
  band its *true* y-extent overlaps (`yext` includes the interior extremum);
  `slugMPB=24` curves/band; per pixel loops only its band → fixed small cost
  regardless of glyph complexity.
- **True quadratics** from `font.quads` (raw glyf control triples, ~25/glyph vs
  ~160 flattened).
- **Scene-buffer path** (Vello-style, the ONE fill+text backend): all a frame's fill
  curves — solid shapes AND glyph outlines — in ONE resident buffer (`gpu.write`
  once/frame), fragment reads its curves by offset. `sceneBegin/addFill/sceneFlush/
  fillDraw` + `VTXF`/`FRAGF` (a `fragmentBuf`). `bandData[cs;pad]`/`rectOf[cs;pad]`
  bin ANY quadratic contour list (glyph or path). Per-fill AA host-computed (~1.2 px).
- **Text on the scene buffer** (`lib/canvas.k` `addGlyph/drawGlyphS`): each glyph's raw
  `font.quads` outline is just another fill — `addFill` bins it, `drawGlyphS` draws its
  bbox quad. Empty glyphs (spaces) get a `-1` offset sentinel and are skipped. Renders
  unlimited repeats correctly (the old texture path could not). CFF/OTF still glyf-only.
- `slugNB/MPB/TW/AA` are BARE globals baked into the shaders.

### font — `lib/font.k`
- `font.quads[f;gid;sz]` → raw quadratic control triples per contour (pixel-space,
  y-flipped), TrueType/glyf only. A `rawC`/`compositeQ`/`emit2` path mirroring
  `flatC`/`compositeG` but emitting `(on;ctrl;on)` instead of subdividing.

### dye (shader compiler) — `lib/dye.k`
- **Fragment-shader bounded loops**: `rsum`/loop region nodes now lower correctly
  in the fragment path. The gap was the loop consts (`RCi0/RCi1/RCf0` from
  `kAllocLoop`) — only the compute prologue emitted them, so fragment loops
  referenced id 0 → MoltenVK "Cannot resolve expression type". Fix: reset them in
  `shader.fragment/fragmentTexN` and lazily `kAllocLoop` in `xLowerC` when a loop
  node is present (compute already has them → no-op).
- **`shader.fragmentBuf[ioTypes; nBuf; fn]`**: fragment reads `nBuf` StorageBuffer
  f32 runtime-arrays (the SAME set-0 buffers a `vertexPull` vertex pulls from).
  fn's LAST `nBuf` params are buffers, read `buf[i]` via the existing
  `bufidx`/`xLoBufIdx` lowering; `buildModW` gained a `BufVars`-gated buffer
  section (mirrors vertexPull's `bufTypes`/`decBuf`, uses `fbBufVar`/`FBpbufs`/
  `CPf32`). This is the enabler for the scene buffer.

### native (Vulkan) — `lib/gpu/`
- `vk.zig createTextureF` + `gpu_vk.zig gpuTextureF` (k: `gpu.textureF`): float
  data texture (`R32G32B32A32_SFLOAT`, **NEAREST** sampler → exact per-texel reads
  via `sample[]` at texel centres, so no `texelFetch` intrinsic was needed).
- `vk.zig` pull storage-buffer descriptors now `VK_SHADER_STAGE_VERTEX_BIT |
  FRAGMENT_BIT` (1 line) so the fragment can read them.

### demos / tasks
- `demo/canvas.k` (fills + gradients + clip + strokes + Slug text; DPI-aware),
  `demo/slug.k` (standalone analytic glyphs `eag8`).
- `.plan/tasks.md`: "`&`/`|` as min/max in shaders" task logged.

---

## 3. Remaining tasks (roadmap to one backend)

**ONE BACKEND REACHED.** Solid/gradient fills, clips, strokes, AND text all render through
the single Slug scene-buffer path (`FRAGF`); `cnv.render` is one accumulate→flush→draw pass;
canvas.k no longer calls `gpu.tessellate`/`gpu.fill`. Tasks 1–3 below are DONE:

1. **Gradients + clip in `FRAGF` — DONE.** Each fill's full 44-float NanoVG paint block
   (gradient/solid + baked clip) is packed into the scene buffer BEFORE its curves
   (`addFill[cs;pad;paint]`, layout `[paint slugPS][bands]`, `off`→paint). The vertex now
   carries the fragment's SCREEN pos (`fx,fy` varying) alongside uv; `FRAGF` evaluates
   `scissorMask` and the rounded-rect gradient SDF at (fx,fy) — the exact math from
   `lib/gpu/fill.frag` — and folds paint×scissor into the alpha. Solid = `ext.x<0.5` branch
   (→ innerCol). Stride-8 vertex `[clipXY u v fx fy off aa]`; nbuf=1.
2. **Strokes via Slug — DONE (option b, offset outline).** `canvas.miterContour` builds a
   stroke's fill outline in SCREEN space by offsetting each vertex ±half-width along its
   MITER bisector (limit ≈4×hw). OPEN paths → one ribbon contour (butt caps); CLOSED paths
   (cnv.close, last≈first) → TWO contours (outer + reversed inner = an annulus, so winding
   fills the ring and empties the hole). Then it's just a fill (identity transform, screen
   space). Gotchas that bit: (i) don't subdivide STRAIGHT segments when flattening — a
   horizontal edge's 16 collinear pieces × 2 sides overflow one band's `slugMPB` and drop
   (`segFlat` emits straight segs as a single edge); (ii) the annulus needs the two separate
   contours, not one concatenated ribbon (that was the missing-triangle-base bug).
3. **Retire tessellation — DONE (canvas side).** canvas.k's `fillDraw`/`strokeDraw`/
   `gpu.tessellate` paths are gone. `triangulate.zig` + `fill.frag`/`fill.vert` still exist
   (other callers of `gpu.fill`/`gpu.tessellate` may remain) — deleting the native files is a
   separate cleanup once nothing else uses them.

   **Enabler for 1+2: independent-aspect normalisation.** `bandData`/`rectOf`/`normC` now
   scale x and y INDEPENDENTLY (sx,sy) instead of aspect-preserving square. A wide/flat shape
   (a stroke, a thin bar) then fills the full uv-y range so its curves spread across ALL bands
   instead of cramming into a few (→ `slugMPB` truncation). The non-square quad undoes the
   stretch, so coverage stays exact; glyphs/fills verified unchanged.
4. **Image paint — DONE.** `cnv.image[img;x;y;w;h;rgba]` (img = `cnv.loadImg[path]` →
   `(handle;iw;ih)`) is a type-1 paint: paintMat maps screen→image space, extent=(iw,ih).
   The texture handle rides in the paint block (`frag[10].z`); the draw pass reads it and
   routes the fill to `slug.fillDrawImg`/`FRAGFI` (a `shader.fragmentBufTex` = fragment that
   reads BOTH the scene STORAGE buffers AND a texture — new dye helper). FRAGFI samples the
   image at `paintMat·fpos/extent` × innerCol × coverage × scissor, so image fills get the
   same analytic coverage + clip as everything else. Solid/gradient/text stay on FRAGF (no
   per-draw texture bind → no tex_upool pressure for text). Gotcha: the texture handle must be
   a FLOAT in the paint block (a bare int boxes it). Verified: image + clipped/tinted image.
5. **CFF cubic→quad — DONE.** `font.quads` now dispatches to `cff2.quads` for CFF/OTF fonts.
   The native charstring interpreter (`cff_outline.zig`) gained a `quads` mode: instead of
   flattening cubics to lines it emits raw quadratic control triples (each cubic split to 2
   quads via de Casteljau, lines → degenerate quads, closing quad per contour). Exported as
   `cffQuads`. Gotcha: the k `3.*a+d` split formula is `3*(a+d)` (right-to-left) — a literal
   Zig `3*a+d` is wrong and gives spiky "flame" glyphs. Verified: OTF text renders clean.
6. **`&`/`|` as min/max in the shader dialect — DONE.** `dispBin`/`binRty`/`xTransNorm`
   in `lib/dye.k` dispatch `&`/`|` by operand type: bool→`OpLogicalAnd`/`Or`,
   float/vector→`OpFMin`/`OpFMax`. slug.k's shader bodies now use `&`/`|` directly
   (dropped the `min[]`/`max[]` workaround); canvas + slug demos verified unchanged.
   Golden assertions in `test/spirv.k` §9.
6b. **Text clipping — DONE.** `canvas.k` `slugText` snapshots the live clip
   (`TXCLM`/`TXCLE`) per glyph and `txPaint` bakes it via `applyClipM`, so text inside a
   `cnv.clip` is cropped like any fill. Verified: glyphs cropped to a clip band.
7. **dFdx-based AA width.** Currently AA is host-computed per fill/glyph (~1.2px).
   A real `dFdx`/`fwidth` intrinsic in dye would make it exact under any transform
   without host math. Needs `OpDPdx`/`OpDPdy`/`OpFwidth` (opcodes 207/208/210) in
   the dialect + the `DerivativeControl`/no-cap fragment path.
8. **Async GPU submission — DONE (double-buffering).** First, the myth: `gpuBufferWrite`'s
   `sync()` is gated on `self.recording` (the COMPUTE path), which is FALSE during windowed
   rendering — so the per-frame scene write never stalled; it's a plain memcpy into the
   coherent mapped buffer. `createTextureF`'s `vkQueueWaitIdle` stalls only on texture creation
   (cached glyphs, images loaded once), not per frame. The REAL bug was a latent data race:
   FRAMES=2, one shared `SCENE` buffer, so frame N's memcpy could clobber frame N-1's in-flight
   GPU read. Fixed in slug.k (no engine change) by **double-buffering** `SCENE` AND the quad
   pool: keep `SCNF`=FRAMES copies and cycle by parity `SLFR`, which advances once per
   sceneBegin — in lockstep with the GPU frame — so the copy about to be written was last used
   2 frames ago, whose fence `beginFrame` already waited on. Correctness under pipelining, no
   stall. (Uses the deep indexed-assign `SCENEV[SLFR]:: …` VM feature.)
9. **Scene-buffer compaction — DONE.** The fixed layout padded every band to `slugMPB` curves
   with 5.0 filler → `slugNB*slugMPB*8 = 3072` floats/fill regardless, capping a frame at
   ~85 fills (a paragraph overflowed `SCCAP`). Now `bandDataC` writes a COMPACTED layout:
   `[paint][band index: slugNB×(poolOffset,count)][tightly-packed curve pool]`. The fragment
   reads its band's `(off,count)`, loops `slugMPB` but clamps the read index to `[0,count-1]`
   and masks padded slots (`valid = 1-step[count; j+0.5]`). ~10× smaller for glyphs (verified:
   a 250+-glyph paragraph renders). The FIXED `bandData` is kept for the texture path
   (`slug.glyph`→`upload`, demo/slug.k). Truncation still caps a band's LOOP at `slugMPB`.
10. **Shape-texture eviction / dynamic geometry.** The text glyph cache is
    grow-only (fine — glyphs are a fixed set). If a truly morphing path ever used
    the *texture* path it'd leak; the scene-buffer path already handles dynamic
    geometry (rebuilt each frame), so prefer it.

---

## 4. Lessons learned / gotchas (read before touching this code)

### Gradients / clip / strokes (this session)
- **Band truncation on FLAT shapes.** With aspect-preserving (square) normalisation, a
  wide/flat shape (a stroke bbox, a thin bar) compresses in uv-y so ALL its curves land in a
  couple of bands and overflow `slugMPB` → the higher-indexed curves silently drop. Fix:
  normalise x and y INDEPENDENTLY (`normC`/`rectOf`/`bandData` take sx,sy); the non-square
  quad undoes the stretch so coverage is still exact. This unblocked strokes.
- **Don't subdivide straight stroke segments.** `segPts` flattens every segment to 16 points;
  a horizontal edge's 16 collinear pieces × 2 outline sides = 32 curves in ONE band → dropped
  (the "missing triangle base"). `segFlat` emits a straight segment (control≈midpoint) as a
  single edge; only curves get 16 points.
- **A CLOSED stroke is an ANNULUS = TWO contours** (outer offset + REVERSED inner offset), so
  nonzero winding fills the ring and empties the hole. Concatenating L-forward+R-reversed into
  ONE ribbon polygon is correct only for OPEN strokes (butt caps); using it for a closed path
  gives a spiky, half-missing outline.
- **Paint packed in the scene buffer, screen pos as a varying.** The fragment needs the pixel's
  SCREEN (framebuffer) position for `paintMat`/`scissorMat` (both are inverse affines
  screen→paint-local). Pass it as an extra vertex varying (`fx,fy`); pack the 44-float paint
  block per-fill ahead of the curves (`off`→paint, bands at `off+slugPS`). Solid vs gradient =
  `ext.x<0.5` (gpu.solid sets ext=0). Fold `paint.a × coverage × scissorMask` into out alpha
  (straight SRC_ALPHA blend, so only alpha is the weight — don't premultiply rgb by scissor).

### ink language (cost real time)
- **`,` adjacency.** `f ,/(...)` parses the `,` as *dyadic join with f*, not raze
  feeding f — bracket it: `f[,/(...)]`. Same for `a+b,c+d` → `(a+b),(c+d)`. This
  is the #1 source of `!`-type surprises here.
- **Mixed int/float joins BOX to a list** (no promotion). `0. 0. w 0.` with int
  `w`, or `a,0.,0.,aa,off,col` with int `off` → a boxed list, not a flat vector →
  garbage GPU buffers → blank output. Cast: `0.+w`, `off:0.+#SCACC`.
- **Lambdas don't close over parent scope.** An inner `{… mx …}'list` can't see an
  enclosing local `mx`. Thread via each-multi (`f'[a; n#mx; …]`) or a module
  global, never a nested closure.
- **`f[;a;b]` open-slot projection fixes the FIRST arg**, not the empty slot — a
  documented trap. Use each-multi instead.
- **`[name:v; …]` inside a `$[...]` branch is a dict literal**, not a block. A
  diagnostic like `$[c; [`0 0:x; done::1]; 0]` is a *parse error* → the whole file
  produces no output. Use a named helper fn for multi-statement branches.
- **`xf2`-style helpers**: `{… (…) ; (…)}` with `;` is TWO statements returning the
  last (a scalar); use `,` to build a vector.
- Single-char string is a char ATOM (`"H"` ≠ `"HH"`) → `font.shape` returns a
  scalar; normalise with `1_0,font.shape[…]`.
- `dict\`key` before an operator misparses; `%` is float divide; `_x` is floor.

### Scene-buffer text bugs fixed this session (all THREE needed for correct text)
- **Pull pipeline depth was `LESS` (→ `LESS_OR_EQUAL`)** in `vk.zig`. Every 2D quad
  (VTXF/VTXC) emits `z=0.5`; tightly-packed glyphs' *square* coverage quads overlap
  heavily, so under `LESS` the second-and-later quad at an equal-depth pixel is rejected
  → whole repeated glyphs vanish ("ninini" → "i i i"; the first of each pair survives).
  `LESS_OR_EQUAL` lets coplanar 2D quads all pass (blend/paint order decides). Benign for
  3D pulls (earth.k unchanged). This ALSO explains the old texture path's drops.
- **Empty-glyph (space) guard used an inline `[a;b]` block in a `$[...]` branch** →
  parsed as a dict literal, ran neither statement, so spaces never appended their skip
  sentinel → `TXOFF`/`TXRECT` desynced from the glyph indices and words lost their gaps
  ("Canvas in ink" → "Canvasinink"). Fix: a NAMED helper (`addGlyphSkip`). (The #1 ink
  gotcha, verbatim from CLAUDE.md — bites in real code, not just diagnostics.)
- **`off` (scene-buffer offset) rounded in `FRAGF`** (`floor[off+0.5]`): it's one integer
  per quad but arrives as an interpolated varying (`off·(b0+b1+b2)`, sum ≠ 1.0 by ~1e-7),
  so a bare truncating buffer index can land one slot low and read the previous fill's
  curves. Defensive; keep it.
- **The depth test was the whole story (an nbuf=2+texture MoltenVK theory was a red
  herring).** `demo/slug.k` (spread-out, non-overlapping glyphs) and the 8-square fill
  test (spread) both worked *because* their quads don't overlap; tight text overlaps and
  dropped. An nbuf=1 rewrite of the text vertex shader did NOT fix it — confirming nbuf was
  irrelevant and depth was the cause. `8`→`3` (loses the left stem) is exactly the
  overlapping left region being depth-rejected. Moving text to the scene buffer is a
  roadmap unification, not the bug fix; the bug fix is `LESS_OR_EQUAL`.

### GPU extension
- **The built-in fill shader multiplies alpha by `clamp(ftcoord.y,0,1)`** (edge-AA
  fringe) → hand-built triangles need `v=1` or they draw fully transparent.
  `gpu.tessellate` sets it; direct-vert draws must too.
- **Draw calls / buffer+texture creation inside `'`/`/` adverbs are eliminated**
  (treated pure). A dynamic number of draws needs *recursion*; build buffers with
  explicit calls, not an each.
- **Deferred submission**: each draw reads its vertex buffer's FINAL contents, so
  N draws sharing one buffer all land on the last write → each needs its OWN
  buffer (a pool).
- **`gpu.fill` (fill pipeline) + `mesh.drawPull*` (pull pipeline) compose** in one
  render pass (fills first as base, pulls on top).
- Retina: `props`width/`height` are the **framebuffer** size (2× logical). Fills
  use framebuffer viewSize → **canvas coord == framebuffer pixel**, so a canvas
  drawn at logical coords fills only the top-left quarter on a 2× display. The
  *app* fixes it (`cnv.scale[props`width/WINW …]`), not the library.

### dye / shaders
- **`&`/`|` in the shader dialect are now POLYSEMIC** (as of 2026-07-21, matching host
  k): min/max on float/vector operands (`OpFMin`/`OpFMax`), logical and/or on bool
  operands. So `y0&y2` = `min[y0;y2]`; `(a>b)&(c>d)` = logical-and. `min[]`/`max[]` still
  work but are no longer required. (Older notes below saying "&/| are logical" are stale.)
- Vector loop-state needs component brackets (`t[0]`); params can't be named `in`;
  max 8 params.
- Loop consts (`RCi0/RCf0`) are compile-scoped globals — a stage that uses loops
  must ensure `kAllocLoop` ran (compute does it in the prologue; fragment now does
  it lazily in `xLowerC`).
- **Fragment buffer index k = set-0 binding k = the SAME binding the vertex sees.**
  For a fill: quad@binding0 (vertex pulls) + curves@binding1 (fragment reads), and
  BOTH shaders declare both buffers (unused declarations are fine; the descriptor
  layout comes from the vertex's buffer count).
- **NEAREST float textures** let `sample[]` at texel centres read exact data →
  no `texelFetch` intrinsic needed (saved a dye change).
- Buffer reads work inside a fragment `rsum` loop; f32 indices are exact to 2^24
  (>> any realistic buffer size).

---

## 5. Future improvements — VM & shader compiler

The graphics work surfaced several places where a modest engine change removes a
whole class of workaround.

### Shader compiler (dye)
- **Async is the real ceiling (via the gpu extension).** Both `createTextureF`
  (`vkQueueWaitIdle`) and `gpuBufferWrite` (`v.sync()`) are fully synchronous — the
  extension is correctness-first (see `vk.zig` header, `.plan/tasks.md` perf item).
  Every per-frame upload/write stalls the CPU on the whole queue. The scene buffer
  minimises this to one sync/frame, but truly stall-free dynamic rendering needs
  **fences + double/triple-buffering** (a staging ring, or ping-pong resident
  buffers). This is the single biggest perf win available and it's engine-level,
  not shader-level.
- **`dFdx`/`fwidth` in the dialect** (opcodes 207/208/210). Removes host-side AA
  width math and makes edge AA exact under arbitrary transforms. Small addition.
- **`&`/`|` → min/max dispatch by operand type — DONE** (float→`OpFMin/FMax`, bool→
  logical). Removed a sharp edge for shader authors; slug.k dropped its `min[]`/`max[]`
  workaround.
- **Storage buffers in the fragment — DONE this session** (`shader.fragmentBuf`).
  Worth generalising: a fragment that reads *both* textures and buffers, and
  configurable binding bases (right now fragment buffer index == binding index,
  which forces the "both shaders declare all buffers" dance).
- **Uniform blocks in the fragment.** Per-draw constants (gradient params, view
  size) currently ride as vertex attributes or baked globals. A real UBO read in
  the dye fragment path would be cleaner for the gradient/clip work (§3.1).
- **Loop unrolling / early-out.** The per-pixel band loop is a fixed `slugMPB`
  with padding. `whileL` (already in the compute dialect) with a per-band count
  would skip empty slots; needs the while-loop wired into the fragment path and a
  count read from the buffer.
- **Scene compaction primitives.** An indexed band layout (§3.9) wants a small
  gather (`buf[index[i]]`) in the fragment — a double-indirect read. The
  machinery (`bufidx`) exists; just needs an index buffer + one more `buf[...]`.

### VM / runtime
- Nothing in the VM blocked graphics work directly, but the recurring **int/float
  boxing** foot-guns (mixed-type joins silently box) cost real debugging time.
  A lint/warning on mixed-type vector literals, or auto-promote on join, would
  prevent a class of "blank GPU output" bugs. (Behaviour is intentional per the
  language design — flagging, not changing, is the ask.)
- The **`f[;a]` open-slot projection semantics** (fixes the first arg) surprised us
  repeatedly; worth documenting louder or reconsidering.

### Native (Vulkan) extension
- **Resident *writable* textures** (a `gpu.textureWriteF` that re-uploads into an
  existing image via a copy in the frame cb, not a fresh create+stall). Would let
  the *texture* path handle dynamic shapes without the scene-buffer indirection.
- **Expose `destroyTexture`** to k (currently textures leak if created per-frame;
  the caches/pools avoid it, but a free is the honest primitive).
- **Bindless / descriptor-indexing** (`gpu.caps` reports `descIndex`/`runtimeArray`
  green) would let ONE draw fill many shapes with per-instance texture/offset
  indices — collapsing the per-fill draw + per-fill quad buffer into an instanced
  draw. Big structural simplification for scenes with many fills.

---

## 6. File reference

| File | What |
|------|------|
| `lib/canvas.k` | Canvas API, ops table, 3-pass render, gradient/clip, text recording |
| `lib/slug.k` | Slug analytic renderer: coverage, bands, scene-buffer fill+text path (`bandData`/`rectOf`/`addFill`/`fillDraw`), standalone data-texture path (demo), shaders |
| `lib/font.k` | `font.quads` raw glyf quadratic accessor (+ existing `font.outline`) |
| `lib/dye.k` | fragment loops fix, `shader.fragmentBuf`, `buildModW` buffer section |
| `lib/gpu.k` | `gpu.textureF` binding |
| `lib/gpu/vk.zig` | `createTextureF`, pull storage-buffer stage flags |
| `lib/gpu/gpu_vk.zig` | `gpuTextureF` export |
| `lib/gpu/fill.frag`,`.vert` | legacy NanoVG uber-shader (tessellation path; to retire) |
| `lib/gpu/triangulate.zig` | CPU ear-clip (tessellation path; to retire) |
| `demo/canvas.k`, `demo/slug.k` | demos |

### Key constants (baked into Slug shaders — bare globals in `lib/slug.k`)
`slugNB=16` bands, `slugMPB=24` curves/band, `slugTW=48`=2·MPB (texture width),
`slugAA=0.004` (texture-path fallback AA; text/fills override per-draw). Raise
`slugMPB` if a dense glyph/shape truncates a band (measured max ~16 for `@`).

### Data layouts
- **Curve record** (8 floats): `[x0 y0 cx cy x2 y2 0 0]` — quadratic p0→control→p2
  in [0,1] shape space, padded to a texel/8-slot.
- **Banded data**: `slugNB` rows × `slugMPB` curves × 8 floats, row-major; band `b`
  curve `j` at `b*MPB*8 + j*8`. Unused slots = `5.0` (far away, never crossed).
- **Scene buffer**: concatenated banded data per fill; fill `k` at float offset
  `SFOFF[k]`; fragment reads `base = off + band*MPB*8`, then `o = base + j*8`.
