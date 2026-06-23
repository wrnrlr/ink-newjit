/// hmtx — Horizontal Metrics.
/// doc/otf/table-hmtx.md
///
/// Expanded to two per-glyph columns (length numGlyphs): `adv` and `lsb`.
/// Glyphs past numberOfHMetrics reuse the final advanceWidth and carry their
/// own left-side bearing. Returned as a dict of columns; `+f\`hmtx` flips it
/// to a table.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  const ng: usize = ctx.numGlyphs;
  const nh: usize = ctx.numberOfHMetrics;
  if (ng == 0) return null;

  const adv = k.KI(ng) orelse return null;
  const lsb = k.KI(ng) orelse {
    k.unref(adv);
    return null;
  };
  const ap = k.ip(adv) orelse return null;
  const lp = k.ip(lsb) orelse return null;

  var r = reader.Reader.init(data);
  var lastAdv: i32 = 0;
  var i: usize = 0;
  while (i < ng) : (i += 1) {
    if (i < nh) {
      lastAdv = try r.uint16();
      ap[i] = lastAdv;
      lp[i] = try r.int16();
    } else {
      ap[i] = lastAdv;
      lp[i] = r.int16() catch 0; // trailing LSB array may be short in odd fonts
    }
  }

  const keys = [_][*:0]const u8{ "adv", "lsb" };
  const vals = [_]?k.K{ adv, lsb };
  return k.dict(&keys, &vals);
}
