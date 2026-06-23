/// GPOS — Glyph Positioning Table.
/// doc/otf/table-GPOS.md
///
/// Decodes the shared OpenType layout header (ScriptList / FeatureList /
/// LookupList — identical to GSUB) plus the simple, high-value GPOS lookup
/// subtable types. The complex attachment / contextual subtables expose their
/// type and format but defer their bodies (noted per type below).
///
/// → dict:
///   version  : F (major.minor, e.g. 1.0)
///   scripts  : L, one element per ScriptRecord, each a dict
///                {tag (4-char string);
///                 langSys : columns {tag (L of 4-char strings, "dflt" for the
///                   default LangSys); required (I, 0xFFFF→-1); features (L of I
///                   feature-index vectors)}}
///   features : columns {tag (L of 4-char strings); lookups (L of I lookup-index
///                vectors)}
///   lookups  : L, one element per Lookup, each a dict
///                {type (I); flag (I); subtables (L of per-subtable dicts)}
///
/// Per-subtable shapes (after resolving the type-9 Extension indirection to the
/// real lookup type + offset):
///   type 1 (single adjustment): {format; gid (I covered); value (L of I vectors
///     — the present ValueRecord fields in spec order Xplacement, Yplacement,
///     Xadvance, Yadvance, …; Device-table offsets are read as plain int16 and
///     kept as their raw value)}.
///   type 2 (pair adjustment) — the kerning case:
///     fmt1 → columns {left (I); right (I); xAdv (I, valueRecord1's XAdvance)}.
///     fmt2 → {format; class1 (classDef); class2 (classDef); class1Count;
///             class2Count; xAdv (L of I rows — valueRecord1's XAdvance per
///             (class1,class2) cell)}.
///   type 3 (cursive): {format} (body deferred).
///   types 4,5,6 (mark-to-base / -ligature / -mark): {format; markCoverage (I);
///     baseCoverage (I)} (attachment anchors deferred).
///   types 7,8 (contextual / chaining): {format} (deferred).
///
/// Header offsets are from data[0]; every sub-structure's internal offsets are
/// relative to its own start.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;
const common = @import("../common.zig");

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

// ── ValueRecord helpers ───────────────────────────────────────────────────────

// One set bit in valueFormat = one int16 field in the ValueRecord. Bits in spec
// order: XPlacement, YPlacement, XAdvance, YAdvance, then four Device-table
// offsets (read as int16, value kept raw — its meaning is ignored).
fn valueRecordSize(valueFormat: u16) usize {
  return @popCount(valueFormat) * 2;
}

// Read a ValueRecord at the cursor into an I vector of the present fields, in
// spec bit order. Returns an empty I vector when no bits are set.
fn readValueRecord(r: *Reader, valueFormat: u16) ?k.K {
  const n = @popCount(valueFormat);
  const vec = k.KI(n) orelse return null;
  if (k.ip(vec)) |p| {
    var idx: usize = 0;
    var bit: u4 = 0;
    while (bit < 8) : (bit += 1) {
      const mask = @as(u16, 1) << bit;
      if (valueFormat & mask != 0) {
        p[idx] = r.int16() catch 0;
        idx += 1;
      }
    }
  }
  return vec;
}

// XAdvance (bit 0x04) within a ValueRecord, given the cursor sits at its start.
// Advances the cursor past the whole record. Returns 0 when X_ADVANCE is absent.
fn xAdvanceOf(r: *Reader, valueFormat: u16) i32 {
  var out: i32 = 0;
  var bit: u4 = 0;
  while (bit < 8) : (bit += 1) {
    const mask = @as(u16, 1) << bit;
    if (valueFormat & mask == 0) continue;
    const v = r.int16() catch 0;
    if (mask == 0x0004) out = v; // X_ADVANCE
  }
  return out;
}

// ── Lookup type 1: single adjustment ──────────────────────────────────────────

fn singlePos(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const format = r.uint16() catch return null;
  const coverageOffset = r.uint16() catch return null;
  const valueFormat = r.uint16() catch return null;

  const gid = common.coverage(data, off + coverageOffset) orelse return null;

  var values: ?k.K = null;
  if (format == 1) {
    // One ValueRecord applied to every covered glyph; we still expose it as a
    // single-element value list for shape consistency.
    const vr = readValueRecord(&r, valueFormat);
    const list = k.KL(1) orelse {
      k.unref(gid);
      if (vr) |x| k.unref(x);
      return null;
    };
    k.listSet(list, 0, vr);
    values = list;
  } else {
    // format 2: one ValueRecord per covered glyph, Coverage-index ordered.
    const valueCount = r.uint16() catch 0;
    const list = k.KL(valueCount) orelse {
      k.unref(gid);
      return null;
    };
    var i: usize = 0;
    while (i < valueCount) : (i += 1) k.listSet(list, i, readValueRecord(&r, valueFormat));
    values = list;
  }

  const keys = [_][*:0]const u8{ "format", "gid", "value" };
  const vals = [_]?k.K{ k.ki(format), gid, values };
  return k.dict(&keys, &vals);
}

// ── Lookup type 2: pair adjustment ────────────────────────────────────────────

// fmt1: walk each PairSet, emitting a (left, right, xAdv) row for every pair —
// xAdv is valueRecord1's X_ADVANCE, the common horizontal kerning value.
fn pairPosFormat1(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  _ = r.uint16() catch return null; // format
  const coverageOffset = r.uint16() catch return null;
  const valueFormat1 = r.uint16() catch return null;
  const valueFormat2 = r.uint16() catch return null;
  const pairSetCount = r.uint16() catch return null;

  // Coverage gives the first (left) glyph for each PairSet, in index order.
  const cov = common.coverage(data, off + coverageOffset) orelse return null;
  defer k.unref(cov);
  const covLen: usize = @intCast(k.reg.?.kn(cov));
  const covp = k.ip(cov);

  var lefts: std.ArrayList(i32) = .empty;
  var rights: std.ArrayList(i32) = .empty;
  var xadvs: std.ArrayList(i32) = .empty;
  defer lefts.deinit(alloc);
  defer rights.deinit(alloc);
  defer xadvs.deinit(alloc);

  var i: usize = 0;
  while (i < pairSetCount) : (i += 1) {
    const psOff = r.uint16() catch 0;
    if (psOff == 0 or i >= covLen) continue;
    const left: i32 = if (covp) |p| p[i] else 0;

    var pr = Reader.at(data, off + psOff);
    const pairValueCount = pr.uint16() catch 0;
    var j: usize = 0;
    while (j < pairValueCount) : (j += 1) {
      const second = pr.uint16() catch break;
      const xadv = xAdvanceOf(&pr, valueFormat1); // consumes valueRecord1
      pr.skip(valueRecordSize(valueFormat2)); // skip valueRecord2
      lefts.append(alloc, left) catch break;
      rights.append(alloc, @intCast(second)) catch break;
      xadvs.append(alloc, xadv) catch break;
    }
  }

  const keys = [_][*:0]const u8{ "format", "left", "right", "xAdv" };
  const vals = [_]?k.K{
    k.ki(1),
    k.ints(i32, lefts.items),
    k.ints(i32, rights.items),
    k.ints(i32, xadvs.items),
  };
  return k.dict(&keys, &vals);
}

// fmt2: expose both ClassDefs, the class counts, and a flattened xAdv matrix
// (one I row per class1, class2Count wide) built from valueRecord1's X_ADVANCE.
fn pairPosFormat2(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  _ = r.uint16() catch return null; // format
  _ = r.uint16() catch return null; // coverageOffset (unused — classDef1 governs)
  const valueFormat1 = r.uint16() catch return null;
  const valueFormat2 = r.uint16() catch return null;
  const classDef1Offset = r.uint16() catch return null;
  const classDef2Offset = r.uint16() catch return null;
  const class1Count = r.uint16() catch return null;
  const class2Count = r.uint16() catch return null;

  const vr2Size = valueRecordSize(valueFormat2);

  const matrix = k.KL(class1Count) orelse return null;
  var c1: usize = 0;
  while (c1 < class1Count) : (c1 += 1) {
    const row = k.KI(class2Count) orelse {
      k.listSet(matrix, c1, k.KI(0));
      continue;
    };
    const rp = k.ip(row);
    var c2: usize = 0;
    while (c2 < class2Count) : (c2 += 1) {
      const xadv = xAdvanceOf(&r, valueFormat1);
      r.skip(vr2Size); // skip valueRecord2
      if (rp) |p| p[c2] = xadv;
    }
    k.listSet(matrix, c1, row);
  }

  const class1 = common.classDef(data, off + classDef1Offset);
  const class2 = common.classDef(data, off + classDef2Offset);

  const keys = [_][*:0]const u8{ "format", "class1", "class2", "class1Count", "class2Count", "xAdv" };
  const vals = [_]?k.K{ k.ki(2), class1, class2, k.ki(class1Count), k.ki(class2Count), matrix };
  return k.dict(&keys, &vals);
}

fn pairPos(data: []const u8, off: usize) ?k.K {
  const format = blk: {
    var r = Reader.at(data, off);
    break :blk r.uint16() catch return null;
  };
  if (format == 1) return pairPosFormat1(data, off);
  if (format == 2) return pairPosFormat2(data, off);
  const keys = [_][*:0]const u8{"format"};
  const vals = [_]?k.K{k.ki(format)};
  return k.dict(&keys, &vals);
}

// ── Lookup type 3: cursive (deferred) ─────────────────────────────────────────

fn cursivePos(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const format = r.uint16() catch return null;
  const keys = [_][*:0]const u8{"format"};
  const vals = [_]?k.K{k.ki(format)};
  return k.dict(&keys, &vals);
}

// ── Lookup types 4/5/6: mark attachment (anchors deferred) ────────────────────
//
// All three formats begin: format(u16), mark(Coverage)Offset(u16),
// base/ligature/mark2(Coverage)Offset(u16). We expose format and the two
// coverage glyph lists; the MarkArray / anchor bodies are deferred.

fn markPos(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const format = r.uint16() catch return null;
  const markCoverageOffset = r.uint16() catch return null;
  const secondCoverageOffset = r.uint16() catch return null;

  const markCov = common.coverage(data, off + markCoverageOffset) orelse k.KI(0);
  const baseCov = common.coverage(data, off + secondCoverageOffset) orelse k.KI(0);

  const keys = [_][*:0]const u8{ "format", "markCoverage", "baseCoverage" };
  const vals = [_]?k.K{ k.ki(format), markCov, baseCov };
  return k.dict(&keys, &vals);
}

// ── Lookup types 7/8: contextual / chaining (deferred) ────────────────────────

fn contextPos(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const format = r.uint16() catch return null;
  const keys = [_][*:0]const u8{"format"};
  const vals = [_]?k.K{k.ki(format)};
  return k.dict(&keys, &vals);
}

// ── Subtable dispatch ─────────────────────────────────────────────────────────

fn subtable(data: []const u8, lookupType: u16, off: usize) ?k.K {
  return switch (lookupType) {
    1 => singlePos(data, off),
    2 => pairPos(data, off),
    3 => cursivePos(data, off),
    4, 5, 6 => markPos(data, off),
    7, 8 => contextPos(data, off),
    else => blk: {
      // Unknown / unhandled — still surface a format so the shape holds.
      var r = Reader.at(data, off);
      const format = r.uint16() catch 0;
      const keys = [_][*:0]const u8{"format"};
      const vals = [_]?k.K{k.ki(format)};
      break :blk k.dict(&keys, &vals);
    },
  };
}

// ── LookupList ────────────────────────────────────────────────────────────────

fn lookupList(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const lookupCount = r.uint16() catch return null;
  const list = k.KL(lookupCount) orelse return null;

  var i: usize = 0;
  while (i < lookupCount) : (i += 1) {
    const lkOff = r.uint16() catch 0;
    if (lkOff == 0) {
      k.listSet(list, i, k.KL(0));
      continue;
    }
    const lookupBase = off + lkOff;
    var lr = Reader.at(data, lookupBase);
    var lookupType = lr.uint16() catch 0;
    const lookupFlag = lr.uint16() catch 0;
    const subTableCount = lr.uint16() catch 0;

    // Read all subtable offsets up-front (relative to the Lookup start). Resolve
    // type-9 Extension indirection here so the reported type/subtables are real.
    const subs = k.KL(subTableCount) orelse {
      k.listSet(list, i, k.KL(0));
      continue;
    };
    var realType = lookupType;
    var s: usize = 0;
    while (s < subTableCount) : (s += 1) {
      const subOff = lr.uint16() catch 0;
      var stBase = lookupBase + subOff;
      if (lookupType == 9) {
        // PosExtensionFormat1: format(u16), extensionLookupType(u16),
        // extensionOffset(Offset32 from the extension subtable start).
        var er = Reader.at(data, stBase);
        _ = er.uint16() catch 0; // format (1)
        realType = er.uint16() catch 0;
        const extOff = er.uint32() catch 0;
        stBase = stBase + extOff;
      }
      k.listSet(subs, s, subtable(data, realType, stBase));
    }
    // When USE_MARK_FILTERING_SET (0x0010) is set, a markFilteringSet u16 follows
    // the subtableOffsets array. We don't expose it, but consume it so the cursor
    // is consistent with the Lookup table layout.
    if (lookupFlag & 0x0010 != 0) _ = lr.uint16() catch 0;
    if (lookupType == 9) lookupType = realType;

    const keys = [_][*:0]const u8{ "type", "flag", "subtables" };
    const vals = [_]?k.K{ k.ki(lookupType), k.ki(lookupFlag), subs };
    k.listSet(list, i, k.dict(&keys, &vals));
  }
  return list;
}

// ── FeatureList ───────────────────────────────────────────────────────────────
//
// → columns {tag (L of 4-char strings); lookups (L of I lookup-index vectors)}.

fn featureList(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const featureCount = r.uint16() catch return null;

  const tags = k.KL(featureCount) orelse return null;
  const lookups = k.KL(featureCount) orelse {
    k.unref(tags);
    return null;
  };

  var i: usize = 0;
  while (i < featureCount) : (i += 1) {
    const t = r.tag() catch 0;
    const featureOffset = r.uint16() catch 0;
    k.listSet(tags, i, k.str(&reader.tagBytes(t)));

    var fr = Reader.at(data, off + featureOffset);
    _ = fr.uint16() catch 0; // featureParamsOffset (unused)
    const lookupIndexCount = fr.uint16() catch 0;
    const vec = k.KI(lookupIndexCount) orelse {
      k.listSet(lookups, i, k.KI(0));
      continue;
    };
    if (k.ip(vec)) |p| {
      var j: usize = 0;
      while (j < lookupIndexCount) : (j += 1) p[j] = fr.uint16() catch 0;
    }
    k.listSet(lookups, i, vec);
  }

  const keys = [_][*:0]const u8{ "tag", "lookups" };
  const vals = [_]?k.K{ tags, lookups };
  return k.dict(&keys, &vals);
}

// ── ScriptList ────────────────────────────────────────────────────────────────

// One LangSys table → (required feature index, feature-index vector).
const LangSys = struct { required: i32, features: ?k.K };

fn readLangSys(data: []const u8, off: usize) LangSys {
  var r = Reader.at(data, off);
  _ = r.uint16() catch 0; // lookupOrderOffset (reserved, NULL)
  const requiredRaw = r.uint16() catch 0xFFFF;
  const featureIndexCount = r.uint16() catch 0;
  const vec = k.KI(featureIndexCount) orelse k.KI(0);
  if (k.ip(vec)) |p| {
    var i: usize = 0;
    while (i < featureIndexCount) : (i += 1) p[i] = r.uint16() catch 0;
  }
  const required: i32 = if (requiredRaw == 0xFFFF) -1 else @intCast(requiredRaw);
  return .{ .required = required, .features = vec };
}

// One Script table → dict {tag; langSys : columns {tag; required; features}}.
fn scriptTable(data: []const u8, off: usize, scriptTag: u32) ?k.K {
  var r = Reader.at(data, off);
  const defaultLangSysOffset = r.uint16() catch 0;
  const langSysCount = r.uint16() catch 0;

  const total: usize = @as(usize, langSysCount) + @intFromBool(defaultLangSysOffset != 0);

  const tags = k.KL(total) orelse return null;
  const required = k.KI(total) orelse {
    k.unref(tags);
    return null;
  };
  const features = k.KL(total) orelse {
    k.unref(tags);
    k.unref(required);
    return null;
  };
  const rp = k.ip(required);

  var row: usize = 0;
  if (defaultLangSysOffset != 0) {
    const ls = readLangSys(data, off + defaultLangSysOffset);
    k.listSet(tags, row, k.str("dflt"));
    if (rp) |p| p[row] = ls.required;
    k.listSet(features, row, ls.features);
    row += 1;
  }
  var i: usize = 0;
  while (i < langSysCount) : (i += 1) {
    const t = r.tag() catch 0;
    const lsOff = r.uint16() catch 0;
    const ls = readLangSys(data, off + lsOff);
    k.listSet(tags, row, k.str(&reader.tagBytes(t)));
    if (rp) |p| p[row] = ls.required;
    k.listSet(features, row, ls.features);
    row += 1;
  }

  const lkeys = [_][*:0]const u8{ "tag", "required", "features" };
  const lvals = [_]?k.K{ tags, required, features };
  const langSys = k.dict(&lkeys, &lvals);

  const keys = [_][*:0]const u8{ "tag", "langSys" };
  const vals = [_]?k.K{ k.str(&reader.tagBytes(scriptTag)), langSys };
  return k.dict(&keys, &vals);
}

fn scriptList(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const scriptCount = r.uint16() catch return null;
  const list = k.KL(scriptCount) orelse return null;
  var i: usize = 0;
  while (i < scriptCount) : (i += 1) {
    const t = r.tag() catch 0;
    const scriptOffset = r.uint16() catch 0;
    k.listSet(list, i, scriptTable(data, off + scriptOffset, t));
  }
  return list;
}

// ── GPOS header ───────────────────────────────────────────────────────────────

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const major = try r.uint16();
  const minor = try r.uint16();
  const scriptListOffset = try r.uint16();
  const featureListOffset = try r.uint16();
  const lookupListOffset = try r.uint16();
  // minor >= 1 also has a featureVariationsOffset (Offset32); not decoded.

  const version: f32 = @as(f32, @floatFromInt(major)) + (@as(f32, @floatFromInt(minor)) / 10.0);

  const scripts = if (scriptListOffset != 0) scriptList(data, scriptListOffset) else k.KL(0);
  const features = if (featureListOffset != 0) featureList(data, featureListOffset) else k.KL(0);
  const lookups = if (lookupListOffset != 0) lookupList(data, lookupListOffset) else k.KL(0);

  const keys = [_][*:0]const u8{ "version", "scripts", "features", "lookups" };
  const vals = [_]?k.K{ k.kf(version), scripts, features, lookups };
  return k.dict(&keys, &vals);
}
