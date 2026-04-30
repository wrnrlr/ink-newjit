// TrueType / OpenType font parser.
//
// `font@bytes` parses a TTF/OTF file into a queryable dict:
//
//   sfntVersion : `truetype | `opentype
//   tables      : symbol vector of all table tags present
//   head        : dict  [unitsPerEm; xMin; yMin; xMax; yMax; macStyle; indexToLocFormat]
//   maxp        : dict  [numGlyphs]
//   hhea        : dict  [ascender; descender; lineGap; advanceWidthMax; numberOfHMetrics]
//   OS2         : dict  [xAvgCharWidth; usWeightClass; usWidthClass; sTypoAscender; ...]
//   name        : table [[]nameId; platformId; name]
//   cmap        : table [[]codepoint; glyphId]          Unicode → glyph mapping
//   hmtx        : table [[]advanceWidth; lsb]           one row per glyph
//   fvar        : table [[]tag; min; default; max]       variation axes
//   COLR        : dict  [version; baseGlyphs; layers]   color glyph layers
//   CPAL        : table [[]r; g; b; a]                  color palette
//
// Font binary data is big-endian; all values in the output are host-order
// native Terse integers/floats.

const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../noun/value.zig");
const Pool  = @import("../noun/symbol.zig").Pool;

const V = value.V;
const N = value.N;

// ── Big-endian read helpers ───────────────────────────────────────────────────

inline fn u16be(d: []const u8, o: usize) u16 { return std.mem.readInt(u16, d[o..][0..2], .big); }
inline fn u32be(d: []const u8, o: usize) u32 { return std.mem.readInt(u32, d[o..][0..4], .big); }
inline fn i16be(d: []const u8, o: usize) i16 { return std.mem.readInt(i16, d[o..][0..2], .big); }
inline fn i32be(d: []const u8, o: usize) i32 { return std.mem.readInt(i32, d[o..][0..4], .big); }

fn fixed16_16(d: []const u8, o: usize) f32 {
    return @as(f32, @floatFromInt(i32be(d, o))) / 65536.0;
}

// ── Dict / table builders (direct copy — caller transfers ownership) ──────────

fn makeDict(alloc: Alloc, syms: []const u32, vals: []const V) !V {
    std.debug.assert(syms.len == vals.len);
    const keys = try N(u32).n1(alloc, syms);
    const vn   = try N(V).init(alloc, vals.len);
    @memcpy(vn.slice(), vals);
    return V{ .m = try value.Dict.init(alloc, .{ .S = keys }, .{ .L = vn }) };
}

fn makeTable(alloc: Alloc, syms: []const u32, cols: []const V) !V {
    std.debug.assert(syms.len == cols.len);
    const keys = try N(u32).n1(alloc, syms);
    const vn   = try N(V).init(alloc, cols.len);
    @memcpy(vn.slice(), cols);
    return V{ .M = try value.Dict.init(alloc, .{ .S = keys }, .{ .L = vn }) };
}

// ── Table directory ───────────────────────────────────────────────────────────

const Ref = struct { offset: u32, length: u32 };

fn findTable(d: []const u8, tag: *const [4]u8) ?Ref {
    if (d.len < 12) return null;
    const n = u16be(d, 4);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const base = 12 + i * 16;
        if (base + 16 > d.len) return null;
        if (std.mem.eql(u8, d[base..base + 4], tag))
            return .{ .offset = u32be(d, base + 8), .length = u32be(d, base + 12) };
    }
    return null;
}

fn parseTableTags(alloc: Alloc, pool: *Pool, d: []const u8) !V {
    if (d.len < 12) return .blank;
    const n    = u16be(d, 4);
    const tags = try N(u32).init(alloc, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const base = 12 + i * 16;
        if (base + 4 > d.len) break;
        const raw = d[base..base + 4];
        var end: usize = 4;
        while (end > 0 and raw[end - 1] == ' ') end -= 1;
        tags.slice()[i] = try pool.intern(raw[0..end]);
    }
    return V{ .S = tags };
}

// ── head ─────────────────────────────────────────────────────────────────────

fn parseHead(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref) !V {
    const b = r.offset;
    if (b + 54 > d.len) return .blank;
    return makeDict(alloc, &.{
        try pool.intern("unitsPerEm"),
        try pool.intern("xMin"), try pool.intern("yMin"),
        try pool.intern("xMax"), try pool.intern("yMax"),
        try pool.intern("macStyle"),
        try pool.intern("indexToLocFormat"),
    }, &.{
        .{ .i = u16be(d, b + 18) },
        .{ .i = i16be(d, b + 36) }, .{ .i = i16be(d, b + 38) },
        .{ .i = i16be(d, b + 40) }, .{ .i = i16be(d, b + 42) },
        .{ .i = u16be(d, b + 44) },
        .{ .i = i16be(d, b + 50) },
    });
}

// ── maxp ─────────────────────────────────────────────────────────────────────

fn parseMaxp(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref) !V {
    const b = r.offset;
    if (b + 6 > d.len) return .blank;
    return makeDict(alloc, &.{ try pool.intern("numGlyphs") },
                           &.{ .{ .i = u16be(d, b + 4) } });
}

// ── hhea ─────────────────────────────────────────────────────────────────────

fn parseHhea(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref) !V {
    const b = r.offset;
    if (b + 36 > d.len) return .blank;
    return makeDict(alloc, &.{
        try pool.intern("ascender"),      try pool.intern("descender"),
        try pool.intern("lineGap"),       try pool.intern("advanceWidthMax"),
        try pool.intern("numberOfHMetrics"),
    }, &.{
        .{ .i = i16be(d, b +  4) }, .{ .i = i16be(d, b +  6) },
        .{ .i = i16be(d, b +  8) }, .{ .i = u16be(d, b + 10) },
        .{ .i = u16be(d, b + 34) },
    });
}

// ── OS/2 ─────────────────────────────────────────────────────────────────────
//
// Offsets (v0+, 78 bytes minimum):
//   2  xAvgCharWidth (int16)
//   4  usWeightClass (uint16)
//   6  usWidthClass  (uint16)
//  68  sTypoAscender (int16)
//  70  sTypoDescender
//  72  sTypoLineGap
//  74  usWinAscent (uint16)
//  76  usWinDescent

fn parseOS2(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref) !V {
    const b = r.offset;
    if (b + 78 > d.len) return .blank;
    return makeDict(alloc, &.{
        try pool.intern("xAvgCharWidth"), try pool.intern("usWeightClass"),
        try pool.intern("usWidthClass"),  try pool.intern("sTypoAscender"),
        try pool.intern("sTypoDescender"),try pool.intern("sTypoLineGap"),
        try pool.intern("usWinAscent"),   try pool.intern("usWinDescent"),
    }, &.{
        .{ .i = i16be(d, b +  2) }, .{ .i = u16be(d, b +  4) },
        .{ .i = u16be(d, b +  6) }, .{ .i = i16be(d, b + 68) },
        .{ .i = i16be(d, b + 70) }, .{ .i = i16be(d, b + 72) },
        .{ .i = u16be(d, b + 74) }, .{ .i = u16be(d, b + 76) },
    });
}

// ── name ─────────────────────────────────────────────────────────────────────

fn internUtf16BE(alloc: Alloc, pool: *Pool, data: []const u8) !u32 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var i: usize = 0;
    while (i + 1 < data.len) {
        var cp: u32 = (@as(u32, data[i]) << 8) | data[i + 1];
        i += 2;
        // Surrogate pairs
        if (cp >= 0xD800 and cp <= 0xDBFF) {
            if (i + 1 >= data.len) break;
            const lo: u32 = (@as(u32, data[i]) << 8) | data[i + 1];
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            } else continue; // orphan high surrogate
        } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
            continue; // orphan low surrogate
        }
        if (cp == 0 or cp >= 0x110000) continue;
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(cp), &tmp) catch continue;
        try buf.appendSlice(alloc, tmp[0..len]);
    }
    return pool.intern(buf.items);
}

fn parseName(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref) !V {
    const b = r.offset;
    if (b + 6 > d.len) return .blank;
    const count   = u16be(d, b + 2);
    const str_off = u16be(d, b + 4);

    var name_ids: std.ArrayList(i32) = .empty; defer name_ids.deinit(alloc);
    var plat_ids: std.ArrayList(i32) = .empty; defer plat_ids.deinit(alloc);
    var names:    std.ArrayList(u32) = .empty; defer names.deinit(alloc);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec = b + 6 + i * 12;
        if (rec + 12 > d.len) break;
        const plat    = u16be(d, rec);
        const enc     = u16be(d, rec + 2);
        const name_id = u16be(d, rec + 6);
        const length  = u16be(d, rec + 8);
        const offset  = u16be(d, rec + 10);
        // Only Windows UTF-16BE (3,1) or (3,10), or Unicode platform (0,*)
        const is_utf16 = (plat == 3 and (enc == 1 or enc == 10)) or plat == 0;
        if (!is_utf16) continue;
        const str_abs = b + str_off + offset;
        if (str_abs + length > d.len) continue;
        const sym = try internUtf16BE(alloc, pool, d[str_abs..str_abs + length]);
        try name_ids.append(alloc, name_id);
        try plat_ids.append(alloc, plat);
        try names.append(alloc, sym);
    }

    const n = name_ids.items.len;
    if (n == 0) return .blank;

    const id_col  = try N(i32).n1(alloc, name_ids.items);
    const plt_col = try N(i32).n1(alloc, plat_ids.items);
    const nam_col = try N(u32).n1(alloc, names.items);

    return makeTable(alloc, &.{
        try pool.intern("nameId"), try pool.intern("platformId"), try pool.intern("name"),
    }, &.{ .{ .I = id_col }, .{ .I = plt_col }, .{ .S = nam_col } });
}

// ── cmap ─────────────────────────────────────────────────────────────────────
//
// Format 4: segmented BMP mapping (up to U+FFFF).
// Format 12: sequential group mapping, full Unicode.
// We prefer format 12 over format 4, and Windows (platform 3) over Unicode (0).

fn cmapFmt4(alloc: Alloc, d: []const u8, sub: usize,
            cps: *std.ArrayList(i32), gids: *std.ArrayList(i32)) !void {
    if (sub + 14 > d.len) return;
    const seg_count  = @as(usize, u16be(d, sub + 6)) / 2;
    const end_base   = sub + 14;
    const start_base = end_base + seg_count * 2 + 2; // +2 for reservedPad
    const delta_base = start_base + seg_count * 2;
    const range_base = delta_base + seg_count * 2;
    if (range_base + seg_count * 2 > d.len) return;

    var seg: usize = 0;
    while (seg < seg_count) : (seg += 1) {
        const end_cp   = @as(u32, u16be(d, end_base   + seg * 2));
        const start_cp = @as(u32, u16be(d, start_base + seg * 2));
        const delta    = @as(i32, i16be(d, delta_base + seg * 2));
        const roff     =          u16be(d, range_base + seg * 2);
        if (end_cp == 0xFFFF) break;

        var cp: u32 = start_cp;
        while (cp <= end_cp) : (cp += 1) {
            const gid: u16 = gid: {
                if (roff == 0) {
                    break :gid @intCast((@as(i32, @intCast(cp)) + delta) & 0xFFFF);
                } else {
                    // idRangeOffset is a byte offset from its own address
                    const entry_addr = range_base + seg * 2;
                    const addr = entry_addr + roff + (cp - start_cp) * 2;
                    if (addr + 2 > d.len) continue;
                    const raw = u16be(d, addr);
                    if (raw == 0) continue;
                    break :gid @intCast((@as(i32, raw) + delta) & 0xFFFF);
                }
            };
            if (gid == 0) continue;
            try cps.append(alloc, @intCast(cp));
            try gids.append(alloc, @intCast(gid));
        }
    }
}

fn cmapFmt12(alloc: Alloc, d: []const u8, sub: usize,
             cps: *std.ArrayList(i32), gids: *std.ArrayList(i32)) !void {
    if (sub + 16 > d.len) return;
    const num_groups  = u32be(d, sub + 12);
    const groups_base = sub + 16;
    if (groups_base + @as(usize, num_groups) * 12 > d.len) return;

    var g: usize = 0;
    while (g < num_groups) : (g += 1) {
        const base      = groups_base + g * 12;
        const start_cp  = u32be(d, base);
        const end_cp    = u32be(d, base + 4);
        const start_gid = u32be(d, base + 8);
        var cp: u32 = start_cp;
        while (cp <= end_cp) : (cp += 1) {
            const gid = start_gid + (cp - start_cp);
            if (gid == 0) continue;
            try cps.append(alloc, @intCast(cp));
            try gids.append(alloc, @intCast(gid));
        }
    }
}

fn parseCmap(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref) !V {
    const b = r.offset;
    if (b + 4 > d.len) return .blank;
    const num_enc = u16be(d, b + 2);

    var best_sub:   ?usize = null;
    var best_fmt:    u16   = 0;
    var best_score:  u8    = 0;

    var i: usize = 0;
    while (i < num_enc) : (i += 1) {
        const rec = b + 4 + i * 8;
        if (rec + 8 > d.len) break;
        const plat    = u16be(d, rec);
        const enc     = u16be(d, rec + 2);
        const sub_off = u32be(d, rec + 4);
        const sub_abs = b + sub_off;
        if (sub_abs + 2 > d.len) continue;
        const fmt = u16be(d, sub_abs);

        // Score: higher = preferred
        //  4: Windows full Unicode format 12
        //  3: Unicode platform full format 12
        //  2: Windows BMP format 4
        //  1: Unicode platform BMP format 4
        const score: u8 =
            if (plat == 3 and enc == 10 and fmt == 12) 4
            else if (plat == 0 and (enc == 4 or enc == 6) and fmt == 12) 3
            else if (plat == 3 and enc ==  1 and fmt ==  4) 2
            else if (plat == 0 and (enc == 3 or enc == 4) and fmt ==  4) 1
            else 0;

        if (score > best_score) {
            best_score = score;
            best_sub   = sub_abs;
            best_fmt   = fmt;
        }
    }

    if (best_sub == null) return .blank;

    var cps:  std.ArrayList(i32) = .empty; defer cps.deinit(alloc);
    var gids: std.ArrayList(i32) = .empty; defer gids.deinit(alloc);

    if (best_fmt == 12)
        try cmapFmt12(alloc, d, best_sub.?, &cps, &gids)
    else
        try cmapFmt4 (alloc, d, best_sub.?, &cps, &gids);

    if (cps.items.len == 0) return .blank;

    const cp_col  = try N(i32).n1(alloc, cps.items);
    const gid_col = try N(i32).n1(alloc, gids.items);
    return makeTable(alloc, &.{
        try pool.intern("codepoint"), try pool.intern("glyphId"),
    }, &.{ .{ .I = cp_col }, .{ .I = gid_col } });
}

// ── hmtx ─────────────────────────────────────────────────────────────────────
//
// LongHorMetric[numberOfHMetrics] followed by int16 lsb[numGlyphs-numberOfHMetrics].
// Glyphs beyond numberOfHMetrics share the last advanceWidth.

fn parseHmtx(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref,
              num_glyphs: u16, num_metrics: u16) !V {
    const b  = r.offset;
    const ng: usize = num_glyphs;
    const nm: usize = num_metrics;
    if (nm == 0 or b + nm * 4 > d.len) return .blank;

    const aw_col  = try N(i32).init(alloc, ng);
    const lsb_col = try N(i32).init(alloc, ng);
    var last_aw: i32 = 0;
    var i: usize = 0;
    while (i < ng) : (i += 1) {
        if (i < nm) {
            last_aw = u16be(d, b + i * 4);
            aw_col.slice()[i]  = last_aw;
            lsb_col.slice()[i] = i16be(d, b + i * 4 + 2);
        } else {
            aw_col.slice()[i]  = last_aw;
            const lsb_off = b + nm * 4 + (i - nm) * 2;
            lsb_col.slice()[i] = if (lsb_off + 2 <= d.len) i16be(d, lsb_off) else 0;
        }
    }

    return makeTable(alloc, &.{
        try pool.intern("advanceWidth"), try pool.intern("lsb"),
    }, &.{ .{ .I = aw_col }, .{ .I = lsb_col } });
}

// ── fvar ─────────────────────────────────────────────────────────────────────
//
// Header (16 bytes):
//   0  uint16  majorVersion  (must be 1)
//   2  uint16  minorVersion
//   4  Offset16 axesArrayOffset
//   6  uint16  reserved
//   8  uint16  axisCount
//  10  uint16  axisSize      (normally 20)
//  12  uint16  instanceCount
//  14  uint16  instanceSize
//
// VariationAxisRecord (20 bytes per axis):
//   0  Tag     axisTag
//   4  Fixed   minValue   (16.16)
//   8  Fixed   defaultValue
//  12  Fixed   maxValue
//  16  uint16  flags
//  18  uint16  axisNameID

fn parseFvar(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref) !V {
    const b = r.offset;
    if (b + 16 > d.len) return .blank;
    const axes_off   = u16be(d, b +  4);
    const axis_count = u16be(d, b +  8);
    const axis_size  = u16be(d, b + 10);
    if (axis_count == 0 or axis_size < 20) return .blank;

    var tags: std.ArrayList(u32) = .empty; defer tags.deinit(alloc);
    var mins: std.ArrayList(f32) = .empty; defer mins.deinit(alloc);
    var defs: std.ArrayList(f32) = .empty; defer defs.deinit(alloc);
    var maxs: std.ArrayList(f32) = .empty; defer maxs.deinit(alloc);

    var i: usize = 0;
    while (i < axis_count) : (i += 1) {
        const ax = b + axes_off + i * axis_size;
        if (ax + 20 > d.len) break;
        const raw = d[ax..ax + 4];
        // Trim trailing spaces (e.g. "cvt " → "cvt")
        var end: usize = 4;
        while (end > 0 and raw[end - 1] == ' ') end -= 1;
        try tags.append(alloc, try pool.intern(raw[0..end]));
        try mins.append(alloc, fixed16_16(d, ax +  4));
        try defs.append(alloc, fixed16_16(d, ax +  8));
        try maxs.append(alloc, fixed16_16(d, ax + 12));
    }

    if (tags.items.len == 0) return .blank;

    const tag_col = try N(u32).n1(alloc, tags.items);
    const min_col = try N(f32).n1(alloc, mins.items);
    const def_col = try N(f32).n1(alloc, defs.items);
    const max_col = try N(f32).n1(alloc, maxs.items);

    return makeTable(alloc, &.{
        try pool.intern("tag"), try pool.intern("min"),
        try pool.intern("default"), try pool.intern("max"),
    }, &.{
        .{ .S = tag_col }, .{ .F = min_col }, .{ .F = def_col }, .{ .F = max_col },
    });
}

// ── CPAL ─────────────────────────────────────────────────────────────────────
//
// Header (v0, 12 bytes):
//   0  uint16  version              (0 or 1)
//   2  uint16  numPaletteEntries
//   4  uint16  numPalettes
//   6  uint16  numColorRecords
//   8  Offset32 colorRecordsArray   (from start of CPAL table)
//
// ColorRecord (4 bytes, BGRA order):
//   0  uint8  blue
//   1  uint8  green
//   2  uint8  red
//   3  uint8  alpha

fn parseCpal(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref) !V {
    const b = r.offset;
    if (b + 12 > d.len) return .blank;
    const num_colors = u16be(d, b + 6);
    const colors_off = u32be(d, b + 8);
    const col_abs    = b + colors_off;
    if (col_abs + @as(usize, num_colors) * 4 > d.len) return .blank;

    const rc = try N(i32).init(alloc, num_colors);
    const gc = try N(i32).init(alloc, num_colors);
    const bc = try N(i32).init(alloc, num_colors);
    const ac = try N(i32).init(alloc, num_colors);

    var i: usize = 0;
    while (i < num_colors) : (i += 1) {
        const o = col_abs + i * 4;
        bc.slice()[i] = d[o];     // BGRA in spec
        gc.slice()[i] = d[o + 1];
        rc.slice()[i] = d[o + 2];
        ac.slice()[i] = d[o + 3];
    }

    return makeTable(alloc, &.{
        try pool.intern("r"), try pool.intern("g"),
        try pool.intern("b"), try pool.intern("a"),
    }, &.{ .{ .I = rc }, .{ .I = gc }, .{ .I = bc }, .{ .I = ac } });
}

// ── COLR ─────────────────────────────────────────────────────────────────────
//
// Header v0 (14 bytes):
//   0  uint16   version
//   2  uint16   numBaseGlyphRecords
//   4  Offset32 baseGlyphRecordsOffset  (from table start)
//   8  Offset32 layerRecordsOffset
//  12  uint16   numLayerRecords
//
// BaseGlyphRecord (6 bytes):  glyphID(u16), firstLayerIndex(u16), numLayers(u16)
// LayerRecord     (4 bytes):  glyphID(u16), paletteIndex(u16)

fn parseColr(alloc: Alloc, pool: *Pool, d: []const u8, r: Ref) !V {
    const b = r.offset;
    if (b + 14 > d.len) return .blank;

    const version    = u16be(d, b);
    const num_base   = u16be(d, b + 2);
    const base_off   = u32be(d, b + 4);
    const layer_off  = u32be(d, b + 8);
    const num_layers = u16be(d, b + 12);

    const base_abs  = b + base_off;
    const layer_abs = b + layer_off;
    if (base_abs  + @as(usize, num_base)   * 6 > d.len) return .blank;
    if (layer_abs + @as(usize, num_layers) * 4 > d.len) return .blank;

    // Base glyph records
    const bg_gid      = try N(i32).init(alloc, num_base);
    const bg_first    = try N(i32).init(alloc, num_base);
    const bg_nlayers  = try N(i32).init(alloc, num_base);
    var i: usize = 0;
    while (i < num_base) : (i += 1) {
        const o = base_abs + i * 6;
        bg_gid.slice()[i]     = u16be(d, o);
        bg_first.slice()[i]   = u16be(d, o + 2);
        bg_nlayers.slice()[i] = u16be(d, o + 4);
    }
    const base_tbl = try makeTable(alloc, &.{
        try pool.intern("glyphId"), try pool.intern("firstLayerIndex"), try pool.intern("numLayers"),
    }, &.{ .{ .I = bg_gid }, .{ .I = bg_first }, .{ .I = bg_nlayers } });

    // Layer records
    const l_gid = try N(i32).init(alloc, num_layers);
    const l_pal = try N(i32).init(alloc, num_layers);
    var j: usize = 0;
    while (j < num_layers) : (j += 1) {
        const o = layer_abs + j * 4;
        l_gid.slice()[j] = u16be(d, o);
        l_pal.slice()[j] = u16be(d, o + 2);
    }
    const layer_tbl = try makeTable(alloc, &.{
        try pool.intern("glyphId"), try pool.intern("paletteIndex"),
    }, &.{ .{ .I = l_gid }, .{ .I = l_pal } });

    return makeDict(alloc, &.{
        try pool.intern("version"),
        try pool.intern("baseGlyphs"),
        try pool.intern("layers"),
    }, &.{ .{ .i = version }, base_tbl, layer_tbl });
}

// ── Top-level parse helpers ───────────────────────────────────────────────────

const ParseFn = *const fn (Alloc, *Pool, []const u8, Ref) anyerror!V;

fn appendTable(
    alloc: Alloc, pool: *Pool, d: []const u8,
    file_tag: *const [4]u8, key: []const u8,
    keys: *std.ArrayList(u32), vals: *std.ArrayList(V),
    parseFn: ParseFn,
) !void {
    const ref = findTable(d, file_tag) orelse return;
    const v = try parseFn(alloc, pool, d, ref);
    if (v == .blank) return;
    try keys.append(alloc, try pool.intern(key));
    try vals.append(alloc, v);
}

// ── Top-level parse ───────────────────────────────────────────────────────────

pub fn parse(alloc: Alloc, pool: *Pool, d: []const u8) !V {
    if (d.len < 12) return .{ .err = .domain };

    const sfnt = u32be(d, 0);
    const sfnt_sym: u32 = switch (sfnt) {
        0x4F54544F          => try pool.intern("opentype"),  // 'OTTO'
        0x00010000,
        0x74727565          => try pool.intern("truetype"),  // 0x00010000 or 'true'
        else                => try pool.intern("unknown"),
    };

    // Pre-read numGlyphs / numberOfHMetrics (needed by hmtx)
    var num_glyphs:  u16 = 0;
    var num_metrics: u16 = 0;
    if (findTable(d, "maxp")) |r| if (r.offset + 6  <= d.len) { num_glyphs  = u16be(d, r.offset + 4);  };
    if (findTable(d, "hhea")) |r| if (r.offset + 36 <= d.len) { num_metrics = u16be(d, r.offset + 34); };

    var keys: std.ArrayList(u32) = .empty; defer keys.deinit(alloc);
    var vals: std.ArrayList(V)   = .empty; defer vals.deinit(alloc);

    // sfntVersion + tables list
    try keys.append(alloc, try pool.intern("sfntVersion"));
    try vals.append(alloc, .{ .s = sfnt_sym });
    try keys.append(alloc, try pool.intern("tables"));
    try vals.append(alloc, try parseTableTags(alloc, pool, d));

    // Known tables parsed into the result dict
    try appendTable(alloc, pool, d, "head", "head", &keys, &vals, parseHead);
    try appendTable(alloc, pool, d, "maxp", "maxp", &keys, &vals, parseMaxp);
    try appendTable(alloc, pool, d, "hhea", "hhea", &keys, &vals, parseHhea);
    try appendTable(alloc, pool, d, "OS/2", "OS2",  &keys, &vals, parseOS2);
    try appendTable(alloc, pool, d, "name", "name", &keys, &vals, parseName);
    try appendTable(alloc, pool, d, "cmap", "cmap", &keys, &vals, parseCmap);
    try appendTable(alloc, pool, d, "fvar", "fvar", &keys, &vals, parseFvar);
    try appendTable(alloc, pool, d, "COLR", "COLR", &keys, &vals, parseColr);
    try appendTable(alloc, pool, d, "CPAL", "CPAL", &keys, &vals, parseCpal);

    // hmtx — needs num_glyphs and num_metrics from above
    if (num_glyphs > 0 and num_metrics > 0) {
        if (findTable(d, "hmtx")) |ref| {
            const v = try parseHmtx(alloc, pool, d, ref, num_glyphs, num_metrics);
            if (v != .blank) {
                try keys.append(alloc, try pool.intern("hmtx"));
                try vals.append(alloc, v);
            }
        }
    }

    // Build result dict, transferring ownership of all values
    const k_n = try N(u32).n1(alloc, keys.items);
    const v_n = try N(V).init(alloc, vals.items.len);
    @memcpy(v_n.slice(), vals.items);
    // vals.deinit() in defer releases only the backing array, not the V data
    return V{ .m = try value.Dict.init(alloc, .{ .S = k_n }, .{ .L = v_n }) };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parse Cascadia Code" {
    const alloc = std.testing.allocator;
    var pool = @import("../noun/symbol.zig").Pool.init(alloc);
    defer pool.deinit();

    const zio = std.Io.Threaded.global_single_threaded.io();
    const data = try std.Io.Dir.cwd().readFileAlloc(
        zio, "font/Cascadia/CascadiaCode.ttf", alloc, std.Io.Limit.limited(10 * 1024 * 1024));
    defer alloc.free(data);

    const font = try parse(alloc, &pool, data);
    defer font.deinit(alloc);

    try std.testing.expect(font.tag() == .m);

    const font_keys = font.m.av().S.slice();
    const font_vals = font.m.bv().L.slice();

    // sfntVersion = `truetype
    const truetype_sym = try pool.intern("truetype");
    const sfnt_sym2    = try pool.intern("sfntVersion");
    for (font_keys, font_vals) |k, v| {
        if (k == sfnt_sym2) {
            try std.testing.expectEqual(truetype_sym, v.s);
            break;
        }
    }

    // head.unitsPerEm = 2048
    const head_sym = try pool.intern("head");
    const upm_sym  = try pool.intern("unitsPerEm");
    for (font_keys, font_vals) |k, v| {
        if (k != head_sym) continue;
        try std.testing.expect(v.tag() == .m);
        for (v.m.av().S.slice(), v.m.bv().L.slice()) |hk, hv| {
            if (hk == upm_sym) {
                try std.testing.expectEqual(@as(i32, 2048), hv.i);
                break;
            }
        }
        break;
    }

    // fvar: 1 axis = wght
    const fvar_sym = try pool.intern("fvar");
    const wght_sym = try pool.intern("wght");
    for (font_keys, font_vals) |k, v| {
        if (k != fvar_sym) continue;
        try std.testing.expect(v.tag() == .M);
        // columns are in the L value; first column (index 0) is `tag`
        const cols = v.M.bv().L.slice();
        try std.testing.expect(cols.len >= 1);
        try std.testing.expect(cols[0].tag() == .S);
        try std.testing.expectEqual(@as(usize, 1), cols[0].S.ptr.len);
        try std.testing.expectEqual(wght_sym, cols[0].S.slice()[0]);
        break;
    }

    // cmap: many codepoints
    const cmap_sym = try pool.intern("cmap");
    for (font_keys, font_vals) |k, v| {
        if (k != cmap_sym) continue;
        try std.testing.expect(v.tag() == .M);
        const cols = v.M.bv().L.slice();  // [codepoint col, glyphId col]
        try std.testing.expect(cols.len >= 1);
        try std.testing.expect(cols[0].tag() == .I);
        try std.testing.expect(cols[0].I.ptr.len > 100);
        break;
    }
}
