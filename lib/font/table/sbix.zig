/// sbix — Standard Bitmap Graphics Table.
/// doc/otf/table-sbix.md
///
/// Color bitmap strikes in standard image formats (png/jpg/tiff/dupe).
/// Normalized to a dict { flags, strikes }. `strikes` is an L, one element per
/// strike, each a dict { ppem, ppi, glyphs }. `glyphs` is a columns dict over
/// the glyphs that actually carry data (empty glyph records are skipped):
///   gid originX originY graphicType data
/// graphicType is an L of 4-char tag strings; data is an L of raw image byte
/// strings (kept verbatim — PNG/JPEG/TIFF/dupe payloads are not decoded).

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const alloc = std.heap.c_allocator;

const Glyphs = struct {
  gid: std.ArrayList(i32) = .empty,
  originX: std.ArrayList(i32) = .empty,
  originY: std.ArrayList(i32) = .empty,
  graphicType: std.ArrayList([4]u8) = .empty,
  data: std.ArrayList([]const u8) = .empty,

  fn deinit(self: *Glyphs) void {
    self.gid.deinit(alloc);
    self.originX.deinit(alloc);
    self.originY.deinit(alloc);
    self.graphicType.deinit(alloc);
    self.data.deinit(alloc);
  }
};

/// Build the `glyphs` columns dict for one strike from the collected rows.
fn glyphsDict(g: *Glyphs) ?k.K {
  const gtype = k.KL(g.graphicType.items.len) orelse return null;
  for (g.graphicType.items, 0..) |t, i| k.listSet(gtype, i, k.str(&t));
  const blobs = k.KL(g.data.items.len) orelse return null;
  for (g.data.items, 0..) |d, i| k.listSet(blobs, i, k.str(d));

  const keys = [_][*:0]const u8{ "gid", "originX", "originY", "graphicType", "data" };
  const vals = [_]?k.K{
    k.ints(i32, g.gid.items),
    k.ints(i32, g.originX.items),
    k.ints(i32, g.originY.items),
    gtype,
    blobs,
  };
  return k.dict(&keys, &vals);
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  var r = reader.Reader.init(data);
  _ = try r.uint16(); // version (set to 1)
  const flags = try r.uint16();
  const numStrikes = try r.uint32();

  // One column per glyph offset entry; numGlyphs+1 offsets per strike.
  const offsetCount: usize = @as(usize, ctx.numGlyphs) + 1;

  const strikes = k.KL(numStrikes) orelse return null;

  var si: usize = 0;
  while (si < numStrikes) : (si += 1) {
    const strikeOffset = try r.uint32();
    if (strikeOffset >= data.len) {
      k.listSet(strikes, si, k.dict(
        &[_][*:0]const u8{ "ppem", "ppi", "glyphs" },
        &[_]?k.K{ k.ki(0), k.ki(0), k.KL(0) },
      ));
      continue;
    }
    const strike = data[strikeOffset..];

    var sr = reader.Reader.init(strike);
    const ppem = try sr.uint16();
    const ppi = try sr.uint16();

    var g = Glyphs{};
    defer g.deinit();

    var prev: u32 = sr.uint32() catch 0; // glyphDataOffsets[0]
    var gid: usize = 1;
    while (gid < offsetCount) : (gid += 1) {
      const cur = sr.uint32() catch break;
      defer prev = cur;
      // Glyph (gid-1) record spans [prev, cur) within the strike data.
      if (cur <= prev) continue; // no bitmap data for this glyph
      if (cur > strike.len or prev + 8 > cur) continue; // malformed / no room for header
      var gr = reader.Reader.at(strike, prev);
      const ox = gr.int16() catch continue;
      const oy = gr.int16() catch continue;
      const gtype = gr.tag() catch continue;
      const blob: []const u8 = strike[prev + 8 .. cur];
      g.gid.append(alloc, @intCast(gid - 1)) catch continue;
      g.originX.append(alloc, ox) catch continue;
      g.originY.append(alloc, oy) catch continue;
      g.graphicType.append(alloc, reader.tagBytes(gtype)) catch continue;
      g.data.append(alloc, blob) catch continue;
    }

    const keys = [_][*:0]const u8{ "ppem", "ppi", "glyphs" };
    const vals = [_]?k.K{ k.ki(ppem), k.ki(ppi), glyphsDict(&g) };
    k.listSet(strikes, si, k.dict(&keys, &vals));
  }

  const keys = [_][*:0]const u8{ "flags", "strikes" };
  const vals = [_]?k.K{ k.ki(flags), strikes };
  return k.dict(&keys, &vals);
}
