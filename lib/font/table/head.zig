/// head — Font Header Table.
/// doc/otf/table-head.md
///
/// Normalized to a scalar dict. `created`/`modified` are seconds-since-1904
/// stored as floats (LONGDATETIME does not fit K's 32-bit int). The internal
/// checksumAdjustment / magicNumber / glyphDataFormat fields are dropped.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const version = try r.version16dot16();
  const revision = try r.fixed();
  _ = try r.uint32(); // checksumAdjustment
  _ = try r.uint32(); // magicNumber
  const flags = try r.uint16();
  const upm = try r.uint16();
  const created = try r.longdatetime();
  const modified = try r.longdatetime();
  const xMin = try r.int16();
  const yMin = try r.int16();
  const xMax = try r.int16();
  const yMax = try r.int16();
  const macStyle = try r.uint16();
  const lowestRec = try r.uint16();
  const dirHint = try r.int16();
  const locFormat = try r.int16();

  const keys = [_][*:0]const u8{
    "version",  "revision", "flags",   "upm",      "created",
    "modified", "xMin",     "yMin",    "xMax",     "yMax",
    "macStyle", "lowestRec", "dirHint", "locFormat",
  };
  const vals = [_]?k.K{
    k.kf(version),                  k.kf(revision),  k.ki(flags),   k.ki(upm),
    k.kf(@floatFromInt(created)),
    k.kf(@floatFromInt(modified)),  k.ki(xMin),      k.ki(yMin),    k.ki(xMax),
    k.ki(yMax),                     k.ki(macStyle),  k.ki(lowestRec), k.ki(dirHint),
    k.ki(locFormat),
  };
  return k.dict(&keys, &vals);
}
