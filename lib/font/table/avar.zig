/// avar — Axis Variations Table.
/// doc/otf/table-avar.md
///
/// Normalized to a dict:
///   version : F (version16dot16)
///   maps    : L, one element per axis. Each element is a dict
///             {from: F vector, to: F vector} of the segment map's
///             fromCoordinate/toCoordinate F2Dot14 pairs.
/// The optional avar v2 item-variation-store is deferred — only the per-axis
/// segment maps are parsed.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);
  const version = try r.version16dot16();
  _ = try r.uint16(); // reserved
  const axisCount = try r.uint16();

  const maps = k.KL(axisCount) orelse return null;

  var ai: usize = 0;
  while (ai < axisCount) : (ai += 1) {
    const positionMapCount = try r.uint16();
    const from = k.KF(positionMapCount) orelse return null;
    const to = k.KF(positionMapCount) orelse return null;
    const fromp = k.fp(from) orelse return null;
    const top = k.fp(to) orelse return null;
    var mi: usize = 0;
    while (mi < positionMapCount) : (mi += 1) {
      fromp[mi] = try r.f2dot14();
      top[mi] = try r.f2dot14();
    }
    const m = k.dict(
      &[_][*:0]const u8{ "from", "to" },
      &[_]?k.K{ from, to },
    );
    k.listSet(maps, ai, m);
  }

  const keys = [_][*:0]const u8{ "version", "maps" };
  const vals = [_]?k.K{ k.kf(version), maps };
  return k.dict(&keys, &vals);
}
