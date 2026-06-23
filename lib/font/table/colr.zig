/// COLR — Color Table.
/// doc/otf/table-COLR.md
///
/// Defines multi-colored glyphs. Version 0 stacks layers bottom-up: a base
/// glyph maps to a contiguous slice of layer records, each pairing a glyph ID
/// with a CPAL palette index. Colors themselves live in the CPAL table.
///
/// Normalized (version 0 layer model only) to a dict:
///   version (I, the uint16 version)
///   base    : columns over baseGlyphRecords — gid (I), firstLayer (I), numLayers (I)
///   layers  : columns over layerRecords     — gid (I), palette (I)
/// The v0 baseGlyph/layer arrays exist in both v0 and v1 headers, so they are
/// parsed regardless of version. The COLR v1 paint graph (BaseGlyphList,
/// LayerList, ClipList, var-store) is DEFERRED.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const version = try r.uint16();
  const numBaseGlyphRecords = try r.uint16();
  const baseGlyphRecordsOffset = try r.uint32();
  const layerRecordsOffset = try r.uint32();
  const numLayerRecords = try r.uint16();

  // baseGlyphRecords: { glyphID (u16), firstLayerIndex (u16), numLayers (u16) }
  const baseGid = k.KI(numBaseGlyphRecords) orelse return null;
  const firstLayer = k.KI(numBaseGlyphRecords) orelse return null;
  const baseNum = k.KI(numBaseGlyphRecords) orelse return null;
  const bg = k.ip(baseGid) orelse return null;
  const fl = k.ip(firstLayer) orelse return null;
  const bn = k.ip(baseNum) orelse return null;
  var br = reader.Reader.at(data, baseGlyphRecordsOffset);
  var i: usize = 0;
  while (i < numBaseGlyphRecords) : (i += 1) {
    bg[i] = br.uint16() catch 0;
    fl[i] = br.uint16() catch 0;
    bn[i] = br.uint16() catch 0;
  }

  // layerRecords: { glyphID (u16), paletteIndex (u16) }
  const layerGid = k.KI(numLayerRecords) orelse return null;
  const layerPalette = k.KI(numLayerRecords) orelse return null;
  const lg = k.ip(layerGid) orelse return null;
  const lp = k.ip(layerPalette) orelse return null;
  var lr = reader.Reader.at(data, layerRecordsOffset);
  i = 0;
  while (i < numLayerRecords) : (i += 1) {
    lg[i] = lr.uint16() catch 0;
    lp[i] = lr.uint16() catch 0;
  }

  const base = k.dict(
    &[_][*:0]const u8{ "gid", "firstLayer", "numLayers" },
    &[_]?k.K{ baseGid, firstLayer, baseNum },
  );
  const layers = k.dict(
    &[_][*:0]const u8{ "gid", "palette" },
    &[_]?k.K{ layerGid, layerPalette },
  );

  const keys = [_][*:0]const u8{ "version", "base", "layers" };
  const vals = [_]?k.K{ k.ki(version), base, layers };
  return k.dict(&keys, &vals);
}
