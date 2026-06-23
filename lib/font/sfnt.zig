/// sfnt container — offset table, table directory, TTC, and per-face dispatch.
///
/// readFont(data) returns a K *list* of face dicts (always a list, even for a
/// single-face TTF/OTF — uniform API across ttf/otf/ttc). Each face dict is
/// keyed by normalized table name (e.g. `head`, `cmap`, `OS2`) → that table's
/// normalized value. Only recognized tables present in the file appear.

const std = @import("std");
const reader = @import("reader.zig");
const k = @import("kbuild.zig");
const Ctx = @import("ctx.zig").Ctx;
const TableRec = @import("ctx.zig").TableRec;

const Reader = reader.Reader;
const tagFrom = reader.tagFrom;
const alloc = std.heap.c_allocator;

// ── Table registry ──────────────────────────────────────────────────────────────
//
// One entry per implemented table: the 4-byte file tag, the K dict key it is
// exposed under (slash/space-free so it is a usable k name — "OS/2"→"OS2",
// "cvt "→"cvt"), and its parser.

const ParseFn = *const fn (*const Ctx, []const u8) reader.Error!?k.K;
const Entry = struct { tag: u32, key: [*:0]const u8, parse: ParseFn };

const tables = [_]Entry{
  .{ .tag = tagFrom("head"), .key = "head", .parse = @import("table/head.zig").parse },
  .{ .tag = tagFrom("maxp"), .key = "maxp", .parse = @import("table/maxp.zig").parse },
  .{ .tag = tagFrom("hhea"), .key = "hhea", .parse = @import("table/hhea.zig").parse },
  .{ .tag = tagFrom("hmtx"), .key = "hmtx", .parse = @import("table/hmtx.zig").parse },
  .{ .tag = tagFrom("loca"), .key = "loca", .parse = @import("table/loca.zig").parse },
  .{ .tag = tagFrom("glyf"), .key = "glyf", .parse = @import("table/glyf.zig").parse },
  .{ .tag = tagFrom("post"), .key = "post", .parse = @import("table/post.zig").parse },
  .{ .tag = tagFrom("name"), .key = "name", .parse = @import("table/name.zig").parse },
  .{ .tag = tagFrom("OS/2"), .key = "OS2", .parse = @import("table/os2.zig").parse },
  .{ .tag = tagFrom("cmap"), .key = "cmap", .parse = @import("table/cmap.zig").parse },
  .{ .tag = tagFrom("cvt "), .key = "cvt", .parse = @import("table/cvt.zig").parse },
  .{ .tag = tagFrom("fpgm"), .key = "fpgm", .parse = @import("table/fpgm.zig").parse },
  .{ .tag = tagFrom("prep"), .key = "prep", .parse = @import("table/prep.zig").parse },
  .{ .tag = tagFrom("gasp"), .key = "gasp", .parse = @import("table/gasp.zig").parse },
  .{ .tag = tagFrom("vhea"), .key = "vhea", .parse = @import("table/vhea.zig").parse },
  .{ .tag = tagFrom("vmtx"), .key = "vmtx", .parse = @import("table/vmtx.zig").parse },
  .{ .tag = tagFrom("VORG"), .key = "VORG", .parse = @import("table/vorg.zig").parse },
  .{ .tag = tagFrom("hdmx"), .key = "hdmx", .parse = @import("table/hdmx.zig").parse },
  .{ .tag = tagFrom("LTSH"), .key = "LTSH", .parse = @import("table/ltsh.zig").parse },
  .{ .tag = tagFrom("DSIG"), .key = "DSIG", .parse = @import("table/dsig.zig").parse },
  .{ .tag = tagFrom("meta"), .key = "meta", .parse = @import("table/meta.zig").parse },
  .{ .tag = tagFrom("MERG"), .key = "MERG", .parse = @import("table/merg.zig").parse },
  .{ .tag = tagFrom("PCLT"), .key = "PCLT", .parse = @import("table/pclt.zig").parse },
  .{ .tag = tagFrom("fvar"), .key = "fvar", .parse = @import("table/fvar.zig").parse },
  .{ .tag = tagFrom("avar"), .key = "avar", .parse = @import("table/avar.zig").parse },
  .{ .tag = tagFrom("STAT"), .key = "STAT", .parse = @import("table/stat.zig").parse },
  .{ .tag = tagFrom("CPAL"), .key = "CPAL", .parse = @import("table/cpal.zig").parse },
  .{ .tag = tagFrom("COLR"), .key = "COLR", .parse = @import("table/colr.zig").parse },
  .{ .tag = tagFrom("kern"), .key = "kern", .parse = @import("table/kern.zig").parse },
  .{ .tag = tagFrom("sbix"), .key = "sbix", .parse = @import("table/sbix.zig").parse },
  .{ .tag = tagFrom("SVG "), .key = "SVG", .parse = @import("table/svg.zig").parse },
  .{ .tag = tagFrom("VDMX"), .key = "VDMX", .parse = @import("table/vdmx.zig").parse },
  .{ .tag = tagFrom("GDEF"), .key = "GDEF", .parse = @import("table/gdef.zig").parse },
  .{ .tag = tagFrom("GSUB"), .key = "GSUB", .parse = @import("table/gsub.zig").parse },
  .{ .tag = tagFrom("GPOS"), .key = "GPOS", .parse = @import("table/gpos.zig").parse },
  .{ .tag = tagFrom("BASE"), .key = "BASE", .parse = @import("table/base.zig").parse },
  .{ .tag = tagFrom("MATH"), .key = "MATH", .parse = @import("table/math.zig").parse },
  .{ .tag = tagFrom("HVAR"), .key = "HVAR", .parse = @import("table/hvar.zig").parse },
  .{ .tag = tagFrom("VVAR"), .key = "VVAR", .parse = @import("table/vvar.zig").parse },
  .{ .tag = tagFrom("MVAR"), .key = "MVAR", .parse = @import("table/mvar.zig").parse },
  .{ .tag = tagFrom("gvar"), .key = "gvar", .parse = @import("table/gvar.zig").parse },
  .{ .tag = tagFrom("cvar"), .key = "cvar", .parse = @import("table/cvar.zig").parse },
  .{ .tag = tagFrom("CFF "), .key = "CFF", .parse = @import("table/cff.zig").parse },
  .{ .tag = tagFrom("CFF2"), .key = "CFF2", .parse = @import("table/cff2.zig").parse },
  .{ .tag = tagFrom("CBLC"), .key = "CBLC", .parse = @import("table/cblc.zig").parse },
  .{ .tag = tagFrom("CBDT"), .key = "CBDT", .parse = @import("table/cbdt.zig").parse },
  .{ .tag = tagFrom("EBLC"), .key = "EBLC", .parse = @import("table/eblc.zig").parse },
  .{ .tag = tagFrom("EBDT"), .key = "EBDT", .parse = @import("table/ebdt.zig").parse },
  .{ .tag = tagFrom("EBSC"), .key = "EBSC", .parse = @import("table/ebsc.zig").parse },
  .{ .tag = tagFrom("JSTF"), .key = "JSTF", .parse = @import("table/jstf.zig").parse },
};

// ── Table directory ─────────────────────────────────────────────────────────────

fn findRec(recs: []const TableRec, tag: u32) ?TableRec {
  for (recs) |r| {
    if (r.tag == tag) return r;
  }
  return null;
}

fn sliceOf(file: []const u8, recs: []const TableRec, tag: u32) ?[]const u8 {
  const r = findRec(recs, tag) orelse return null;
  const end = @as(usize, r.off) + @as(usize, r.len);
  if (r.off > file.len or end > file.len) return null;
  return file[r.off..end];
}

/// Read the table directory at face offset `base` into a freshly allocated slice.
fn readDirectory(file: []const u8, base: usize) ?[]TableRec {
  var r = Reader.at(file, base);
  _ = r.uint32() catch return null; // sfntVersion
  const numTables = r.uint16() catch return null;
  r.skip(6); // searchRange, entrySelector, rangeShift
  if (numTables == 0 or numTables > 4096) return null;

  const recs = alloc.alloc(TableRec, numTables) catch return null;
  var i: usize = 0;
  while (i < numTables) : (i += 1) {
    const tag = r.uint32() catch {
      alloc.free(recs);
      return null;
    };
    _ = r.uint32() catch 0; // checksum
    const off = r.uint32() catch 0;
    const len = r.uint32() catch 0;
    recs[i] = .{ .tag = tag, .off = off, .len = len };
  }
  return recs;
}

// ── Header scalars + loca ────────────────────────────────────────────────────────

fn u16At(file: []const u8, recs: []const TableRec, tag: u32, fieldOff: usize) ?u16 {
  const s = sliceOf(file, recs, tag) orelse return null;
  var r = Reader.at(s, fieldOff);
  return r.uint16() catch null;
}

fn i16At(file: []const u8, recs: []const TableRec, tag: u32, fieldOff: usize) ?i16 {
  const s = sliceOf(file, recs, tag) orelse return null;
  var r = Reader.at(s, fieldOff);
  return r.int16() catch null;
}

fn parseLoca(file: []const u8, recs: []const TableRec, numGlyphs: u16, locFormat: i16) []u32 {
  const s = sliceOf(file, recs, tagFrom("loca")) orelse return &.{};
  const n: usize = @as(usize, numGlyphs) + 1;
  const out = alloc.alloc(u32, n) catch return &.{};
  var r = Reader.init(s);
  var i: usize = 0;
  if (locFormat == 0) {
    while (i < n) : (i += 1) out[i] = @as(u32, r.uint16() catch 0) * 2;
  } else {
    while (i < n) : (i += 1) out[i] = r.uint32() catch 0;
  }
  return out;
}

// ── Per-face build ───────────────────────────────────────────────────────────────

fn buildFace(file: []const u8, base: usize) ?k.K {
  const recs = readDirectory(file, base) orelse return null;
  defer alloc.free(recs);

  var ctx = Ctx{ .file = file, .recs = recs };
  // head: unitsPerEm @18, indexToLocFormat @50
  ctx.unitsPerEm = u16At(file, recs, tagFrom("head"), 18) orelse 1000;
  ctx.indexToLocFormat = i16At(file, recs, tagFrom("head"), 50) orelse 0;
  // maxp: numGlyphs @4
  ctx.numGlyphs = u16At(file, recs, tagFrom("maxp"), 4) orelse 0;
  // hhea: numberOfHMetrics @34
  ctx.numberOfHMetrics = u16At(file, recs, tagFrom("hhea"), 34) orelse 0;
  // vhea: numOfLongVerMetrics @34
  ctx.numberOfVMetrics = u16At(file, recs, tagFrom("vhea"), 34) orelse 0;
  ctx.isCFF = findRec(recs, tagFrom("CFF ")) != null or findRec(recs, tagFrom("CFF2")) != null;

  ctx.loca = parseLoca(file, recs, ctx.numGlyphs, ctx.indexToLocFormat);
  defer if (ctx.loca.len > 0) alloc.free(ctx.loca);

  var keys: [tables.len][*:0]const u8 = undefined;
  var vals: [tables.len]?k.K = undefined;
  var n: usize = 0;
  for (tables) |t| {
    const s = sliceOf(file, recs, t.tag) orelse continue;
    const v = (t.parse(&ctx, s) catch null) orelse continue;
    keys[n] = t.key;
    vals[n] = v;
    n += 1;
  }
  return k.dict(keys[0..n], vals[0..n]);
}

// ── Entry point ──────────────────────────────────────────────────────────────────

/// Parse all faces in `data`; returns a K list of face dicts, or null on failure.
pub fn readFont(data: []const u8) ?k.K {
  if (data.len < 12) return null;

  // TTC?  'ttcf' header lists per-face offset-table offsets.
  if (std.mem.readInt(u32, data[0..4], .big) == tagFrom("ttcf")) {
    var r = Reader.at(data, 8);
    const numFonts = r.uint32() catch return null;
    if (numFonts == 0 or numFonts > 256) return null;
    const list = k.KL(numFonts) orelse return null;
    var i: usize = 0;
    while (i < numFonts) : (i += 1) {
      const off = r.uint32() catch 0;
      k.listSet(list, i, buildFace(data, off));
    }
    return list;
  }

  // Single face → a one-element list (uniform API).
  const list = k.KL(1) orelse return null;
  k.listSet(list, 0, buildFace(data, 0));
  return list;
}
