/// VORG — Vertical Origin.
/// doc/otf/table-VORG.md
///
/// Default vertical origin Y plus a sparse per-glyph override list. Returned as
/// a dict: `defaultY` scalar, and parallel `gid`/`originY` columns for the
/// overrides.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  _ = try r.uint16(); // majorVersion
  _ = try r.uint16(); // minorVersion
  const defaultY = try r.int16();
  const count = try r.uint16();

  const gid = k.KI(count) orelse return null;
  const originY = k.KI(count) orelse {
    k.unref(gid);
    return null;
  };
  const gp = k.ip(gid) orelse return null;
  const yp = k.ip(originY) orelse return null;
  var i: usize = 0;
  while (i < count) : (i += 1) {
    gp[i] = try r.uint16();
    yp[i] = try r.int16();
  }

  const keys = [_][*:0]const u8{ "defaultY", "gid", "originY" };
  const vals = [_]?k.K{ k.ki(defaultY), gid, originY };
  return k.dict(&keys, &vals);
}
