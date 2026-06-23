/// GDEF — Glyph Definition Table.
/// doc/otf/table-GDEF.md
///
/// Six independent subtables, all optional and offset-gated from the header:
///   glyphClass  — ClassDef (1=base,2=ligature,3=mark,4=component)
///   markAttach  — ClassDef for mark attachment classes
///   attachList  — covered glyphs + per-glyph attach-point indices
///   ligCaret    — covered ligature glyphs + per-glyph caret value lists
///   markGlyphSets (v1.2+) — L of coverage glyph lists
///   varStore    (v1.3+) — ItemVariationStore
/// Only keys whose source offset is non-zero/present are included. The header
/// version is normalized to major.minor (e.g. 1.3 → 1.3). All header offsets are
/// from data[0]; each sub-table's own internal offsets are from its own start.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;
const common = @import("../common.zig");

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

// ── AttachList ──────────────────────────────────────────────────────────────
//
// → dict {gid (I, covered glyphs); points (L of I vectors — attach-point indices
//   per covered glyph)}. coverageOffset and attachPointOffsets are from the
//   start of the AttachList sub-table.

fn attachList(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const coverageOffset = r.uint16() catch return null;
  const glyphCount = r.uint16() catch return null;

  const gid = common.coverage(data, off + coverageOffset) orelse return null;
  const points = k.KL(glyphCount) orelse {
    k.unref(gid);
    return null;
  };

  var i: usize = 0;
  while (i < glyphCount) : (i += 1) {
    const apOff = r.uint16() catch 0;
    if (apOff == 0) {
      k.listSet(points, i, k.KI(0));
      continue;
    }
    var ar = Reader.at(data, off + apOff);
    const pointCount = ar.uint16() catch 0;
    const vec = k.KI(pointCount) orelse {
      k.listSet(points, i, k.KI(0));
      continue;
    };
    if (k.ip(vec)) |p| {
      var j: usize = 0;
      while (j < pointCount) : (j += 1) p[j] = ar.uint16() catch 0;
    }
    k.listSet(points, i, vec);
  }

  const keys = [_][*:0]const u8{ "gid", "points" };
  const vals = [_]?k.K{ gid, points };
  return k.dict(&keys, &vals);
}

// ── LigCaretList ────────────────────────────────────────────────────────────
//
// → dict {gid (I, covered ligature glyphs); carets (L — per glyph an L of caret
//   values)}. Each caret is decoded by CaretValue format:
//     fmt1 → coordinate (I)
//     fmt2 → pointIndex  (I)
//     fmt3 → coordinate  (I, the Device/VariationIndex sub-offset is ignored)
// All offsets (coverage, ligGlyph, caretValue) are relative to their enclosing
// sub-table's start.

fn caretValue(data: []const u8, off: usize) i32 {
  var r = Reader.at(data, off);
  const format = r.uint16() catch return 0;
  switch (format) {
    1 => return r.int16() catch 0,
    2 => return @intCast(r.uint16() catch 0),
    3 => return r.int16() catch 0, // coordinate; Device/VariationIndex ignored
    else => return 0,
  }
}

fn ligGlyph(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const caretCount = r.uint16() catch return k.KI(0);
  const carets = k.KI(caretCount) orelse return null;
  if (k.ip(carets)) |p| {
    var i: usize = 0;
    while (i < caretCount) : (i += 1) {
      const cvOff = r.uint16() catch 0;
      p[i] = if (cvOff != 0) caretValue(data, off + cvOff) else 0;
    }
  }
  return carets;
}

fn ligCaretList(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const coverageOffset = r.uint16() catch return null;
  const ligGlyphCount = r.uint16() catch return null;

  const gid = common.coverage(data, off + coverageOffset) orelse return null;
  const carets = k.KL(ligGlyphCount) orelse {
    k.unref(gid);
    return null;
  };

  var i: usize = 0;
  while (i < ligGlyphCount) : (i += 1) {
    const lgOff = r.uint16() catch 0;
    k.listSet(carets, i, if (lgOff != 0) ligGlyph(data, off + lgOff) else k.KI(0));
  }

  const keys = [_][*:0]const u8{ "gid", "carets" };
  const vals = [_]?k.K{ gid, carets };
  return k.dict(&keys, &vals);
}

// ── MarkGlyphSets ───────────────────────────────────────────────────────────
//
// → L of I vectors, each the covered glyph list of one mark glyph set.
// coverageOffsets are Offset32 from the start of the MarkGlyphSets table.

fn markGlyphSets(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  _ = r.uint16() catch return null; // format (1)
  const count = r.uint16() catch return null;
  const list = k.KL(count) orelse return null;
  var i: usize = 0;
  while (i < count) : (i += 1) {
    const covOff = r.uint32() catch 0;
    k.listSet(list, i, if (covOff != 0) common.coverage(data, off + covOff) else k.KI(0));
  }
  return list;
}

// ── GDEF header ─────────────────────────────────────────────────────────────

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const major = try r.uint16();
  const minor = try r.uint16();
  const glyphClassDefOffset = try r.uint16();
  const attachListOffset = try r.uint16();
  const ligCaretListOffset = try r.uint16();
  const markAttachClassDefOffset = try r.uint16();

  var markGlyphSetsDefOffset: u16 = 0;
  if (minor >= 2) markGlyphSetsDefOffset = try r.uint16();
  var itemVarStoreOffset: u32 = 0;
  if (minor >= 3) itemVarStoreOffset = try r.uint32();

  const version: f32 = @as(f32, @floatFromInt(major)) + (@as(f32, @floatFromInt(minor)) / 10.0);

  var keys: std.ArrayList([*:0]const u8) = .empty;
  var vals: std.ArrayList(?k.K) = .empty;
  defer keys.deinit(alloc);
  defer vals.deinit(alloc);

  keys.append(alloc, "version") catch {};
  vals.append(alloc, k.kf(version)) catch {};

  if (glyphClassDefOffset != 0) {
    keys.append(alloc, "glyphClass") catch {};
    vals.append(alloc, common.classDef(data, glyphClassDefOffset)) catch {};
  }
  if (markAttachClassDefOffset != 0) {
    keys.append(alloc, "markAttach") catch {};
    vals.append(alloc, common.classDef(data, markAttachClassDefOffset)) catch {};
  }
  if (attachListOffset != 0) {
    keys.append(alloc, "attachList") catch {};
    vals.append(alloc, attachList(data, attachListOffset)) catch {};
  }
  if (ligCaretListOffset != 0) {
    keys.append(alloc, "ligCaret") catch {};
    vals.append(alloc, ligCaretList(data, ligCaretListOffset)) catch {};
  }
  if (markGlyphSetsDefOffset != 0) {
    keys.append(alloc, "markGlyphSets") catch {};
    vals.append(alloc, markGlyphSets(data, markGlyphSetsDefOffset)) catch {};
  }
  if (itemVarStoreOffset != 0) {
    keys.append(alloc, "varStore") catch {};
    vals.append(alloc, common.itemVariationStore(data, itemVarStoreOffset)) catch {};
  }

  return k.dict(keys.items, vals.items);
}
