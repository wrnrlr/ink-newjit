/// kern — Kerning.
/// doc/otf/table-kern.md
///
/// Flattens the kerning pairs from every format-0 subtable into three
/// equal-length columns:
///   left  : I — left-hand glyph index of each pair
///   right : I — right-hand glyph index
///   value : I — kerning value in font design units (signed FWORD)
/// Pairs are accumulated across all format-0 subtables; flip with `+` for a
/// per-pair table. Both header layouts are handled:
///   Microsoft/OpenType — version uint16(=0), nTables uint16; subtable header
///     version/length/coverage(u16) with the format in the HIGH byte of coverage.
///   Apple TrueType — version uint32(=0x00010000), nTables uint32; subtable
///     header length(u32), coverage(u16, format in the LOW byte), tupleIndex(u16).
/// Only format-0 subtables contribute pairs; formats 1/2/3 are skipped. If no
/// format-0 pairs exist the dict is still returned with three empty I vectors.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const alloc = std.heap.c_allocator;

const Pairs = struct {
  left: std.ArrayList(i32),
  right: std.ArrayList(i32),
  value: std.ArrayList(i32),

  fn add(self: *Pairs, l: u16, rt: u16, v: i16) void {
    self.left.append(alloc, @intCast(l)) catch return;
    self.right.append(alloc, @intCast(rt)) catch return;
    self.value.append(alloc, @intCast(v)) catch return;
  }
};

/// Read the nPairs × {left u16, right u16, value i16} list of a format-0
/// subtable. `r` is positioned at the start of the format-0 body (just past
/// the subtable header). Truncated data stops parsing cleanly.
fn decodeFormat0(r: *reader.Reader, out: *Pairs) void {
  const nPairs = r.uint16() catch return;
  _ = r.uint16() catch return; // searchRange
  _ = r.uint16() catch return; // entrySelector
  _ = r.uint16() catch return; // rangeShift
  var i: usize = 0;
  while (i < nPairs) : (i += 1) {
    const l = r.uint16() catch return;
    const rt = r.uint16() catch return;
    const v = r.int16() catch return;
    out.add(l, rt, v);
  }
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;

  var pairs = Pairs{ .left = .empty, .right = .empty, .value = .empty };
  defer pairs.left.deinit(alloc);
  defer pairs.right.deinit(alloc);
  defer pairs.value.deinit(alloc);

  var r = reader.Reader.init(data);
  // The first uint16 disambiguates the two header layouts: 0 → Microsoft,
  // 1 → high half of the Apple uint32 version 0x00010000.
  const first = try r.uint16();

  if (first == 1) {
    // Apple TrueType: version uint32 (already consumed high half), nTables u32.
    _ = try r.uint16(); // low half of the uint32 version
    const nTables = try r.uint32();
    var t: u32 = 0;
    while (t < nTables) : (t += 1) {
      const subStart = r.pos;
      const length = try r.uint32(); // length (u32, including header)
      const coverage = try r.uint16();
      _ = try r.uint16(); // tupleIndex
      const format: u8 = @truncate(coverage & 0xFF); // format in LOW byte
      if (format == 0) decodeFormat0(&r, &pairs);
      // Advance to the next subtable regardless of format/parse state.
      if (length == 0) break;
      r.seek(subStart + length);
      if (r.pos <= subStart or r.pos > data.len) break;
    }
  } else {
    // Microsoft/OpenType: version uint16 (already consumed), nTables u16.
    const nTables = try r.uint16();
    var t: u32 = 0;
    while (t < nTables) : (t += 1) {
      const subStart = r.pos;
      _ = try r.uint16(); // subtable version
      const length = try r.uint16(); // length (u16, including header)
      const coverage = try r.uint16();
      const format: u8 = @truncate(coverage >> 8); // format in HIGH byte
      if (format == 0) decodeFormat0(&r, &pairs);
      if (length == 0) break;
      r.seek(subStart + length);
      if (r.pos <= subStart or r.pos > data.len) break;
    }
  }

  const keys = [_][*:0]const u8{ "left", "right", "value" };
  const vals = [_]?k.K{
    k.ints(i32, pairs.left.items),
    k.ints(i32, pairs.right.items),
    k.ints(i32, pairs.value.items),
  };
  return k.dict(&keys, &vals);
}
