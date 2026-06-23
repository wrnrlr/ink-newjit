/// LTSH — Linear Threshold.
/// doc/otf/table-LTSH.md
///
/// Per-glyph ppem threshold at and above which the glyph scales linearly.
/// Returned as an I vector of length numGlyphs (yPels).

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);
  _ = try r.uint16(); // version
  const n = try r.uint16(); // numGlyphs (per this table)
  const v = k.KI(n) orelse return null;
  if (k.ip(v)) |p| {
    var i: usize = 0;
    while (i < n) : (i += 1) p[i] = try r.uint8();
  }
  return v;
}
