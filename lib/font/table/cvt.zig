/// cvt — Control Value Table.
/// doc/otf/table-cvt.md
///
/// A flat array of FWORD (int16) control values, used by the TrueType
/// hinting interpreter. Returned as an I vector.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  const n = data.len / 2;
  const v = k.KI(n) orelse return null;
  if (k.ip(v)) |p| {
    var r = reader.Reader.init(data);
    var i: usize = 0;
    while (i < n) : (i += 1) p[i] = try r.int16();
  }
  return v;
}
