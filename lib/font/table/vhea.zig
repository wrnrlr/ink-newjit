/// vhea — Vertical Header.
/// doc/otf/table-vhea.md
///
/// Vertical analogue of hhea. numOfLongVerMetrics drives vmtx's row count.

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
  const advanceHeightMax = try r.int16();
  const minTsb = try r.int16();
  const minBsb = try r.int16();
  const yMaxExtent = try r.int16();
  const caretSlopeRise = try r.int16();
  const caretSlopeRun = try r.int16();
  const caretOffset = try r.int16();
  r.skip(8); // 4× reserved
  const metricDataFormat = try r.int16();
  const numOfLongVerMetrics = try r.uint16();

  const keys = [_][*:0]const u8{
    "version",        "ascent",        "descent",     "lineGap",
    "advanceHeightMax", "minTsb",      "minBsb",      "yMaxExtent",
    "caretSlopeRise", "caretSlopeRun", "caretOffset", "metricDataFormat",
    "numOfLongVerMetrics",
  };
  const vals = [_]?k.K{
    k.kf(version),         k.ki(ascent),        k.ki(descent),    k.ki(lineGap),
    k.ki(advanceHeightMax), k.ki(minTsb),       k.ki(minBsb),     k.ki(yMaxExtent),
    k.ki(caretSlopeRise),  k.ki(caretSlopeRun), k.ki(caretOffset), k.ki(metricDataFormat),
    k.ki(numOfLongVerMetrics),
  };
  return k.dict(&keys, &vals);
}
