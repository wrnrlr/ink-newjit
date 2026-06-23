/// vmtx — Vertical Metrics.
/// doc/otf/table-vmtx.md
///
/// Vertical analogue of hmtx: per-glyph `adv` (advance height) and `tsb` (top
/// side bearing), length numGlyphs. Glyphs past numOfLongVerMetrics reuse the
/// final advance height. Returned as a dict of columns.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  const ng: usize = ctx.numGlyphs;
  const nv: usize = ctx.numberOfVMetrics;
  if (ng == 0) return null;

  const adv = k.KI(ng) orelse return null;
  const tsb = k.KI(ng) orelse {
    k.unref(adv);
    return null;
  };
  const ap = k.ip(adv) orelse return null;
  const tp = k.ip(tsb) orelse return null;

  var r = reader.Reader.init(data);
  var lastAdv: i32 = 0;
  var i: usize = 0;
  while (i < ng) : (i += 1) {
    if (i < nv) {
      lastAdv = try r.uint16();
      ap[i] = lastAdv;
      tp[i] = try r.int16();
    } else {
      ap[i] = lastAdv;
      tp[i] = r.int16() catch 0;
    }
  }

  const keys = [_][*:0]const u8{ "adv", "tsb" };
  const vals = [_]?k.K{ adv, tsb };
  return k.dict(&keys, &vals);
}
