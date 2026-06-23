/// cmap — Character to Glyph Index Mapping.
/// doc/otf/table-cmap.md
///
/// Normalized to:
///   subtables : columns (platform, encoding, format) describing every subtable
///   cp        : I vector of mapped Unicode code points (ascending)
///   gid       : I vector of glyph IDs, parallel to cp
/// cp/gid come from the single best Unicode subtable (prefer Windows full
/// Unicode → Windows BMP → any Unicode-platform subtable; format 12 > 4 > 6 > 0).
/// Subtable formats 0, 4, 6 and 12 are decoded; others contribute a row to
/// `subtables` but no cp/gid entries.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const alloc = std.heap.c_allocator;
const Reader = reader.Reader;

fn rdU16(data: []const u8, pos: usize) u16 {
  if (pos + 2 > data.len) return 0;
  return std.mem.readInt(u16, data[pos..][0..2], .big);
}

const Pairs = struct {
  cp: std.ArrayList(i32),
  gid: std.ArrayList(i32),

  fn add(self: *Pairs, c: u32, g: u32) void {
    if (g == 0) return;
    self.cp.append(alloc, @intCast(c)) catch return;
    self.gid.append(alloc, @intCast(g)) catch return;
  }
};

fn decodeSubtable(sub: []const u8, out: *Pairs) void {
  const format = rdU16(sub, 0);
  switch (format) {
    0 => {
      // byte glyph array, 256 entries at offset 6
      var c: u32 = 0;
      while (c < 256) : (c += 1) {
        if (6 + c >= sub.len) break;
        out.add(c, sub[6 + c]);
      }
    },
    4 => {
      const segCount = rdU16(sub, 6) / 2;
      if (segCount == 0) return;
      const endBase: usize = 14;
      const startBase: usize = 16 + 2 * @as(usize, segCount);
      const deltaBase: usize = startBase + 2 * @as(usize, segCount);
      const rangeBase: usize = deltaBase + 2 * @as(usize, segCount);
      var i: usize = 0;
      while (i < segCount) : (i += 1) {
        const end = rdU16(sub, endBase + 2 * i);
        const start = rdU16(sub, startBase + 2 * i);
        const delta = rdU16(sub, deltaBase + 2 * i);
        const rangeOff = rdU16(sub, rangeBase + 2 * i);
        if (start > end) continue;
        var c: u32 = start;
        while (true) : (c += 1) {
          var g: u16 = 0;
          if (rangeOff == 0) {
            g = @truncate((c + delta) & 0xFFFF);
          } else {
            const gpos = rangeBase + 2 * i + rangeOff + 2 * (c - start);
            const raw = rdU16(sub, gpos);
            if (raw != 0) g = @truncate((@as(u32, raw) + delta) & 0xFFFF);
          }
          out.add(c, g);
          if (c == end) break;
        }
      }
    },
    6 => {
      const first = rdU16(sub, 6);
      const cnt = rdU16(sub, 8);
      var j: usize = 0;
      while (j < cnt) : (j += 1) {
        out.add(first + @as(u32, @intCast(j)), rdU16(sub, 10 + 2 * j));
      }
    },
    12 => {
      var r = Reader.at(sub, 12);
      const numGroups = r.uint32() catch return;
      var gi: u32 = 0;
      while (gi < numGroups) : (gi += 1) {
        const startCp = r.uint32() catch return;
        const endCp = r.uint32() catch return;
        const startGid = r.uint32() catch return;
        if (startCp > endCp) continue;
        var c: u32 = startCp;
        while (true) : (c += 1) {
          out.add(c, startGid + (c - startCp));
          if (c == endCp) break;
        }
      }
    },
    else => {},
  }
}

/// Priority of a (platform, encoding) Unicode subtable; higher wins. Non-Unicode
/// records score 0 and are never chosen for cp/gid.
fn unicodeScore(platform: u16, encoding: u16, format: u16) u32 {
  const base: u32 = switch (platform) {
    3 => switch (encoding) {
      10 => 40, // Windows full Unicode (UCS-4)
      1 => 30, // Windows BMP (UCS-2)
      else => 0,
    },
    0 => 20, // Unicode platform, any encoding
    else => 0,
  };
  if (base == 0) return 0;
  // Prefer richer formats when platform/encoding tie.
  const fbonus: u32 = switch (format) {
    12 => 4,
    4 => 3,
    6 => 2,
    0 => 1,
    else => 0,
  };
  return base + fbonus;
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = Reader.init(data);
  _ = try r.uint16(); // version
  const numTables = try r.uint16();

  const platform = k.KI(numTables) orelse return null;
  const encoding = k.KI(numTables) orelse return null;
  const format = k.KI(numTables) orelse return null;
  const pp = k.ip(platform) orelse return null;
  const ep = k.ip(encoding) orelse return null;
  const fp = k.ip(format) orelse return null;

  var bestScore: u32 = 0;
  var bestSub: []const u8 = &.{};

  var i: usize = 0;
  while (i < numTables) : (i += 1) {
    const plat = try r.uint16();
    const enc = try r.uint16();
    const off = try r.uint32();
    const sub: []const u8 = if (off < data.len) data[off..] else &.{};
    const fmt = rdU16(sub, 0);
    pp[i] = plat;
    ep[i] = enc;
    fp[i] = fmt;
    const score = unicodeScore(plat, enc, fmt);
    if (score > bestScore) {
      bestScore = score;
      bestSub = sub;
    }
  }

  var pairs = Pairs{ .cp = .empty, .gid = .empty };
  defer pairs.cp.deinit(alloc);
  defer pairs.gid.deinit(alloc);
  if (bestSub.len > 0) decodeSubtable(bestSub, &pairs);

  const subtables = k.dict(
    &[_][*:0]const u8{ "platform", "encoding", "format" },
    &[_]?k.K{ platform, encoding, format },
  );

  const keys = [_][*:0]const u8{ "subtables", "cp", "gid" };
  const vals = [_]?k.K{
    subtables,
    k.ints(i32, pairs.cp.items),
    k.ints(i32, pairs.gid.items),
  };
  return k.dict(&keys, &vals);
}
