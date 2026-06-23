/// MATH — The Mathematical Typesetting Table.
/// doc/otf/table-MATH.md
///
/// Normalized to a dict:
///   version          : F (major.minor)
///   constants        : dict of MathConstants scalar values, by name. Each
///                      MathValueRecord contributes its FWORD value (the device
///                      offset is ignored); the leading percent fields and the
///                      min-height fields are plain int16/uint16.
///   italicCorrection : columns {gid; value} over MathItalicsCorrectionInfo
///                      (present only when that sub-table exists)
///   topAccent        : columns {gid; value} over MathTopAccentAttachment
///                      (present only when that sub-table exists)
///   variants         : dict {minConnectorOverlap; vert (gid list); horiz (gid
///                      list)} from MathVariants (present when it exists)
///
/// MathKernInfo (per-glyph corner kern tables) and the per-variant glyph
/// constructions / assemblies are deferred — only the coverage gids and the
/// connector-overlap minimum from MathVariants are exposed.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;
const common = @import("../common.zig");

const Reader = reader.Reader;

/// The 51 named scalar fields of the MathConstants table, in file order, paired
/// with how each is encoded:
///   .i16 — a plain int16 (the two percent fields).
///   .u16 — a plain uint16/UFWORD (the two min-height fields).
///   .val — a MathValueRecord: FWORD value + Offset16 device (device dropped).
/// radicalDegreeBottomRaisePercent (trailing int16) closes the list.
const Enc = enum { i16, u16, val };
const Field = struct { name: [*:0]const u8, enc: Enc };

const constantFields = [_]Field{
  .{ .name = "scriptPercentScaleDown", .enc = .i16 },
  .{ .name = "scriptScriptPercentScaleDown", .enc = .i16 },
  .{ .name = "delimitedSubFormulaMinHeight", .enc = .u16 },
  .{ .name = "displayOperatorMinHeight", .enc = .u16 },
  .{ .name = "mathLeading", .enc = .val },
  .{ .name = "axisHeight", .enc = .val },
  .{ .name = "accentBaseHeight", .enc = .val },
  .{ .name = "flattenedAccentBaseHeight", .enc = .val },
  .{ .name = "subscriptShiftDown", .enc = .val },
  .{ .name = "subscriptTopMax", .enc = .val },
  .{ .name = "subscriptBaselineDropMin", .enc = .val },
  .{ .name = "superscriptShiftUp", .enc = .val },
  .{ .name = "superscriptShiftUpCramped", .enc = .val },
  .{ .name = "superscriptBottomMin", .enc = .val },
  .{ .name = "superscriptBaselineDropMax", .enc = .val },
  .{ .name = "subSuperscriptGapMin", .enc = .val },
  .{ .name = "superscriptBottomMaxWithSubscript", .enc = .val },
  .{ .name = "spaceAfterScript", .enc = .val },
  .{ .name = "upperLimitGapMin", .enc = .val },
  .{ .name = "upperLimitBaselineRiseMin", .enc = .val },
  .{ .name = "lowerLimitGapMin", .enc = .val },
  .{ .name = "lowerLimitBaselineDropMin", .enc = .val },
  .{ .name = "stackTopShiftUp", .enc = .val },
  .{ .name = "stackTopDisplayStyleShiftUp", .enc = .val },
  .{ .name = "stackBottomShiftDown", .enc = .val },
  .{ .name = "stackBottomDisplayStyleShiftDown", .enc = .val },
  .{ .name = "stackGapMin", .enc = .val },
  .{ .name = "stackDisplayStyleGapMin", .enc = .val },
  .{ .name = "stretchStackTopShiftUp", .enc = .val },
  .{ .name = "stretchStackBottomShiftDown", .enc = .val },
  .{ .name = "stretchStackGapAboveMin", .enc = .val },
  .{ .name = "stretchStackGapBelowMin", .enc = .val },
  .{ .name = "fractionNumeratorShiftUp", .enc = .val },
  .{ .name = "fractionNumeratorDisplayStyleShiftUp", .enc = .val },
  .{ .name = "fractionDenominatorShiftDown", .enc = .val },
  .{ .name = "fractionDenominatorDisplayStyleShiftDown", .enc = .val },
  .{ .name = "fractionNumeratorGapMin", .enc = .val },
  .{ .name = "fractionNumDisplayStyleGapMin", .enc = .val },
  .{ .name = "fractionRuleThickness", .enc = .val },
  .{ .name = "fractionDenominatorGapMin", .enc = .val },
  .{ .name = "fractionDenomDisplayStyleGapMin", .enc = .val },
  .{ .name = "skewedFractionHorizontalGap", .enc = .val },
  .{ .name = "skewedFractionVerticalGap", .enc = .val },
  .{ .name = "overbarVerticalGap", .enc = .val },
  .{ .name = "overbarRuleThickness", .enc = .val },
  .{ .name = "overbarExtraAscender", .enc = .val },
  .{ .name = "underbarVerticalGap", .enc = .val },
  .{ .name = "underbarRuleThickness", .enc = .val },
  .{ .name = "underbarExtraDescender", .enc = .val },
  .{ .name = "radicalVerticalGap", .enc = .val },
  .{ .name = "radicalDisplayStyleVerticalGap", .enc = .val },
  .{ .name = "radicalRuleThickness", .enc = .val },
  .{ .name = "radicalExtraAscender", .enc = .val },
  .{ .name = "radicalKernBeforeDegree", .enc = .val },
  .{ .name = "radicalKernAfterDegree", .enc = .val },
  .{ .name = "radicalDegreeBottomRaisePercent", .enc = .i16 },
};

fn constants(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  var keys: [constantFields.len][*:0]const u8 = undefined;
  var vals: [constantFields.len]?k.K = undefined;
  inline for (constantFields, 0..) |f, i| {
    keys[i] = f.name;
    const v: i32 = switch (f.enc) {
      .i16 => r.int16() catch 0,
      .u16 => r.uint16() catch 0,
      .val => blk: {
        const value = r.int16() catch 0; // FWORD
        _ = r.uint16() catch 0; // deviceOffset (ignored)
        break :blk value;
      },
    };
    vals[i] = k.ki(v);
  }
  return k.dict(&keys, &vals);
}

/// MathItalicsCorrectionInfo / MathTopAccentAttachment share the same shape:
/// a coverage offset, a count, then `count` MathValueRecords. Returns columns
/// {gid; value}, gids from the coverage, values the FWORDs (device dropped).
fn coverageValues(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const coverageOffset = r.uint16() catch 0;
  const count = r.uint16() catch 0;

  const gids = if (coverageOffset != 0)
    (common.coverage(data, off + coverageOffset) orelse k.KI(0))
  else
    k.KI(0);

  const values = k.KI(count) orelse return null;
  if (k.ip(values)) |vp| {
    var i: usize = 0;
    while (i < count) : (i += 1) {
      vp[i] = r.int16() catch 0; // FWORD value
      _ = r.uint16() catch 0; // deviceOffset (ignored)
    }
  }

  const keys = [_][*:0]const u8{ "gid", "value" };
  const vals = [_]?k.K{ gids, values };
  return k.dict(&keys, &vals);
}

fn variants(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const minConnectorOverlap = r.uint16() catch 0;
  const vertCoverageOffset = r.uint16() catch 0;
  const horizCoverageOffset = r.uint16() catch 0;

  const vert = if (vertCoverageOffset != 0)
    (common.coverage(data, off + vertCoverageOffset) orelse k.KI(0))
  else
    k.KI(0);
  const horiz = if (horizCoverageOffset != 0)
    (common.coverage(data, off + horizCoverageOffset) orelse k.KI(0))
  else
    k.KI(0);

  const keys = [_][*:0]const u8{ "minConnectorOverlap", "vert", "horiz" };
  const vals = [_]?k.K{ k.ki(minConnectorOverlap), vert, horiz };
  return k.dict(&keys, &vals);
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = Reader.init(data);
  const major = try r.uint16();
  const minor = try r.uint16();
  const constantsOffset = try r.uint16();
  const glyphInfoOffset = try r.uint16();
  const variantsOffset = try r.uint16();

  const version = @as(f32, @floatFromInt(major)) + @as(f32, @floatFromInt(minor)) / 10.0;

  var keys: [5][*:0]const u8 = undefined;
  var vals: [5]?k.K = undefined;
  var n: usize = 0;
  keys[n] = "version";
  vals[n] = k.kf(version);
  n += 1;

  if (constantsOffset != 0) {
    keys[n] = "constants";
    vals[n] = constants(data, constantsOffset);
    n += 1;
  }

  if (glyphInfoOffset != 0) {
    var gr = Reader.at(data, glyphInfoOffset);
    const italicsOffset = gr.uint16() catch 0;
    const topAccentOffset = gr.uint16() catch 0;
    // extendedShapeCoverageOffset, mathKernInfoOffset follow — kern info deferred.
    if (italicsOffset != 0) {
      keys[n] = "italicCorrection";
      vals[n] = coverageValues(data, glyphInfoOffset + italicsOffset);
      n += 1;
    }
    if (topAccentOffset != 0) {
      keys[n] = "topAccent";
      vals[n] = coverageValues(data, glyphInfoOffset + topAccentOffset);
      n += 1;
    }
  }

  if (variantsOffset != 0) {
    keys[n] = "variants";
    vals[n] = variants(data, variantsOffset);
    n += 1;
  }

  return k.dict(keys[0..n], vals[0..n]);
}
