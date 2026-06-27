//! Minimal Thrift TCompactProtocol reader — just enough to walk the Parquet
//! `FileMetaData` and `PageHeader` structures. All Parquet metadata is encoded
//! with the compact protocol (see parquet-format `parquet.thrift`).

const std = @import("std");

pub const Error = error{ EndOfStream, BadProtocol };

/// Compact-protocol field/element type codes.
pub const Type = enum(u8) {
  stop = 0,
  bool_true = 1,
  bool_false = 2,
  byte = 3,
  i16 = 4,
  i32 = 5,
  i64 = 6,
  double = 7,
  binary = 8,
  list = 9,
  set = 10,
  map = 11,
  struct_ = 12,
  _,
};

pub const Field = struct { id: i16, type: Type };

pub const Reader = struct {
  buf: []const u8,
  pos: usize = 0,
  // Field-id state is per struct scope; we keep a small stack of last ids so
  // nested structs decode their short-form deltas correctly.
  last_id: i16 = 0,
  id_stack: [32]i16 = undefined,
  depth: usize = 0,
  // Pending bool value carried in a field header (compact encodes bool in the
  // type nibble of the field header rather than in the body).
  pending_bool: ?bool = null,

  pub fn init(buf: []const u8) Reader {
    return .{ .buf = buf };
  }

  fn u8at(r: *Reader) Error!u8 {
    if (r.pos >= r.buf.len) return error.EndOfStream;
    const b = r.buf[r.pos];
    r.pos += 1;
    return b;
  }

  /// Unsigned LEB128 varint.
  pub fn varint(r: *Reader) Error!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
      const b = try r.u8at();
      result |= @as(u64, b & 0x7f) << shift;
      if (b & 0x80 == 0) break;
      if (shift >= 63) return error.BadProtocol;
      shift += 7;
    }
    return result;
  }

  /// Zigzag-decoded signed varint.
  pub fn zigzag(r: *Reader) Error!i64 {
    const u = try r.varint();
    return @bitCast((u >> 1) ^ (~(u & 1) +% 1));
  }

  pub fn structBegin(r: *Reader) void {
    r.id_stack[r.depth] = r.last_id;
    r.depth += 1;
    r.last_id = 0;
  }

  pub fn structEnd(r: *Reader) void {
    r.depth -= 1;
    r.last_id = r.id_stack[r.depth];
  }

  /// Read the next field header. Returns a field with `type == .stop` at the
  /// end of the current struct.
  pub fn fieldBegin(r: *Reader) Error!Field {
    const b = try r.u8at();
    if (b == 0) return .{ .id = 0, .type = .stop };
    const type_nibble: u8 = b & 0x0f;
    const delta: u8 = (b & 0xf0) >> 4;
    var id: i16 = undefined;
    if (delta == 0) {
      id = @intCast(try r.zigzag());
    } else {
      id = r.last_id + @as(i16, @intCast(delta));
    }
    r.last_id = id;
    r.pending_bool = switch (type_nibble) {
      1 => true,
      2 => false,
      else => null,
    };
    return .{ .id = id, .type = @enumFromInt(type_nibble) };
  }

  pub fn readBool(r: *Reader) Error!bool {
    if (r.pending_bool) |v| return v;
    return (try r.u8at()) != 0;
  }

  pub fn readByte(r: *Reader) Error!i8 {
    return @bitCast(try r.u8at());
  }

  pub fn readI32(r: *Reader) Error!i32 {
    return @intCast(try r.zigzag());
  }

  pub fn readI64(r: *Reader) Error!i64 {
    return r.zigzag();
  }

  pub fn readDouble(r: *Reader) Error!f64 {
    if (r.pos + 8 > r.buf.len) return error.EndOfStream;
    const bits = std.mem.readInt(u64, r.buf[r.pos..][0..8], .little);
    r.pos += 8;
    return @bitCast(bits);
  }

  /// Returns a slice into the underlying buffer (no copy).
  pub fn readBinary(r: *Reader) Error![]const u8 {
    const len: usize = @intCast(try r.varint());
    if (r.pos + len > r.buf.len) return error.EndOfStream;
    const out = r.buf[r.pos .. r.pos + len];
    r.pos += len;
    return out;
  }

  /// List header → element type and count.
  pub fn listBegin(r: *Reader) Error!struct { type: Type, size: usize } {
    const b = try r.u8at();
    const type_nibble: u8 = b & 0x0f;
    var size: usize = (b & 0xf0) >> 4;
    if (size == 15) size = @intCast(try r.varint());
    return .{ .type = @enumFromInt(type_nibble), .size = size };
  }

  /// Skip a value of the given type (used for fields we don't care about).
  pub fn skip(r: *Reader, t: Type) Error!void {
    switch (t) {
      .bool_true, .bool_false => {},
      .byte => _ = try r.u8at(),
      .i16, .i32, .i64 => _ = try r.zigzag(),
      .double => _ = try r.readDouble(),
      .binary => _ = try r.readBinary(),
      .list, .set => {
        const h = try r.listBegin();
        var i: usize = 0;
        while (i < h.size) : (i += 1) try r.skip(h.type);
      },
      .map => {
        const b = try r.u8at();
        const size: usize = if (b == 0) 0 else @intCast(try r.varint());
        const kv: u8 = if (b == 0) 0 else b;
        const ktype: Type = @enumFromInt((kv & 0xf0) >> 4);
        const vtype: Type = @enumFromInt(kv & 0x0f);
        var i: usize = 0;
        while (i < size) : (i += 1) {
          try r.skip(ktype);
          try r.skip(vtype);
        }
      },
      .struct_ => {
        r.structBegin();
        while (true) {
          const f = try r.fieldBegin();
          if (f.type == .stop) break;
          try r.skip(f.type);
        }
        r.structEnd();
      },
      else => return error.BadProtocol,
    }
  }
};
