const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayFlags = @import("array.zig").ArrayFlags;
const Fn = @import("operator.zig").Fn;
const Partial = @import("partial.zig").Partial;
const K = @import("class.zig").K;
const N = @import("array.zig").N;
const Dict = @import("dict.zig").Dict;
const ExtObj = @import("plugin.zig").ExtObj;

pub const Err = enum { domain, length, rank, nyi, memory, @"type", io };

pub const V = union(K) {
  blank, err: Err,
  b: bool, i: i32, f: f32, s: u32, c: u8,
  o: Fn, p: *Partial,
  L: N(V), m: Dict, M: Dict, x: *ExtObj,
  B: N(bool), I: N(i32), F: N(f32), S: N(u32), C: N(u8),

  pub const @"0N" = std.math.minInt(i32);
  pub inline fn wrap(comptime k: K, v: holder(k)) V { return @unionInit(V, @tagName(k), v); }
  pub inline fn unwrap(v: V, comptime k: K) holder(k) { return @field(v, @tagName(k)); }
  pub inline fn tag(v: V) K { return std.meta.activeTag(v); }
  pub fn isAtom(v: V) bool { return v.tag().isAtom(); }
  pub fn isVec(v: V) bool { return v.tag().isVec(); }
  pub fn isDict(v: V) bool { return switch (v.tag()) { .m, .M => true, else => false }; }
  pub fn isLambda(v: V) bool { return v == .o and v.o.isLambda(); }
  pub fn isPartial(v: V) bool { return v == .p; }
  pub fn asPartial(v: V) *Partial { return v.p; }
  pub fn Ints(alloc: Alloc, x: []const i32) !V { return .{ .I = try N(i32).n1(alloc, x) }; }
  pub fn Floats(alloc: Alloc, x: []const f32) !V { return .{ .F = try N(f32).n1(alloc, x) }; }
  pub fn Symbols(alloc: Alloc, x: []const u32) !V { return .{ .S = try N(u32).n1(alloc, x) }; }
  pub fn Chars(alloc: Alloc, x: []const u8) !V { return .{ .C = try N(u8).n1(alloc, x) }; }
  pub fn Values(alloc: Alloc, x: []const V) !V { return .{ .L = try N(V).n1(alloc, x) }; }
  
  fn holder(comptime k: K) type {
    return switch (k) {
      .blank => void,
      .b => bool, .B => N(bool),
      .i => i32, .I => N(i32),
      .f => f32, .F => N(f32),
      .s => u32, .S => N(u32),
      .c => u8, .C => N(u8),
      .m, .M => Dict,
      .L => V,
      else => @compileError("no backing type for " ++ @tagName(k)),
    };
  }
  
  pub fn ref(v: V) V {
    switch (v) {
      inline .I => |n| { if (n.ptr.rc != std.math.maxInt(u32)) n.ptr.rc += 1; },
      inline .B, .F, .S, .C, .L => |n| n.ptr.rc += 1,
      inline .m, .M => |n| n.ptr.rc += 1,
      .p => |p| p.rc += 1,
      .x => |obj| { _ = obj.ref(); },
      else => {},
    }
    return v;
  }

  pub fn deinit(v: V, alloc: Alloc) void {
    switch (v) {
      inline .B, .I, .F, .S, .C, .L, .m, .M => |n| n.deinit(alloc),
      .p => |p| p.deinit(alloc),
      .x => |obj| obj.deinit(alloc),
      else => {},
    }
  }

  pub fn cow(v: *V, alloc: Alloc) !void {
    switch (v.*) {
      inline .B, .I, .F, .S, .C, .L, .m, .M => |n, t| {
        if (n.ptr.rc > 1 or n.ptr.meta & ArrayFlags.immutable != 0) {
          const next = try n.clone(alloc);  // clone() → init() stamps a fresh epoch
          n.deinit(alloc);
          v.* = @unionInit(V, @tagName(t), next);
        } else {
          // In-place mutation about to happen on a uniquely-held value: bump its
          // version so change detection sees the write.
          n.ptr.stampEpoch();
        }
      },
      else => {},
    }
  }

  pub fn len(v: V) usize {
    return switch (v) {
      inline .B, .I, .F, .S, .C, .L => |n| n.ptr.len,
      inline .m => |n| n.ptr.len,
      inline .M => |n| {
        const bv = n.bv();
        if (bv.tag() == .L) {
          const slice = bv.L.slice();
          if (slice.len == 0) return 0;
          return slice[0].len();
        }
        return bv.len();
      },
      else => 1,
    };
  }

  pub fn eq(x: V, y: V) bool {
    const t = std.meta.activeTag(x);
    if (t != std.meta.activeTag(y)) return false;
    return switch (x) {
      .blank => true, .err => x.err == y.err,
      .b => x.b == y.b, .i => x.i == y.i, .f => x.f == y.f,
      .s => x.s == y.s, .c => x.c == y.c,
      .o => @as(u64, @bitCast(x.o)) == @as(u64, @bitCast(y.o)),
      .p => x.p == y.p, // pointer equality
      .x => x.x == y.x,                  // pointer equality
      inline else => |n| {
        const T = @TypeOf(n);
        inline for (std.meta.fields(V)) |f| {
          if (f.type == T) {
            if (t == @field(K, f.name)) return n.eq(@field(y, f.name));
          }
        }
        return false;
      },
    };
  }

  pub fn at(v: V, i: usize) V {
    return switch (v) {
      .B => |n| .{ .b = n.slice()[i] },
      .I => |n| .{ .i = n.slice()[i] },
      .F => |n| .{ .f = n.slice()[i] },
      .S => |n| .{ .s = n.slice()[i] },
      .C => |n| .{ .c = n.slice()[i] },
      .L => |n| n.slice()[i].ref(),
      inline .m, .M => |n| n.bv().at(i),
      else => v.ref(),
    };
  }

  pub fn arity(v: V) u8 {
    return switch (v) {
      .o => |r| r.getRealArity(),
      .p => |p| p.remaining(),
      .blank => 0,
      else => 1,
    };
  }

  pub fn isNull(v: V) bool {
    return switch (v) {
      .blank => false,
      inline .b, .i, .f, .s, .c => |a, kt| kt.isNullFn()(a),
      inline .B, .I, .F, .S, .C, .L => |n| n.ptr.len == 0,
      inline .m, .M => |n| n.ptr.len == 0,
      else => false,
    };
  }

  pub fn isTrue(v: V) bool {
    return switch (v) {
      .b => |a| a,
      .c => |a| a != 0, .s => |a| a != 0,
      .i => |a| a != 0 and a != @"0N", .f => |a| a != 0.0 and !std.math.isNan(a),
      inline .B, .I, .F, .S, .C, .L => |n| n.ptr.len > 0,
      inline .m, .M => |n| n.ptr.len > 0,
      .o, .p => true,
      else => false,
    };
  }

  pub fn rc(v: V) usize {
    return switch (v) {
      inline .B, .I, .F, .S, .C, .L => |n| n.ptr.rc,
      inline .m, .M => |n| n.ptr.rc,
      .p => |p| p.rc,
      .x => |obj| obj.rc,
      else => 1,
    };
  }
  
  pub fn make(comptime kk: K, comptime T: type, alloc: Alloc, vals: []const T) !V {
    return @unionInit(V, @tagName(kk), try N(T).n1(alloc, vals));
  }
};

test "V size" { try std.testing.expect(@sizeOf(V) <= 16); }

test "wrap" {
  try std.testing.expect(V.wrap(.b, true).b);
  try std.testing.expect(V.wrap(.i, 2).i == 2);
  try std.testing.expect(V.wrap(.f, 2.3).f == 2.3);
  try std.testing.expect(V.wrap(.c, 'A').c == 'A');
}

test "atoms" {
  const v1 = V{ .i = 42 }; const v2 = V{ .f = 3.14 };
  try std.testing.expect(v1.eq(v1)); try std.testing.expect(!v1.eq(v2));
}

test "vectors" {
  const alloc = std.testing.allocator;
  const v1 = try N(i32).n1(alloc, &.{1, 2, 3}); defer v1.deinit(alloc);
  const v2 = try N(i32).n1(alloc, &.{1, 2, 3}); defer v2.deinit(alloc);
  try std.testing.expect((V{ .I = v1 }).eq(.{ .I = v2 }));
}

test "ref counting" {
  const alloc = std.testing.allocator;
  const v1 = try N(i32).n1(alloc, &.{1, 2, 3});
  const V1 = V{ .I = v1 };
  try std.testing.expectEqual(@as(usize, 1), V1.rc());
  _ = V1.ref();
  try std.testing.expectEqual(@as(usize, 2), V1.rc());
  V1.deinit(alloc);
  try std.testing.expectEqual(@as(usize, 1), V1.rc());
  V1.deinit(alloc);
}
