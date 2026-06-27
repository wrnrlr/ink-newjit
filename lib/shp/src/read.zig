/// Endian-aware cursor over a byte buffer. The shapefile main/index files mix
/// big-endian (file code, record headers, .shx offsets) and little-endian
/// (version, shape type, all coordinates), so reads name their endianness.

const std = @import("std");

pub const Cursor = struct {
  buf: []const u8,
  pos: usize = 0,

  pub fn init(buf: []const u8) Cursor {
    return .{ .buf = buf };
  }

  pub fn remaining(c: Cursor) usize {
    return c.buf.len - c.pos;
  }

  pub fn seek(c: *Cursor, p: usize) void {
    c.pos = p;
  }

  pub fn skip(c: *Cursor, n: usize) void {
    c.pos += n;
  }

  fn take(c: *Cursor, comptime n: usize) ?[n]u8 {
    if (c.pos + n > c.buf.len) return null;
    var out: [n]u8 = undefined;
    @memcpy(&out, c.buf[c.pos .. c.pos + n]);
    c.pos += n;
    return out;
  }

  pub fn i32be(c: *Cursor) i32 {
    const b = c.take(4) orelse return 0;
    return std.mem.readInt(i32, &b, .big);
  }
  pub fn i32le(c: *Cursor) i32 {
    const b = c.take(4) orelse return 0;
    return std.mem.readInt(i32, &b, .little);
  }
  pub fn u32le(c: *Cursor) u32 {
    const b = c.take(4) orelse return 0;
    return std.mem.readInt(u32, &b, .little);
  }
  pub fn u16le(c: *Cursor) u16 {
    const b = c.take(2) orelse return 0;
    return std.mem.readInt(u16, &b, .little);
  }
  pub fn f64le(c: *Cursor) f64 {
    const b = c.take(8) orelse return 0;
    return @bitCast(std.mem.readInt(u64, &b, .little));
  }

  /// Read a fixed-width field as a byte slice aliasing the buffer (no copy).
  pub fn bytes(c: *Cursor, n: usize) []const u8 {
    if (c.pos + n > c.buf.len) {
      const s = c.buf[c.pos..];
      c.pos = c.buf.len;
      return s;
    }
    const s = c.buf[c.pos .. c.pos + n];
    c.pos += n;
    return s;
  }
};

/// Read an entire file into a heap slice (caller frees).
pub fn readFile(alloc: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
  const io = std.Io.Threaded.global_single_threaded.io();
  return std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(path), alloc, std.Io.Limit.limited(512 << 20));
}
