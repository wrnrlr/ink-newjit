/// VDMX — Vertical Device Metrics.
/// doc/otf/table-VDMX.md
///
/// Header (version, numRecs, numRatios) followed by numRatios RatioRange
/// records, numRatios Offset16 offsets to VDMXGroup tables, then the groups.
/// Normalized to:
///   version : I atom
///   ratios  : columns over the RatioRange records
///             (charset, xRatio, yStart, yEnd), one row per ratio
///   groups  : an L, one element per group (in ratio order); each element a
///             columns dict over its vTable records (ppem, yMax, yMin)
/// The vdmxGroupOffsets array is parallel to ratios and used only to seek
/// each group.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const version = try r.uint16();
  _ = try r.uint16(); // numRecs (total group count; not needed for shape)
  const numRatios = try r.uint16();

  // RatioRange records → parallel columns.
  const charset = k.KI(numRatios) orelse return null;
  const xRatio = k.KI(numRatios) orelse return null;
  const yStart = k.KI(numRatios) orelse return null;
  const yEnd = k.KI(numRatios) orelse return null;
  const csp = k.ip(charset) orelse return null;
  const xrp = k.ip(xRatio) orelse return null;
  const ysp = k.ip(yStart) orelse return null;
  const yep = k.ip(yEnd) orelse return null;
  var i: usize = 0;
  while (i < numRatios) : (i += 1) {
    csp[i] = try r.uint8();
    xrp[i] = try r.uint8();
    ysp[i] = try r.uint8();
    yep[i] = try r.uint8();
  }

  // vdmxGroupOffsets[numRatios] — offsets from table start to each group.
  const groups = k.KL(numRatios) orelse return null;
  i = 0;
  while (i < numRatios) : (i += 1) {
    const off = try r.uint16();
    k.listSet(groups, i, try group(data, off));
  }

  const ratios = k.dict(
    &[_][*:0]const u8{ "charset", "xRatio", "yStart", "yEnd" },
    &[_]?k.K{ charset, xRatio, yStart, yEnd },
  );

  const keys = [_][*:0]const u8{ "version", "ratios", "groups" };
  const vals = [_]?k.K{ k.ki(version), ratios, groups };
  return k.dict(&keys, &vals);
}

/// Parse one VDMXGroup at `off` (from table start) into a columns dict over its
/// vTable records: ppem (yPelHeight), yMax, yMin.
fn group(data: []const u8, off: u16) reader.Error!?k.K {
  var r = reader.Reader.at(data, off);
  const recs = try r.uint16();
  _ = try r.uint8(); // startsz (derivable from records; dropped)
  _ = try r.uint8(); // endsz   (derivable from records; dropped)

  const ppem = k.KI(recs) orelse return null;
  const yMax = k.KI(recs) orelse return null;
  const yMin = k.KI(recs) orelse return null;
  const pp = k.ip(ppem) orelse return null;
  const xp = k.ip(yMax) orelse return null;
  const np = k.ip(yMin) orelse return null;
  var i: usize = 0;
  while (i < recs) : (i += 1) {
    pp[i] = try r.uint16();
    xp[i] = try r.int16();
    np[i] = try r.int16();
  }

  return k.dict(
    &[_][*:0]const u8{ "ppem", "yMax", "yMin" },
    &[_]?k.K{ ppem, yMax, yMin },
  );
}
