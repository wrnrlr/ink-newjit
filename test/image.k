/ test/image.k — exercise the ink image modules.
/
/ Build first:  zig build images
/ Run:          ink test/image.k
/
/ Shows the whole surface: per-format read, structured layout (png.info /
/ jpeg.header), magic-byte dispatch (image.read), resampling (image.scale), and
/ round-trip encode (png.write / bmp.write). An image is a dict
/   `width`height`comp`data ! (w; h; channels; DATA)
/ with DATA a row-major, top-left-first, interleaved I vector (F for HDR).
/
/ Dict fields are pulled into plain variables before use — a `dict`key list
/ passed straight into a bracket call mis-parses (see AGENT.md gotchas).

BASE: "data/ambientcg/Grass005_1K-JPG/"

/ ── magic-byte dispatch: image.read picks the decoder, which auto-loads ─────────
png: image.read BASE,"Grass005.png"
jpg: image.read BASE,"Grass005_1K-JPG_Color.jpg"
pngdims: (png`width; png`height; png`comp)
jpgdims: (jpg`width; jpg`height; jpg`comp)
pngdims
jpgdims

/ ── structured layout, font-module style ───────────────────────────────────────
png.info    BASE,"Grass005.png"
jpeg.header BASE,"Grass005_1K-JPG_Color.jpg"

/ ── resample (bilinear) to a 128×128 thumbnail ─────────────────────────────────
thumb: image.scale[png; 128; 128]
tdims: (thumb`width; thumb`height; thumb`comp; #thumb`data)
tdims

/ ── round-trip: write the thumbnail out as PNG and BMP, read it back ────────────
wpng: png.write["/tmp/thumb.png"; thumb]
wbmp: bmp.write["/tmp/thumb.bmp"; thumb]
rp:   png.read "/tmp/thumb.png"
roundtrip: (thumb`data)~rp`data
(wpng; wbmp; roundtrip)

/ ── build a 16×16 red/blue checker from scratch (whole-array, no closures) ──────
mk: {[w;h]
  n: w*h
  xs: (!n) mod w                        / x coord per cell
  ys: _ (!n) % w                        / y coord per cell
  par: (xs + ys) mod 2                  / checker parity
  cell: {[q] $[q; 0 0 255; 255 0 0]}    / blue when odd, red when even
  `width`height`comp`data!(w; h; 3; ,/ cell'par)}
img: mk[16;16]
made: png.write["/tmp/checker.png"; img]
(made; #img`data)
