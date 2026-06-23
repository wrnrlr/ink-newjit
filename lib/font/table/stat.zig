/// STAT — Style Attributes Table.
/// doc/otf/table-STAT.md
///
/// Describes the design-variation axes of a font family and the named values
/// along them. Normalized to a dict:
///   version              : F (major.minor pair, e.g. 1.2)
///   elidedFallbackNameID : I (0 when minorVersion < 1)
///   axes                 : columns dict over the DesignAxisRecord array
///                          (tag, nameID, ordering); flip with `+` for rows.
///   axisValues           : an L of per-record dicts, decoded by format. Each
///                          carries a `format` key plus that format's fields.
/// designAxisSize is honored when striding the axis records; axisValueOffsets
/// are resolved relative to the start of the axis-value-offsets array.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

/// Decode one axis value table (already seeked to its start) into a dict.
fn axisValue(r: *reader.Reader) reader.Error!?k.K {
  const format = try r.uint16();
  switch (format) {
    1 => {
      const axisIndex = try r.uint16();
      const flags = try r.uint16();
      const nameID = try r.uint16();
      const value = try r.fixed();
      const keys = [_][*:0]const u8{ "format", "axisIndex", "flags", "nameID", "value" };
      const vals = [_]?k.K{ k.ki(format), k.ki(axisIndex), k.ki(flags), k.ki(nameID), k.kf(value) };
      return k.dict(&keys, &vals);
    },
    2 => {
      const axisIndex = try r.uint16();
      const flags = try r.uint16();
      const nameID = try r.uint16();
      const nominal = try r.fixed();
      const min = try r.fixed();
      const max = try r.fixed();
      const keys = [_][*:0]const u8{ "format", "axisIndex", "flags", "nameID", "nominal", "min", "max" };
      const vals = [_]?k.K{ k.ki(format), k.ki(axisIndex), k.ki(flags), k.ki(nameID), k.kf(nominal), k.kf(min), k.kf(max) };
      return k.dict(&keys, &vals);
    },
    3 => {
      const axisIndex = try r.uint16();
      const flags = try r.uint16();
      const nameID = try r.uint16();
      const value = try r.fixed();
      const linkedValue = try r.fixed();
      const keys = [_][*:0]const u8{ "format", "axisIndex", "flags", "nameID", "value", "linkedValue" };
      const vals = [_]?k.K{ k.ki(format), k.ki(axisIndex), k.ki(flags), k.ki(nameID), k.kf(value), k.kf(linkedValue) };
      return k.dict(&keys, &vals);
    },
    4 => {
      const axisCount = try r.uint16();
      const flags = try r.uint16();
      const nameID = try r.uint16();
      const values = k.KL(axisCount) orelse return null;
      var i: usize = 0;
      while (i < axisCount) : (i += 1) {
        const axisIndex = try r.uint16();
        const value = try r.fixed();
        const ckeys = [_][*:0]const u8{ "axisIndex", "value" };
        const cvals = [_]?k.K{ k.ki(axisIndex), k.kf(value) };
        k.listSet(values, i, k.dict(&ckeys, &cvals));
      }
      const keys = [_][*:0]const u8{ "format", "flags", "nameID", "values" };
      const vals = [_]?k.K{ k.ki(format), k.ki(flags), k.ki(nameID), values };
      return k.dict(&keys, &vals);
    },
    else => return null,
  }
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const majorVersion = try r.uint16();
  const minorVersion = try r.uint16();
  const designAxisSize = try r.uint16();
  const designAxisCount = try r.uint16();
  const designAxesOffset = try r.uint32();
  const axisValueCount = try r.uint16();
  const offsetToAxisValueOffsets = try r.uint32();
  const elidedFallbackNameID: i32 = if (minorVersion >= 1) try r.uint16() else 0;

  // STAT uses a plain major.minor pair (not Version16Dot16).
  const version: f32 = @as(f32, @floatFromInt(majorVersion)) + @as(f32, @floatFromInt(minorVersion)) / 10.0;

  // ── Design axes: parallel columns ──────────────────────────────────────────
  const tag = k.KL(designAxisCount) orelse return null;
  const nameID = k.KI(designAxisCount) orelse return null;
  const ordering = k.KI(designAxisCount) orelse return null;
  const np = k.ip(nameID) orelse return null;
  const op = k.ip(ordering) orelse return null;
  var i: usize = 0;
  while (i < designAxisCount) : (i += 1) {
    var ar = reader.Reader.at(data, designAxesOffset + i * designAxisSize);
    const t = try ar.tag();
    np[i] = try ar.uint16();
    op[i] = try ar.uint16();
    k.listSet(tag, i, k.str(&reader.tagBytes(t)));
  }
  const axes = k.dict(
    &[_][*:0]const u8{ "tag", "nameID", "ordering" },
    &[_]?k.K{ tag, nameID, ordering },
  );

  // ── Axis values: list of per-format dicts ──────────────────────────────────
  const axisValues = k.KL(axisValueCount) orelse return null;
  i = 0;
  while (i < axisValueCount) : (i += 1) {
    var or2 = reader.Reader.at(data, offsetToAxisValueOffsets + i * 2);
    const off = try or2.uint16();
    var avr = reader.Reader.at(data, offsetToAxisValueOffsets + off);
    k.listSet(axisValues, i, try axisValue(&avr));
  }

  const keys = [_][*:0]const u8{ "version", "elidedFallbackNameID", "axes", "axisValues" };
  const vals = [_]?k.K{ k.kf(version), k.ki(elidedFallbackNameID), axes, axisValues };
  return k.dict(&keys, &vals);
}
