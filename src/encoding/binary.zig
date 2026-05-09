// Binary serialization format for Terse values.
//
// Format:
//   [VERSION: 1 byte = 0x03]
//   [value: recursive]
//
// Each value:
//   [type tag: 1 byte = K.serCode() compact index 0–17]
//   [payload]
//
// Atoms:
//   blank: (no payload)
//   err:   1 byte (Err ordinal)
//   b:     1 byte (0=false, 1=true)
//   i:     8 bytes LE i32
//   f:     8 bytes (f32 bit pattern, LE u32)
//   s:     4 bytes LE u32 len + len bytes UTF-8 string
//   c:     1 bytes LE u8 codepoint
//
// Vectors:
//   B: 4 bytes n + n*1 byte (0/1 per element)
//   I: 4 bytes n + n*8 bytes raw i32 LE
//   F: 4 bytes n + n*8 bytes raw f32 LE
//   S: 4 bytes n + n*(4 bytes len + len bytes)
//   C: 4 bytes n + n bytes raw u8
//
// Composite:
//   L: 4 bytes n + n*value (recursive)
//   m/A/a: value (keys) + value (values)

const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../noun/value.zig");
const Pool = @import("../noun/symbol.zig").Pool;
const K = @import("../noun/class.zig").K;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const Dict = @import("../noun/dict.zig").Dict;
const Err = value.Err;

const VERSION: u8 = 0x03;

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

pub fn serialize(alloc: Alloc, pool: *const Pool, v: V) !V {
  var buf: std.ArrayList(u8) = .empty;
  defer buf.deinit(alloc);
  try buf.append(alloc, VERSION);
  try serVal(&buf, alloc, pool, v);
  const result = try N(u8).n1(alloc, buf.items);
  return .{ .C = result };
}

fn serVal(buf: *std.ArrayList(u8), alloc: Alloc, pool: *const Pool, v: V) anyerror!void {
  try buf.append(alloc, v.tag().serCode());
  switch (v) {
    .blank => {},
    .err   => |e| try buf.append(alloc, @intFromEnum(e)),
    .b     => |b| try buf.append(alloc, if (b) 1 else 0),
    .i     => |i| try writeI64(buf, alloc, i),
    .f     => |f| try writeU64(buf, alloc, @bitCast(f)),
    .s     => |s| try writeStr(buf, alloc, pool.get(s)),
    .c     => |c| try writeU8(buf, alloc, c),
    .B => |n| {
      try writeU32(buf, alloc, @intCast(n.ptr.len));
      for (n.slice()) |b| try buf.append(alloc, if (b) 1 else 0);
    },
    .I => |n| {
      try writeU32(buf, alloc, @intCast(n.ptr.len));
      try buf.appendSlice(alloc, std.mem.sliceAsBytes(n.slice()));
    },
    .F => |n| {
      try writeU32(buf, alloc, @intCast(n.ptr.len));
      try buf.appendSlice(alloc, std.mem.sliceAsBytes(n.slice()));
    },
    .S => |n| {
      try writeU32(buf, alloc, @intCast(n.ptr.len));
      for (n.slice()) |s| try writeStr(buf, alloc, pool.get(s));
    },
    .C => |n| {
      try writeU32(buf, alloc, @intCast(n.ptr.len));
      try buf.appendSlice(alloc, n.slice());
    },
    .L => |n| {
      try writeU32(buf, alloc, @intCast(n.ptr.len));
      for (n.slice()) |item| try serVal(buf, alloc, pool, item);
    },
    .m => |d| { try serVal(buf, alloc, pool, d.av()); try serVal(buf, alloc, pool, d.bv()); },
    .M => |d| { try serVal(buf, alloc, pool, d.av()); try serVal(buf, alloc, pool, d.bv()); },
    // Lambdas, partials, derived verbs, etc. are not serializable
    else => return error.UnsupportedType,
  }
}

fn writeU8(buf: *std.ArrayList(u8), alloc: Alloc, v: u8) !void {
  var b: [1]u8 = undefined;
  std.mem.writeInt(u8, &b, v, .little);
  try buf.appendSlice(alloc, &b);
}

fn writeU32(buf: *std.ArrayList(u8), alloc: Alloc, v: u32) !void {
  var b: [4]u8 = undefined;
  std.mem.writeInt(u32, &b, v, .little);
  try buf.appendSlice(alloc, &b);
}

fn writeI32(buf: *std.ArrayList(u8), alloc: Alloc, v: i32) !void {
  var b: [4]u8 = undefined;
  std.mem.writeInt(i32, &b, v, .little);
  try buf.appendSlice(alloc, &b);
}

fn writeI64(buf: *std.ArrayList(u8), alloc: Alloc, v: i32) !void {
  var b: [4]u8 = undefined;
  std.mem.writeInt(i32, &b, v, .little);
  try buf.appendSlice(alloc, &b);
}

fn writeU64(buf: *std.ArrayList(u8), alloc: Alloc, v: u32) !void {
  var b: [4]u8 = undefined;
  std.mem.writeInt(u32, &b, v, .little);
  try buf.appendSlice(alloc, &b);
}

fn writeStr(buf: *std.ArrayList(u8), alloc: Alloc, s: []const u8) !void {
  try writeU32(buf, alloc, @intCast(s.len));
  try buf.appendSlice(alloc, s);
}

// ---------------------------------------------------------------------------
// Deserialization
// ---------------------------------------------------------------------------

pub fn deserialize(alloc: Alloc, pool: *Pool, bytes: []const u8) !V {
  if (bytes.len < 1) return .{ .err = .domain };
  if (bytes[0] != VERSION) return .{ .err = .domain };
  var pos: usize = 1;
  return desVal(alloc, pool, bytes, &pos) catch .{ .err = .domain };
}

fn desVal(alloc: Alloc, pool: *Pool, bytes: []const u8, pos: *usize) anyerror!V {
  if (pos.* >= bytes.len) return error.UnexpectedEof;
  const tag = bytes[pos.*];
  pos.* += 1;
  const k: K = K.fromCode(tag) orelse return error.UnsupportedType;
  return switch (k) {
    .blank => .blank,
    .err => blk: {
      if (pos.* >= bytes.len) return error.UnexpectedEof;
      const e: Err = @enumFromInt(bytes[pos.*]);
      pos.* += 1;
      break :blk .{ .err = e };
    },
    .b => blk: {
      if (pos.* >= bytes.len) return error.UnexpectedEof;
      const b = bytes[pos.*] != 0;
      pos.* += 1;
      break :blk .{ .b = b };
    },
    .i => .{ .i = try rdI64(bytes, pos) },
    .f => blk: {
      const bits = try rdU64(bytes, pos);
      break :blk .{ .f = @bitCast(bits) };
    },
    .s => blk: {
      const str = try rdStr(alloc, bytes, pos);
      defer alloc.free(str);
      break :blk .{ .s = try pool.intern(str) };
    },
    .c => .{ .c = try rdU8(bytes, pos) },
    .B => blk: {
      const n = try rdU32(bytes, pos);
      const vec = try N(bool).init(alloc, n);
      errdefer vec.deinit(alloc);
      for (vec.slice()) |*b| {
        if (pos.* >= bytes.len) return error.UnexpectedEof;
        b.* = bytes[pos.*] != 0;
        pos.* += 1;
      }
      break :blk .{ .B = vec };
    },
    .I => blk: {
      const n = try rdU32(bytes, pos);
      const vec = try N(i32).init(alloc, n);
      errdefer vec.deinit(alloc);
      const byte_len = n * @sizeOf(i32);
      if (pos.* + byte_len > bytes.len) return error.UnexpectedEof;
      @memcpy(std.mem.sliceAsBytes(vec.slice()), bytes[pos.*..][0..byte_len]);
      pos.* += byte_len;
      break :blk .{ .I = vec };
    },
    .F => blk: {
      const n = try rdU32(bytes, pos);
      const vec = try N(f32).init(alloc, n);
      errdefer vec.deinit(alloc);
      const byte_len = n * @sizeOf(f32);
      if (pos.* + byte_len > bytes.len) return error.UnexpectedEof;
      @memcpy(std.mem.sliceAsBytes(vec.slice()), bytes[pos.*..][0..byte_len]);
      pos.* += byte_len;
      break :blk .{ .F = vec };
    },
    .S => blk: {
      const n = try rdU32(bytes, pos);
      const vec = try N(u32).init(alloc, n);
      errdefer vec.deinit(alloc);
      for (vec.slice()) |*s| {
        const str = try rdStr(alloc, bytes, pos);
        defer alloc.free(str);
        s.* = try pool.intern(str);
      }
      break :blk .{ .S = vec };
    },
    .C => blk: {
      const n = try rdU32(bytes, pos);
      if (pos.* + n > bytes.len) return error.UnexpectedEof;
      const vec = try N(u8).n1(alloc, bytes[pos.*..][0..n]);
      pos.* += n;
      break :blk .{ .C = vec };
    },
    .L => blk: {
      const n = try rdU32(bytes, pos);
      const vec = try N(V).init(alloc, n);
      errdefer vec.deinit(alloc);
      for (vec.slice()) |*item| {
        item.* = .blank;
        item.* = try desVal(alloc, pool, bytes, pos);
      }
      break :blk .{ .L = vec };
    },
    .m => blk: {
      const av = try desVal(alloc, pool, bytes, pos);
      errdefer av.deinit(alloc);
      const bv = try desVal(alloc, pool, bytes, pos);
      errdefer bv.deinit(alloc);
      break :blk .{ .m = try Dict.init(alloc, av, bv) };
    },
    .M => blk: {
      const av = try desVal(alloc, pool, bytes, pos);
      errdefer av.deinit(alloc);
      const bv = try desVal(alloc, pool, bytes, pos);
      errdefer bv.deinit(alloc);
      break :blk .{ .M = try Dict.init(alloc, av, bv) };
    },
    else => error.UnsupportedType,
  };
}

fn rdU8(bytes: []const u8, pos: *usize) !u8 {
  if (pos.* + 1 > bytes.len) return error.UnexpectedEof;
  const v = std.mem.readInt(u8, bytes[pos.*..][0..1], .little);
  pos.* += 1;
  return v;
}

fn rdU32(bytes: []const u8, pos: *usize) !u32 {
  if (pos.* + 4 > bytes.len) return error.UnexpectedEof;
  const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
  pos.* += 4;
  return v;
}

fn rdI32(bytes: []const u8, pos: *usize) !i32 {
  if (pos.* + 4 > bytes.len) return error.UnexpectedEof;
  const v = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
  pos.* += 4;
  return v;
}

fn rdI64(bytes: []const u8, pos: *usize) !i32 {
  if (pos.* + 4 > bytes.len) return error.UnexpectedEof;
  const v = std.mem.readInt(i32, bytes[pos.*..][0..4], .little);
  pos.* += 4;
  return v;
}

fn rdU64(bytes: []const u8, pos: *usize) !u32 {
  if (pos.* + 4 > bytes.len) return error.UnexpectedEof;
  const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
  pos.* += 4;
  return v;
}

fn rdStr(alloc: Alloc, bytes: []const u8, pos: *usize) ![]u8 {
  const len = try rdU32(bytes, pos);
  if (pos.* + len > bytes.len) return error.UnexpectedEof;
  const s = try alloc.dupe(u8, bytes[pos.*..][0..len]);
  pos.* += len;
  return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(alloc: Alloc, pool: *Pool, v: V) !V {
  const bytes = try serialize(alloc, pool, v);
  defer bytes.deinit(alloc);
  return deserialize(alloc, pool, bytes.C.slice());
}

test "binary round-trip: blank" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const got = try roundTrip(alloc, &pool, .blank);
  defer got.deinit(alloc);
  try testing.expect(got.tag() == .blank);
}

test "binary round-trip: bool atom" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  for ([_]bool{ true, false }) |b| {
    const got = try roundTrip(alloc, &pool, .{ .b = b });
    defer got.deinit(alloc);
    try testing.expectEqual(b, got.b);
  }
}

test "binary round-trip: integer atom" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  for ([_]i32{ 0, 1, -1, 42, V.@"0N" }) |i| {
    const got = try roundTrip(alloc, &pool, .{ .i = i });
    defer got.deinit(alloc);
    try testing.expectEqual(i, got.i);
  }
}

test "binary round-trip: float atom" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  for ([_]f32{ 0.0, 1.0, -1.5, 3.14 }) |f| {
    const got = try roundTrip(alloc, &pool, .{ .f = f });
    defer got.deinit(alloc);
    try testing.expectEqual(f, got.f);
  }
}

test "binary round-trip: symbol atom" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const idx = try pool.intern("hello");
  const got = try roundTrip(alloc, &pool, .{ .s = idx });
  defer got.deinit(alloc);
  try testing.expectEqualStrings("hello", pool.get(got.s));
}

test "binary round-trip: char atom" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const got = try roundTrip(alloc, &pool, .{ .c = 'A' });
  defer got.deinit(alloc);
  try testing.expectEqual(@as(u32, 'A'), got.c);
}

test "binary round-trip: integer vector" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const v = try V.Ints(alloc, &.{ 1, 2, 3 });
  defer v.deinit(alloc);
  const got = try roundTrip(alloc, &pool, v);
  defer got.deinit(alloc);
  try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, got.I.slice());
}

test "binary round-trip: float vector" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const v = try V.Floats(alloc, &.{ 1.0, 2.5, 3.0 });
  defer v.deinit(alloc);
  const got = try roundTrip(alloc, &pool, v);
  defer got.deinit(alloc);
  try testing.expectEqualSlices(f32, &.{ 1.0, 2.5, 3.0 }, got.F.slice());
}

test "binary round-trip: bool vector" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const bv = try N(bool).n1(alloc, &.{ true, false, true });
  defer bv.deinit(alloc);
  const got = try roundTrip(alloc, &pool, .{ .B = bv });
  defer got.deinit(alloc);
  try testing.expectEqualSlices(bool, &.{ true, false, true }, got.B.slice());
}

test "binary round-trip: char vector" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const v = try V.Chars(alloc, "hello");
  defer v.deinit(alloc);
  const got = try roundTrip(alloc, &pool, v);
  defer got.deinit(alloc);
  try testing.expectEqualSlices(u8, "hello", got.C.slice());
}

test "binary round-trip: symbol vector" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const ia = try pool.intern("a");
  const ib = try pool.intern("b");
  const ic = try pool.intern("c");
  const v = try V.Symbols(alloc, &.{ ia, ib, ic });
  defer v.deinit(alloc);
  const got = try roundTrip(alloc, &pool, v);
  defer got.deinit(alloc);
  try testing.expectEqualSlices(u32, &.{ ia, ib, ic }, got.S.slice());
}

test "binary round-trip: mixed list" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const items: []const V = &.{ .{ .i = 1 }, .{ .f = 2.0 }, .{ .b = true } };
  const v = try V.Values(alloc, items);
  defer v.deinit(alloc);
  const got = try roundTrip(alloc, &pool, v);
  defer got.deinit(alloc);
  const s = got.L.slice();
  try testing.expectEqual(@as(usize, 3), s.len);
  try testing.expectEqual(@as(i32, 1), s[0].i);
  try testing.expectEqual(@as(f32, 2.0), s[1].f);
  try testing.expectEqual(true, s[2].b);
}

test "binary round-trip: dict" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const ka = try pool.intern("a");
  const kb = try pool.intern("b");
  const keys = try V.Symbols(alloc, &.{ ka, kb });
  errdefer keys.deinit(alloc);
  const vals = try V.Ints(alloc, &.{ 10, 20 });
  errdefer vals.deinit(alloc);
  const d = V{ .m = try Dict.init(alloc, keys, vals) };
  defer d.deinit(alloc);
  const got = try roundTrip(alloc, &pool, d);
  defer got.deinit(alloc);
  try testing.expect(got.tag() == .m);
  try testing.expectEqualSlices(u32, &.{ ka, kb }, got.m.av().S.slice());
  try testing.expectEqualSlices(i32, &.{ 10, 20 }, got.m.bv().I.slice());
}

test "binary deserialize: empty bytes returns domain error" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const got = try deserialize(alloc, &pool, "");
  try testing.expectEqual(V{ .err = .domain }, got);
}

test "binary deserialize: wrong version returns domain error" {
  const alloc = testing.allocator;
  var pool = Pool.init(alloc);
  defer pool.deinit();
  const got = try deserialize(alloc, &pool, &.{0xFF});
  try testing.expectEqual(V{ .err = .domain }, got);
}
