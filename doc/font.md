# Font module — status & remaining work

Native sfnt (TrueType/OpenType/TTC) parser. **No external dependency** — `tatfi`
was removed. Pure read of the font file into normalized k tables.

## Architecture

```
lib/font/
  reader.zig       big-endian byte cursor (bounds-checked)
  kbuild.zig       wraps the host k_* FFI → atoms / typed vectors / lists / dicts
  ctx.zig          per-face parse Ctx (numGlyphs, upm, loca, isCFF, metric counts)
  common.zig       shared sub-parsers: Coverage, ClassDef, DeltaSetIndexMap,
                   ItemVariationStore
  sfnt.zig         container (offset table / table directory / TTC) + a `tables`
                   registry that dispatches each tag → table/<name>.zig
  cff_outline.zig  Type 2 charstring interpreter → flattened pixel outline
  ext.zig          FFI boundary: exports ReadFont + cffOutline + terse_init
  table/*.zig      one parser per table (50 files)
lib/font.k         the k API (ReadFont, FontOutline, FontShape, helpers)
```

`ReadFont "path"` → **always a LIST of face dicts** (one element for TTF/OTF,
several for a TTC). Each face dict is keyed by normalized table name → that
table's normalized value. Keys are slash/space-free so they are usable k names
(`OS/2`→`OS2`, `cvt `→`cvt`, `CFF `→`CFF`, `SVG `→`SVG`). No handle, no global
registration.

## Tables — ALL 52 parse

The standard 48 + `name` + `OS/2`, all implemented and validated on real fonts
(FiraCode, InterVariable, Amiri, NotoSansCJK `.otf`/`.ttc`, Times New Roman,
Apple Color Emoji):

head maxp hhea hmtx loca glyf post name OS2 cmap cvt fpgm prep gasp vhea vmtx
VORG hdmx LTSH DSIG meta MERG PCLT fvar avar STAT CPAL COLR kern sbix SVG VDMX
GDEF GSUB GPOS BASE MATH JSTF HVAR VVAR MVAR gvar cvar CBLC CBDT EBLC EBDT EBSC
CFF CFF2.

## Outlines (done)

`FontOutline[f; gid; sz]` → L of flat F contours `[x,y,x,y,…]`, pixel-scaled,
y-flipped (font y-up → screen y-down), ready for `Tessellate`. Dispatches on
flavour:
- **glyf** (TrueType): flattened in k (`GlyphContours` resolves composites and
  subdivides quadratics). See `lib/font.k`.
- **CFF/CFF2** (PostScript): Type 2 charstring interpreted in Zig
  (`cff_outline.zig`), cubics subdivided. Handles subrs (global + per-FD local
  for CID via `fdSelect`/`fdLocalSubrs`), flex, hintmask. seac/endchar accent
  composition is not handled.

`FontShape[f; str]` (cmap, no shaping), `FontMetrics`, `FontGlyph`,
`FontOutlines` (whole string) round out the k API.

## Deferred — interpretation, NOT parsing (everything parses)

- **COLR v1** paint graph (only v0 base/layer model decoded).
- **CFF2 blend** operator not interpreted; CFF1 charset/Encoding SID→glyph-name
  not resolved (String INDEX exposed raw).
- **Bitmap image extraction**: CBLC/EBLC expose the IndexSubtable headers but do
  not expand index formats 1–5 into per-glyph offsets, so CBDT/EBDT expose only
  `version`+`size` (no per-glyph image bytes). sbix DOES expose per-glyph images.
- **gvar IUP** interpolation (raw `points`+`deltas` exposed for a consumer).
- **GPOS/GSUB contextual/chaining** subtable bodies (types 5–8 / 7,8): lookup
  type + flag + subtable format are exposed, the rule bodies are skipped.
- **GPOS** cursive/mark anchor detail (mark/base coverage exposed; anchors not).
- **BASE** MinMax / feature min-max; **MATH** per-glyph kern + variant parts.
- **endchar seac** accent composition in CFF outlines.

## Open problems

- **Runtime VM bug** (`doc/bug.md` #7): a projection capturing a heap array,
  mapped with `'`, is a use-after-free. `lib/font.k` is written to avoid it
  (scalar/dict captures, `_`-cut splitting, vectorized arithmetic) so the outline
  path is clean, but the VM bug itself is unfixed.
- **Perf** (`doc/bug.md` #8): eager materialization → ~47s for the 10-face CJK
  CFF ttc in Debug. Consider lazy `glyf`/`charStrings`.
- **`klp` stub** (`doc/bug.md` #9): worked around with `k_list_get`.

## Migration note (old API → new)

`ReadFont` used to return a single dict (or list for TTC); it now ALWAYS returns
a list. Downstream scripts must take a face: `FONT: (ReadFont "...") 0`.

The only two scripts that touch the font API — `test/typeset.k` and
`test/font.k` — are both updated to the new API; a grep confirms no other
script uses it, and no old-API markers (handle `f[\`h]`, `Fonts` registry,
`FontByName`, `GlyphPx`, the 65536-element `cmap` vector, `LoadUnicode`) remain
anywhere. If you write new code: the face dict is keyed by table name, and
`f\`cmap` is `{subtables; cp; gid}` (sparse) — use `FontGlyph[f;cp]` to look up
a glyph, not an index into a 65536 vector.
