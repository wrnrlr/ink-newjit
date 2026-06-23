/// EBSC — Embedded Bitmap Scaling Table.
/// doc/otf/table-EBSC.md
///
/// Describes strikes synthesized by scaling another (substitute) strike's
/// bitmaps, rather than storing fresh sbits. Normalized to a dict
/// { version, strikes }. `version` is major.minor as F. `strikes` is a columns
/// dict over the BitmapScale records (flip with `+`):
///   ppemX ppemY substitutePpemX substitutePpemY
/// The two SbitLineMetrics blocks (hori/vert) in each record are skipped.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);
  const major = try r.uint16();
  const minor = try r.uint16();
  const numSizes = try r.uint32();
  const version = @as(f32, @floatFromInt(major)) + @as(f32, @floatFromInt(minor)) / 10.0;

  const ppemX = k.KI(numSizes) orelse return null;
  const ppemY = k.KI(numSizes) orelse return null;
  const subX = k.KI(numSizes) orelse return null;
  const subY = k.KI(numSizes) orelse return null;
  const xp = k.ip(ppemX) orelse return null;
  const yp = k.ip(ppemY) orelse return null;
  const sxp = k.ip(subX) orelse return null;
  const syp = k.ip(subY) orelse return null;

  var i: usize = 0;
  while (i < numSizes) : (i += 1) {
    // Each BitmapScale record: hori SbitLineMetrics (12B), vert (12B), then the
    // four ppem bytes.
    r.skip(24);
    xp[i] = try r.uint8();
    yp[i] = try r.uint8();
    sxp[i] = try r.uint8();
    syp[i] = try r.uint8();
  }

  const keys = [_][*:0]const u8{ "version", "ppemX", "ppemY", "substitutePpemX", "substitutePpemY" };
  const vals = [_]?k.K{ k.kf(version), ppemX, ppemY, subX, subY };
  return k.dict(&keys, &vals);
}
