/// Big-endian byte cursor for parsing the sfnt (TrueType/OpenType) container.
///
/// All multi-byte fields in a font file are stored big-endian. Every table
/// parser reads through one of these. Bounds are checked on every read; an
/// out-of-range read returns error.EndOfStream so a malformed table fails
/// cleanly (the dispatcher turns that into a null/absent table) instead of
/// reading past the buffer.

const std = @import("std");

pub const Error = error{EndOfStream};

pub const Reader = struct {
  data: []const u8,
  pos: usize = 0,

  pub fn init(data: []const u8) Reader {
    return .{ .data = data };
  }

  /// A reader over the same buffer starting at an absolute offset.
  pub fn at(data: []const u8, off: usize) Reader {
    return .{ .data = data, .pos = off };
  }

  pub fn eof(self: Reader) bool {
    return self.pos >= self.data.len;
  }

  pub fn remaining(self: Reader) usize {
    return if (self.pos < self.data.len) self.data.len - self.pos else 0;
  }

  pub fn seek(self: *Reader, off: usize) void {
    self.pos = off;
  }

  pub fn skip(self: *Reader, n: usize) void {
    self.pos += n;
  }

  /// Borrow the next `n` bytes and advance. The slice aliases the source buffer.
  pub fn bytes(self: *Reader, n: usize) Error![]const u8 {
    if (self.pos + n > self.data.len) return Error.EndOfStream;
    const s = self.data[self.pos .. self.pos + n];
    self.pos += n;
    return s;
  }

  // ── Unsigned ──────────────────────────────────────────────────────────────

  pub fn uint8(self: *Reader) Error!u8 {
    if (self.pos >= self.data.len) return Error.EndOfStream;
    const v = self.data[self.pos];
    self.pos += 1;
    return v;
  }

  pub fn uint16(self: *Reader) Error!u16 {
    if (self.pos + 2 > self.data.len) return Error.EndOfStream;
    const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
    self.pos += 2;
    return v;
  }

  /// 24-bit unsigned (uint24 / Offset24).
  pub fn uint24(self: *Reader) Error!u32 {
    const hi: u32 = try self.uint8();
    const mid: u32 = try self.uint8();
    const lo: u32 = try self.uint8();
    return (hi << 16) | (mid << 8) | lo;
  }

  pub fn uint32(self: *Reader) Error!u32 {
    if (self.pos + 4 > self.data.len) return Error.EndOfStream;
    const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
    self.pos += 4;
    return v;
  }

  pub fn uint64(self: *Reader) Error!u64 {
    if (self.pos + 8 > self.data.len) return Error.EndOfStream;
    const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .big);
    self.pos += 8;
    return v;
  }

  // ── Signed ────────────────────────────────────────────────────────────────

  pub fn int8(self: *Reader) Error!i8 {
    return @bitCast(try self.uint8());
  }
  pub fn int16(self: *Reader) Error!i16 {
    return @bitCast(try self.uint16());
  }
  pub fn int32(self: *Reader) Error!i32 {
    return @bitCast(try self.uint32());
  }
  pub fn int64(self: *Reader) Error!i64 {
    return @bitCast(try self.uint64());
  }

  // ── Font-specific scalar types ────────────────────────────────────────────

  /// A 4-byte table/feature/axis tag as a packed u32 (big-endian byte order
  /// preserved, so 'glyf' == 0x676C7966). Compare against tagFrom("glyf").
  pub fn tag(self: *Reader) Error!u32 {
    return self.uint32();
  }

  /// Fixed 16.16 → f32.
  pub fn fixed(self: *Reader) Error!f32 {
    const raw = try self.int32();
    return @as(f32, @floatFromInt(raw)) / 65536.0;
  }

  /// F2Dot14 (signed 2.14 fixed) → f32. Used for variation coordinates.
  pub fn f2dot14(self: *Reader) Error!f32 {
    const raw = try self.int16();
    return @as(f32, @floatFromInt(raw)) / 16384.0;
  }

  /// "Version16Dot16" style version stored as Fixed; returned as f32.
  pub fn version16dot16(self: *Reader) Error!f32 {
    const major = try self.uint16();
    const minor = try self.uint16();
    return @as(f32, @floatFromInt(major)) + (@as(f32, @floatFromInt(minor >> 12)) / 10.0);
  }

  /// LONGDATETIME: seconds since 1904-01-01 (i64).
  pub fn longdatetime(self: *Reader) Error!i64 {
    return self.int64();
  }
};

/// Pack a 4-character ASCII tag literal into the u32 the file stores.
pub fn tagFrom(comptime s: *const [4:0]u8) u32 {
  return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

/// Render a packed tag back to its 4 ASCII bytes (for diagnostics / dict keys).
pub fn tagBytes(t: u32) [4]u8 {
  return .{
    @intCast((t >> 24) & 0xFF),
    @intCast((t >> 16) & 0xFF),
    @intCast((t >> 8) & 0xFF),
    @intCast(t & 0xFF),
  };
}
