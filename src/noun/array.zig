const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("value.zig").V;
const Rc = @import("rc.zig").Rc;
const slabRound = @import("slab.zig").round;

pub const ArrayFlags = struct {
  pub const immutable: u8 = 1 << 0; // do not mutate in place even at rc=1
  pub const ascending: u8 = 1 << 1; // elements are sorted ascending
  pub const distinct:  u8 = 1 << 2; // no duplicate elements
  pub const boolean:   u8 = 1 << 3; // all values are 0 or 1
};

pub fn N(comptime T: type) type {
  return struct {
    const Self = @This();
    pub const alignment = @max(@alignOf(Rc), @alignOf(T));
    pub const data_offset = std.mem.alignForward(usize, @sizeOf(Rc), @alignOf(T));
    const align_enum: std.mem.Alignment = @enumFromInt(@ctz(@as(usize, alignment)));

    ptr: *align(@alignOf(Rc)) Rc,

    pub fn init(alloc: Alloc, n: usize) !Self {
      const total = slabRound(data_offset + n * @sizeOf(T));
      const buf = try alloc.alignedAlloc(u8, align_enum, total);
      const header: *align(@alignOf(Rc)) Rc = @ptrCast(buf.ptr);
      const cap_n: u32 = @intCast((total - data_offset) / @sizeOf(T));
      header.* = .{ .rc = 1, .len = @intCast(n), .cap = cap_n };
      if (comptime T == bool) header.flags = ArrayFlags.boolean;
      return .{ .ptr = header };
    }

    // Like init but with explicit overcapacity; `min_cap` is rounded up to the
    // next allocator-friendly size (power-of-2 above 1024, slab class below)
    // so subsequent in-place appends are cheap.
    pub fn initWithCap(alloc: Alloc, n: usize, min_cap: usize) !Self {
      const target_cap = @max(n, min_cap);
      const requested = data_offset + target_cap * @sizeOf(T);
      const rounded = if (requested <= (1 << 10)) slabRound(requested)
                      else std.math.ceilPowerOfTwo(usize, requested) catch requested;
      const buf = try alloc.alignedAlloc(u8, align_enum, rounded);
      const header: *align(@alignOf(Rc)) Rc = @ptrCast(buf.ptr);
      const cap_n: u32 = @intCast((rounded - data_offset) / @sizeOf(T));
      header.* = .{ .rc = 1, .len = @intCast(n), .cap = cap_n };
      if (comptime T == bool) header.flags = ArrayFlags.boolean;
      return .{ .ptr = header };
    }

    pub fn setFlag(a: Self, f: u8) void { a.ptr.flags |= f; }
    pub fn hasFlag(a: Self, f: u8) bool { return a.ptr.flags & f != 0; }
    pub fn deinit(a: Self, alloc: Alloc) void {
      if (a.ptr.rc == std.math.maxInt(u32)) return;
      a.ptr.rc -= 1;
      if (a.ptr.rc != 0) return;
      if (T == V) for (a.slice()) |child| child.deinit(alloc);
      const total = data_offset + @as(usize, a.ptr.cap) * @sizeOf(T);
      const base: [*]u8 = @ptrCast(a.ptr);
      const buf: []align(alignment) u8 = @as([*]align(alignment) u8, @alignCast(base))[0..total];
      alloc.free(buf);
    }

    // Raw pointer to the data region; positions [len, cap) are valid storage
    // but uninitialised. Callers must hold rc==1.
    pub fn dataPtr(a: Self) [*]T {
      const base: [*]u8 = @ptrCast(a.ptr);
      return @as([*]T, @ptrCast(@alignCast(base + data_offset)));
    }
    pub fn slice(a: Self) []T {
      const base: [*]u8 = @ptrCast(a.ptr);
      return @as([*]T, @ptrCast(@alignCast(base + data_offset)))[0..a.ptr.len];
    }
    pub fn eq(a: Self, b: Self) bool {
      if (a.ptr.len != b.ptr.len) return false;
      if (T == V) {
        for (a.slice(), b.slice()) |v1, v2| if (!v1.eq(v2)) return false; return true;
      }
      return std.mem.eql(T, a.slice(), b.slice());
    }
    pub fn clone(a: Self, alloc: Alloc) !Self {
      const next = try Self.init(alloc, a.ptr.len);
      if (T == V) {
        for (a.slice(), next.slice()) |src, *dst| dst.* = src.ref();
      } else @memcpy(next.slice(), a.slice());
      return next;
    }
    pub fn n1(alloc: Alloc, x: []const T) !Self {
      const n = try Self.init(alloc, x.len);
      if (T == V) {
        for (x, n.slice()) |src, *dst| dst.* = src.ref();
      } else @memcpy(n.slice(), x);
      return n;
    }
    pub fn fromSlice(alloc: Alloc, x: []const T) !Self {
      const n = try Self.init(alloc, x.len);
      @memcpy(n.slice(), x);
      return n;
    }
    pub fn fromRange(alloc: Alloc, start: T, step: T, count: usize) !Self {
      const res = try Self.init(alloc, count);
      var cur = start;
      for (res.slice()) |*val| { val.* = cur; cur += step; }
      if (comptime (T == i32 or T == u32 or T == f32)) {
        if (count > 0 and step > @as(T, 0)) res.ptr.flags |= ArrayFlags.ascending;
      }
      return res;
    }
    pub fn zeros(alloc: Alloc, count: usize) !Self {
      const res = try Self.init(alloc, count);
      @memset(res.slice(), if (T == V) .blank else std.mem.zeroes(T));
      return res;
    }
  };
}
