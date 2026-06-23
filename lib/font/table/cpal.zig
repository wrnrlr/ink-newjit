/// CPAL — Color Palette Table.
/// doc/otf/table-CPAL.md
///
/// One or more palettes, each holding numPaletteEntries colors. Color records
/// are stored once in a shared array; each palette's first record is given by
/// colorRecordIndices (palettes may overlap or share records). The file stores
/// each color as BGRA bytes; we expose them as RGBA floats in 0..1.
///
/// Normalized to a dict:
///   numPaletteEntries (I), numPalettes (I)
///   palettes : an L, one F vector per palette of length numPaletteEntries*4,
///              laid out R,G,B,A,R,G,B,A,… (each channel / 255).
/// CPAL v1 palette type/label name-IDs are deferred.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  _ = try r.uint16(); // version (0 or 1; v1 extras deferred)
  const numPaletteEntries = try r.uint16();
  const numPalettes = try r.uint16();
  _ = try r.uint16(); // numColorRecords (derivable; not exposed)
  const colorRecordsArrayOffset = try r.uint32();

  // Read each palette's first-record index.
  const palettes = k.KL(numPalettes) orelse return null;
  var pi: usize = 0;
  while (pi < numPalettes) : (pi += 1) {
    const firstIndex = try r.uint16();

    const entries = k.KF(@as(usize, numPaletteEntries) * 4) orelse return null;
    if (k.fp(entries)) |fpp| {
      var e: usize = 0;
      while (e < numPaletteEntries) : (e += 1) {
        const recIndex = @as(usize, firstIndex) + e;
        const recOff = @as(usize, colorRecordsArrayOffset) + recIndex * 4;
        var rr = reader.Reader.at(data, recOff);
        const blue = rr.uint8() catch 0;
        const green = rr.uint8() catch 0;
        const red = rr.uint8() catch 0;
        const alpha = rr.uint8() catch 0;
        const base = e * 4;
        fpp[base + 0] = @as(f32, @floatFromInt(red)) / 255.0;
        fpp[base + 1] = @as(f32, @floatFromInt(green)) / 255.0;
        fpp[base + 2] = @as(f32, @floatFromInt(blue)) / 255.0;
        fpp[base + 3] = @as(f32, @floatFromInt(alpha)) / 255.0;
      }
    }
    k.listSet(palettes, pi, entries);
  }

  const keys = [_][*:0]const u8{ "numPaletteEntries", "numPalettes", "palettes" };
  const vals = [_]?k.K{ k.ki(numPaletteEntries), k.ki(numPalettes), palettes };
  return k.dict(&keys, &vals);
}
