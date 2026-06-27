//! Snappy raw block decompression (no framing) — the codec Parquet feeds page
//! bodies through when `CompressionCodec == SNAPPY`. Implements the format at
//! https://github.com/google/snappy/blob/main/format_description.txt

const std = @import("std");

pub const Error = error{ Corrupt, OutOfMemory };

/// Decompress a Snappy block into a freshly allocated buffer owned by `alloc`.
pub fn decompress(alloc: std.mem.Allocator, src: []const u8) Error![]u8 {
  var pos: usize = 0;

  // Preamble: uncompressed length, little-endian varint.
  var ulen: usize = 0;
  var shift: u6 = 0;
  while (true) {
    if (pos >= src.len) return error.Corrupt;
    const b = src[pos];
    pos += 1;
    ulen |= @as(usize, b & 0x7f) << shift;
    if (b & 0x80 == 0) break;
    if (shift >= 28) return error.Corrupt;
    shift += 7;
  }

  const out = alloc.alloc(u8, ulen) catch return error.OutOfMemory;
  errdefer alloc.free(out);
  var o: usize = 0;

  while (pos < src.len) {
    const tag = src[pos];
    pos += 1;
    switch (tag & 0x03) {
      0 => { // literal
        var len: usize = (tag >> 2) + 1;
        if (len > 60) {
          const nbytes = len - 60; // 1..4 extra length bytes
          if (pos + nbytes > src.len) return error.Corrupt;
          var l: usize = 0;
          var i: usize = 0;
          while (i < nbytes) : (i += 1) l |= @as(usize, src[pos + i]) << @intCast(8 * i);
          pos += nbytes;
          len = l + 1;
        }
        if (pos + len > src.len or o + len > out.len) return error.Corrupt;
        @memcpy(out[o .. o + len], src[pos .. pos + len]);
        pos += len;
        o += len;
      },
      1 => { // copy, 1-byte offset
        const len: usize = ((tag >> 2) & 0x07) + 4;
        if (pos >= src.len) return error.Corrupt;
        const offset: usize = (@as(usize, tag >> 5) << 8) | src[pos];
        pos += 1;
        try copyOverlap(out, &o, offset, len);
      },
      2 => { // copy, 2-byte offset
        if (pos + 2 > src.len) return error.Corrupt;
        const len: usize = (tag >> 2) + 1;
        const offset: usize = std.mem.readInt(u16, src[pos..][0..2], .little);
        pos += 2;
        try copyOverlap(out, &o, offset, len);
      },
      3 => { // copy, 4-byte offset
        if (pos + 4 > src.len) return error.Corrupt;
        const len: usize = (tag >> 2) + 1;
        const offset: usize = std.mem.readInt(u32, src[pos..][0..4], .little);
        pos += 4;
        try copyOverlap(out, &o, offset, len);
      },
      else => unreachable,
    }
  }
  if (o != out.len) return error.Corrupt;
  return out;
}

fn copyOverlap(out: []u8, o: *usize, offset: usize, len: usize) Error!void {
  if (offset == 0 or offset > o.*) return error.Corrupt;
  if (o.* + len > out.len) return error.Corrupt;
  var src_pos = o.* - offset;
  var i: usize = 0;
  while (i < len) : (i += 1) {
    out[o.* + i] = out[src_pos];
    src_pos += 1;
  }
  o.* += len;
}
