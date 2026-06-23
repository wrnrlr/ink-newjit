/// GSUB — Glyph Substitution Table.
/// doc/otf/table-GSUB.md (and the shared ScriptList/FeatureList/LookupList
/// structures from the OpenType Layout "Common Table Formats" chapter).
///
/// Normalized to a dict:
///   version  : F (major.minor)
///   scripts  : L, one per ScriptRecord — dict {tag (4-char string);
///              langSys : columns {tag (L of 4-char strings, "dflt" for the
///              defaultLangSys); required (I, requiredFeatureIndex, 0xFFFF→-1);
///              features (L of I vectors, featureIndices per langsys)}}
///   features : columns over the FeatureList {tag (L of 4-char strings);
///              lookups (L of I vectors, lookupListIndices per feature)}
///   lookups  : L, one per Lookup — dict {type (I lookupType); flag (I
///              lookupFlag); subtables : L of per-subtable dicts}
///
/// Per-subtable decode (after resolving Extension type 7 to its real type):
///   type 1 (single)   : {format(I); map : columns {from (I); to (I)}}
///   type 2 (multiple) : {format(I); from (I); seqs (L of I vectors)}
///   type 3 (alternate): {format(I); from (I); alts (L of I vectors)}
///   type 4 (ligature) : {format(I); ligatures : L over covered first-glyphs,
///                        each an L of dicts {components (I); glyph (I)}}
///   types 5,6,8       : {format(I)} only — contextual/chaining/reverse-chaining
///                        bodies are deferred.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;
const common = @import("../common.zig");

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

// ── ScriptList ────────────────────────────────────────────────────────────────

fn langSys(data: []const u8, off: usize, tagBuf: []const u8) struct { tag: ?k.K, required: i32, features: ?k.K } {
  var r = Reader.at(data, off);
  _ = r.uint16() catch 0; // lookupOrderOffset (reserved)
  const requiredRaw = r.uint16() catch 0xFFFF;
  const featureCount = r.uint16() catch 0;
  const features = k.KI(featureCount) orelse return .{ .tag = k.str(tagBuf), .required = -1, .features = null };
  if (k.ip(features)) |p| {
    var i: usize = 0;
    while (i < featureCount) : (i += 1) p[i] = r.uint16() catch 0;
  }
  const required: i32 = if (requiredRaw == 0xFFFF) -1 else @intCast(requiredRaw);
  return .{ .tag = k.str(tagBuf), .required = required, .features = features };
}

fn scriptTable(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const defaultOff = r.uint16() catch 0;
  const langSysCount = r.uint16() catch 0;

  const total: usize = @as(usize, langSysCount) + @intFromBool(defaultOff != 0);

  const tags = k.KL(total) orelse return null;
  const required = k.KI(total) orelse return null;
  const featureLists = k.KL(total) orelse return null;
  const rp = k.ip(required) orelse return null;

  var row: usize = 0;
  if (defaultOff != 0) {
    const ls = langSys(data, off + defaultOff, "dflt");
    k.listSet(tags, row, ls.tag);
    rp[row] = ls.required;
    k.listSet(featureLists, row, ls.features);
    row += 1;
  }

  var i: usize = 0;
  while (i < langSysCount) : (i += 1) {
    const tagBytes = reader.tagBytes(r.uint32() catch 0);
    const lsOff = r.uint16() catch 0;
    const ls = langSys(data, off + lsOff, &tagBytes);
    k.listSet(tags, row, ls.tag);
    rp[row] = ls.required;
    k.listSet(featureLists, row, ls.features);
    row += 1;
  }

  const lkeys = [_][*:0]const u8{ "tag", "required", "features" };
  const lvals = [_]?k.K{ tags, required, featureLists };
  return k.dict(&lkeys, &lvals);
}

fn scriptList(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const count = r.uint16() catch 0;
  const list = k.KL(count) orelse return null;
  var i: usize = 0;
  while (i < count) : (i += 1) {
    const tagBytes = reader.tagBytes(r.uint32() catch 0);
    const scriptOff = r.uint16() catch 0;
    const keys = [_][*:0]const u8{ "tag", "langSys" };
    const vals = [_]?k.K{ k.str(&tagBytes), scriptTable(data, off + scriptOff) };
    k.listSet(list, i, k.dict(&keys, &vals));
  }
  return list;
}

// ── FeatureList ───────────────────────────────────────────────────────────────

fn featureLookups(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  _ = r.uint16() catch 0; // featureParamsOffset
  const count = r.uint16() catch 0;
  const v = k.KI(count) orelse return null;
  if (k.ip(v)) |p| {
    var i: usize = 0;
    while (i < count) : (i += 1) p[i] = r.uint16() catch 0;
  }
  return v;
}

fn featureList(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const count = r.uint16() catch 0;
  const tags = k.KL(count) orelse return null;
  const lookups = k.KL(count) orelse return null;
  var i: usize = 0;
  while (i < count) : (i += 1) {
    const tagBytes = reader.tagBytes(r.uint32() catch 0);
    const featureOff = r.uint16() catch 0;
    k.listSet(tags, i, k.str(&tagBytes));
    k.listSet(lookups, i, featureLookups(data, off + featureOff));
  }
  const keys = [_][*:0]const u8{ "tag", "lookups" };
  const vals = [_]?k.K{ tags, lookups };
  return k.dict(&keys, &vals);
}

// ── Lookup subtables ─────────────────────────────────────────────────────────

// Read a uint16 directly from a subtable slice (relative to its own start).
fn rdU16(data: []const u8, pos: usize) u16 {
  if (pos + 2 > data.len) return 0;
  return std.mem.readInt(u16, data[pos..][0..2], .big);
}

// type 1 — single substitution. Offsets relative to the subtable start `off`.
fn singleSubst(data: []const u8, off: usize, format: u16) ?k.K {
  var r = Reader.at(data, off);
  _ = r.uint16() catch 0; // format
  const covOff = r.uint16() catch 0;
  const from = common.coverage(data, off + covOff) orelse return null;
  const n: usize = @intCast(@max(0, k.reg.?.kn(from)));

  const to = k.KI(n) orelse return null;
  if (k.ip(to)) |tp| {
    if (format == 1) {
      const delta = r.int16() catch 0;
      if (k.ip(from)) |fpp| {
        var i: usize = 0;
        while (i < n) : (i += 1) tp[i] = (fpp[i] + @as(i32, delta)) & 0xFFFF;
      }
    } else {
      _ = r.uint16() catch 0; // glyphCount
      var i: usize = 0;
      while (i < n) : (i += 1) tp[i] = r.uint16() catch 0;
    }
  }

  const mkeys = [_][*:0]const u8{ "from", "to" };
  const mvals = [_]?k.K{ from, to };
  const map = k.dict(&mkeys, &mvals);

  const keys = [_][*:0]const u8{ "format", "map" };
  const vals = [_]?k.K{ k.ki(@intCast(format)), map };
  return k.dict(&keys, &vals);
}

// types 2 (multiple) and 3 (alternate) share a layout: coverage + an array of
// offsets to glyph-id sequences. Keyed `seqs` (type 2) or `alts` (type 3).
fn seqSubst(data: []const u8, off: usize, format: u16, seqKey: [*:0]const u8) ?k.K {
  var r = Reader.at(data, off);
  _ = r.uint16() catch 0; // format
  const covOff = r.uint16() catch 0;
  const count = r.uint16() catch 0;

  const from = common.coverage(data, off + covOff) orelse return null;
  const seqs = k.KL(count) orelse return null;
  var i: usize = 0;
  while (i < count) : (i += 1) {
    const subOff = r.uint16() catch 0;
    const glyphCount = rdU16(data, off + subOff);
    const ids = k.KI(glyphCount) orelse continue;
    if (k.ip(ids)) |p| {
      var j: usize = 0;
      while (j < glyphCount) : (j += 1) p[j] = rdU16(data, off + subOff + 2 + 2 * j);
    }
    k.listSet(seqs, i, ids);
  }

  const keys = [_][*:0]const u8{ "format", "from", seqKey };
  const vals = [_]?k.K{ k.ki(@intCast(format)), from, seqs };
  return k.dict(&keys, &vals);
}

// type 4 — ligature substitution.
fn ligatureSubst(data: []const u8, off: usize, format: u16) ?k.K {
  var r = Reader.at(data, off);
  _ = r.uint16() catch 0; // format
  const covOff = r.uint16() catch 0;
  const setCount = r.uint16() catch 0;

  const from = common.coverage(data, off + covOff) orelse return null;
  const ligatures = k.KL(setCount) orelse return null;

  var i: usize = 0;
  while (i < setCount) : (i += 1) {
    const setOff = r.uint16() catch 0;
    const setBase = off + setOff;
    const ligCount = rdU16(data, setBase);
    const set = k.KL(ligCount) orelse continue;
    var j: usize = 0;
    while (j < ligCount) : (j += 1) {
      const ligOff = rdU16(data, setBase + 2 + 2 * j);
      const ligBase = setBase + ligOff;
      const glyph = rdU16(data, ligBase);
      const componentCount = rdU16(data, ligBase + 2);
      const trailing: usize = if (componentCount > 0) componentCount - 1 else 0;
      const components = k.KI(trailing) orelse continue;
      if (k.ip(components)) |p| {
        var c: usize = 0;
        while (c < trailing) : (c += 1) p[c] = rdU16(data, ligBase + 4 + 2 * c);
      }
      const lkeys = [_][*:0]const u8{ "components", "glyph" };
      const lvals = [_]?k.K{ components, k.ki(@intCast(glyph)) };
      k.listSet(set, j, k.dict(&lkeys, &lvals));
    }
    k.listSet(ligatures, i, set);
  }

  const keys = [_][*:0]const u8{ "format", "from", "ligatures" };
  const vals = [_]?k.K{ k.ki(@intCast(format)), from, ligatures };
  return k.dict(&keys, &vals);
}

// Decode one resolved subtable of `lookupType` at `off` (relative to data[0]).
// Contextual/chaining/reverse-chaining bodies are deferred — only format kept.
fn subtable(data: []const u8, off: usize, lookupType: u16) ?k.K {
  const format = rdU16(data, off);
  return switch (lookupType) {
    1 => singleSubst(data, off, format),
    2 => seqSubst(data, off, format, "seqs"),
    3 => seqSubst(data, off, format, "alts"),
    4 => ligatureSubst(data, off, format),
    else => blk: { // 5, 6, 8 — body deferred
      const keys = [_][*:0]const u8{"format"};
      const vals = [_]?k.K{k.ki(@intCast(format))};
      break :blk k.dict(&keys, &vals);
    },
  };
}

// A subtable offset and the type to decode it as (resolving Extension type 7).
const Resolved = struct { off: usize, type: u16 };

fn resolveExtension(data: []const u8, off: usize) Resolved {
  // SubstExtensionFormat1: format(16), extensionLookupType(16), extensionOffset(32)
  var r = Reader.at(data, off);
  _ = r.uint16() catch 0; // format (1)
  const realType = r.uint16() catch 0;
  const extOff = r.uint32() catch 0;
  return .{ .off = off + extOff, .type = realType };
}

// ── LookupList ────────────────────────────────────────────────────────────────

fn lookupTable(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const lookupType = r.uint16() catch 0;
  const lookupFlag = r.uint16() catch 0;
  const subTableCount = r.uint16() catch 0;

  const subtables = k.KL(subTableCount) orelse return null;
  var i: usize = 0;
  while (i < subTableCount) : (i += 1) {
    const subOff = r.uint16() catch 0;
    var res = Resolved{ .off = off + subOff, .type = lookupType };
    if (lookupType == 7) res = resolveExtension(data, off + subOff);
    k.listSet(subtables, i, subtable(data, res.off, res.type));
  }
  // useMarkFilteringSet (flag 0x0010) adds a trailing markFilteringSet u16
  // after the subtable offset array. Subtable offsets are read absolutely from
  // `off`, so this field doesn't shift them; consumed here for completeness.
  if (lookupFlag & 0x0010 != 0) _ = r.uint16() catch 0; // markFilteringSet

  const keys = [_][*:0]const u8{ "type", "flag", "subtables" };
  const vals = [_]?k.K{ k.ki(@intCast(lookupType)), k.ki(@intCast(lookupFlag)), subtables };
  return k.dict(&keys, &vals);
}

fn lookupList(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const count = r.uint16() catch 0;
  const list = k.KL(count) orelse return null;
  var i: usize = 0;
  while (i < count) : (i += 1) {
    const lookupOff = r.uint16() catch 0;
    k.listSet(list, i, lookupTable(data, off + lookupOff));
  }
  return list;
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = Reader.init(data);
  const major = try r.uint16();
  const minor = try r.uint16();
  const scriptListOffset = try r.uint16();
  const featureListOffset = try r.uint16();
  const lookupListOffset = try r.uint16();

  const version: f32 = @as(f32, @floatFromInt(major)) + @as(f32, @floatFromInt(minor)) / 10.0;

  const keys = [_][*:0]const u8{ "version", "scripts", "features", "lookups" };
  const vals = [_]?k.K{
    k.kf(version),
    if (scriptListOffset != 0) scriptList(data, scriptListOffset) else k.KL(0),
    if (featureListOffset != 0) featureList(data, featureListOffset) else k.KL(0),
    if (lookupListOffset != 0) lookupList(data, lookupListOffset) else k.KL(0),
  };
  return k.dict(&keys, &vals);
}
