/// hhea — Horizontal Header.
/// doc/otf/table-hhea.md
///
/// Scalar dict. numberOfHMetrics drives the row count of hmtx.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const version = try r.version16dot16();
  const ascent = try r.int16();
  const descent = try r.int16();
  const lineGap = try r.int16();
  const advanceWidthMax = try r.uint16();
  const minLsb = try r.int16();
  const minRsb = try r.int16();
  const xMaxExtent = try r.int16();
  const caretSlopeRise = try r.int16();
  const caretSlopeRun = try r.int16();
  const caretOffset = try r.int16();
  r.skip(8); // 4× reserved int16
  const metricDataFormat = try r.int16();
  const numberOfHMetrics = try r.uint16();

  const keys = [_][*:0]const u8{
    "version",        "ascent",         "descent",     "lineGap",
    "advanceWidthMax", "minLsb",        "minRsb",      "xMaxExtent",
    "caretSlopeRise", "caretSlopeRun",  "caretOffset", "metricDataFormat",
    "numberOfHMetrics",
  };
  const vals = [_]?k.K{
    k.kf(version),         k.ki(ascent),        k.ki(descent),    k.ki(lineGap),
    k.ki(advanceWidthMax), k.ki(minLsb),        k.ki(minRsb),     k.ki(xMaxExtent),
    k.ki(caretSlopeRise),  k.ki(caretSlopeRun), k.ki(caretOffset), k.ki(metricDataFormat),
    k.ki(numberOfHMetrics),
  };
  return k.dict(&keys, &vals);
}
