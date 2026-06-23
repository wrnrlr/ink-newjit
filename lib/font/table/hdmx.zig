/// hdmx — Horizontal Device Metrics.
/// doc/otf/table-hdmx.md
///
/// One device record per ppem size, each holding a per-glyph rounded advance.
/// Returned as a dict: `ppem` (I, one per record), `maxWidth` (I, one per
/// record), and `widths` (L of I[numGlyphs], one vector per record).

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  const ng: usize = ctx.numGlyphs;
  var r = reader.Reader.init(data);

  _ = try r.uint16(); // version
  const numRecords: usize = @intCast(@max(0, try r.int16()));
  const recSize: usize = try r.uint32();

  const ppem = k.KI(numRecords) orelse return null;
  const maxWidth = k.KI(numRecords) orelse return null;
  const widths = k.KL(numRecords) orelse return null;
  const pp = k.ip(ppem) orelse return null;
  const mp = k.ip(maxWidth) orelse return null;

  var i: usize = 0;
  while (i < numRecords) : (i += 1) {
    var rr = reader.Reader.at(data, 8 + i * recSize);
    pp[i] = rr.uint8() catch 0;
    mp[i] = rr.uint8() catch 0;
    const w = k.KI(ng) orelse continue;
    if (k.ip(w)) |wp| {
      var g: usize = 0;
      while (g < ng) : (g += 1) wp[g] = rr.uint8() catch 0;
    }
    k.listSet(widths, i, w);
  }

  const keys = [_][*:0]const u8{ "ppem", "maxWidth", "widths" };
  const vals = [_]?k.K{ ppem, maxWidth, widths };
  return k.dict(&keys, &vals);
}
