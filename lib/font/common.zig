/// Shared OpenType sub-table parsers used by several tables (layout + variations).
///
/// These take the enclosing table's byte slice and an absolute offset to the
/// sub-structure, and return a normalized K value. Kept here so GDEF / GPOS /
/// GSUB / MATH / BASE / HVAR / VVAR / MVAR all decode Coverage, ClassDef,
/// DeltaSetIndexMap and ItemVariationStore identically.

const std = @import("std");
const reader = @import("reader.zig");
const k = @import("kbuild.zig");

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

// ── Coverage ────────────────────────────────────────────────────────────────────
//
// → I vector of covered glyph ids in coverage-index order (so position i is the
// glyph with coverage index i).

pub fn coverage(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const format = r.uint16() catch return k.KI(0);
  if (format == 1) {
    const count = r.uint16() catch return k.KI(0);
    const v = k.KI(count) orelse return null;
    if (k.ip(v)) |p| {
      var i: usize = 0;
      while (i < count) : (i += 1) p[i] = r.uint16() catch 0;
    }
    return v;
  }
  if (format == 2) {
    const rangeCount = r.uint16() catch return k.KI(0);
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(alloc);
    var i: usize = 0;
    while (i < rangeCount) : (i += 1) {
      const start = r.uint16() catch break;
      const end = r.uint16() catch break;
      _ = r.uint16() catch break; // startCoverageIndex
      if (start > end) continue;
      var g: u32 = start;
      while (g <= end) : (g += 1) list.append(alloc, @intCast(g)) catch break;
    }
    return k.ints(i32, list.items);
  }
  return k.KI(0);
}

// ── ClassDef ────────────────────────────────────────────────────────────────────
//
// → dict of columns {gid; class} for every glyph with a non-zero class (class 0
// is the implicit default and omitted). Flip with `+`.

pub fn classDef(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  var gids: std.ArrayList(i32) = .empty;
  var classes: std.ArrayList(i32) = .empty;
  defer gids.deinit(alloc);
  defer classes.deinit(alloc);

  const format = r.uint16() catch 0;
  if (format == 1) {
    const startGlyph = r.uint16() catch 0;
    const count = r.uint16() catch 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
      const cls = r.uint16() catch break;
      if (cls != 0) {
        gids.append(alloc, @intCast(startGlyph + @as(u32, @intCast(i)))) catch break;
        classes.append(alloc, cls) catch break;
      }
    }
  } else if (format == 2) {
    const rangeCount = r.uint16() catch 0;
    var i: usize = 0;
    while (i < rangeCount) : (i += 1) {
      const start = r.uint16() catch break;
      const end = r.uint16() catch break;
      const cls = r.uint16() catch break;
      if (cls == 0 or start > end) continue;
      var g: u32 = start;
      while (g <= end) : (g += 1) {
        gids.append(alloc, @intCast(g)) catch break;
        classes.append(alloc, cls) catch break;
      }
    }
  }

  const keys = [_][*:0]const u8{ "gid", "class" };
  const vals = [_]?k.K{ k.ints(i32, gids.items), k.ints(i32, classes.items) };
  return k.dict(&keys, &vals);
}

// ── DeltaSetIndexMap ─────────────────────────────────────────────────────────────
//
// → dict of columns {outer; inner}, one row per mapped index. Maps an item
// (glyph) to an (outerIndex, innerIndex) into an ItemVariationStore.

pub fn deltaSetIndexMap(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const format = r.uint8() catch 0;
  const entryFormat = r.uint8() catch 0;
  const mapCount: usize = if (format == 0)
    (r.uint16() catch 0)
  else
    (r.uint32() catch 0);

  const innerBits: u5 = @intCast((entryFormat & 0x0F) + 1);
  const entrySize: usize = ((entryFormat & 0x30) >> 4) + 1;

  const outer = k.KI(mapCount) orelse return null;
  const inner = k.KI(mapCount) orelse return null;
  const op = k.ip(outer) orelse return null;
  const ip = k.ip(inner) orelse return null;

  var i: usize = 0;
  while (i < mapCount) : (i += 1) {
    var entry: u32 = 0;
    var b: usize = 0;
    while (b < entrySize) : (b += 1) entry = (entry << 8) | (r.uint8() catch 0);
    const innerMask: u32 = (@as(u32, 1) << innerBits) - 1;
    ip[i] = @intCast(entry & innerMask);
    op[i] = @intCast(entry >> innerBits);
  }

  const keys = [_][*:0]const u8{ "outer", "inner" };
  const vals = [_]?k.K{ outer, inner };
  return k.dict(&keys, &vals);
}

// ── ItemVariationStore ───────────────────────────────────────────────────────────
//
// → dict:
//   axisCount : I
//   regions   : L of dicts {start; peak; end} (each an F[axisCount] vector)
//   data      : L of dicts {regions (I region indices); deltas (L of I rows,
//               one per item, regionIndexCount wide)}

fn variationRegionList(data: []const u8, off: usize) struct { axisCount: u16, k: ?k.K } {
  var r = Reader.at(data, off);
  const axisCount = r.uint16() catch return .{ .axisCount = 0, .k = k.KL(0) };
  const regionCount = r.uint16() catch return .{ .axisCount = axisCount, .k = k.KL(0) };
  const list = k.KL(regionCount) orelse return .{ .axisCount = axisCount, .k = null };
  var i: usize = 0;
  while (i < regionCount) : (i += 1) {
    const start = k.KF(axisCount) orelse continue;
    const peak = k.KF(axisCount) orelse continue;
    const end = k.KF(axisCount) orelse continue;
    const sp = k.fp(start);
    const pp = k.fp(peak);
    const ep = k.fp(end);
    var a: usize = 0;
    while (a < axisCount) : (a += 1) {
      if (sp) |s| s[a] = r.f2dot14() catch 0;
      if (pp) |p| p[a] = r.f2dot14() catch 0;
      if (ep) |e| e[a] = r.f2dot14() catch 0;
    }
    const keys = [_][*:0]const u8{ "start", "peak", "end" };
    const vals = [_]?k.K{ start, peak, end };
    k.listSet(list, i, k.dict(&keys, &vals));
  }
  return .{ .axisCount = axisCount, .k = list };
}

fn itemVariationData(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  const itemCount = r.uint16() catch 0;
  const wordDeltaCount = r.uint16() catch 0;
  const longWords = (wordDeltaCount & 0x8000) != 0;
  const wordCount: usize = wordDeltaCount & 0x7FFF;
  const regionIndexCount = r.uint16() catch 0;

  const regions = k.KI(regionIndexCount) orelse return null;
  if (k.ip(regions)) |p| {
    var i: usize = 0;
    while (i < regionIndexCount) : (i += 1) p[i] = r.uint16() catch 0;
  }

  // deltaSets: one row per item, regionIndexCount columns. The first wordCount
  // columns are "long" (i16, or i32 when LONG_WORDS); the rest are short (i8,
  // or i16 when LONG_WORDS).
  const deltas = k.KL(itemCount) orelse return null;
  var item: usize = 0;
  while (item < itemCount) : (item += 1) {
    const row = k.KI(regionIndexCount) orelse continue;
    if (k.ip(row)) |rp| {
      var c: usize = 0;
      while (c < regionIndexCount) : (c += 1) {
        const long = c < wordCount;
        rp[c] = if (long and longWords)
          (r.int32() catch 0)
        else if (long)
          (r.int16() catch 0)
        else if (longWords)
          (r.int16() catch 0)
        else
          (r.int8() catch 0);
      }
    }
    k.listSet(deltas, item, row);
  }

  const keys = [_][*:0]const u8{ "regions", "deltas" };
  const vals = [_]?k.K{ regions, deltas };
  return k.dict(&keys, &vals);
}

pub fn itemVariationStore(data: []const u8, off: usize) ?k.K {
  var r = Reader.at(data, off);
  _ = r.uint16() catch 0; // format (1)
  const regionListOffset = r.uint32() catch 0;
  const dataCount = r.uint16() catch 0;

  const rl = variationRegionList(data, off + regionListOffset);

  const dataList = k.KL(dataCount) orelse return null;
  var i: usize = 0;
  while (i < dataCount) : (i += 1) {
    const dOff = r.uint32() catch 0;
    k.listSet(dataList, i, if (dOff != 0) itemVariationData(data, off + dOff) else k.KL(0));
  }

  const keys = [_][*:0]const u8{ "axisCount", "regions", "data" };
  const vals = [_]?k.K{ k.ki(rl.axisCount), rl.k, dataList };
  return k.dict(&keys, &vals);
}
