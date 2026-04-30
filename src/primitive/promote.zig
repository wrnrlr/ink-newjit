const std = @import("std");
const value = @import("../noun/value.zig");
const VM = @import("../runtime/vm.zig").VM;
const Alloc = std.mem.Allocator;
const K = @import("../noun/class.zig").K;
const V = value.V;
const N = value.N;

pub fn promote(alloc: Alloc, n: N(V)) !V {
  const slice = n.slice();
  if (slice.len == 0) return V{ .L = n };
  var target: ?K = null;
  for (slice) |v| {
    const k = v.tag();
    if (k == .err) {
      n.deinit(alloc);
      return v;
    }
    if (!k.isAtom()) return V{ .L = n };
    if (target == null) {
      target = k;
    } else {
      const t = target.?;
      if (t == k) continue;
      const t_num = t.isNumeric() or t == .b;
      const k_num = k.isNumeric() or k == .b;
      if (t_num and k_num) {
        if (t.isFloat() or k.isFloat()) target = .f else target = .i;
      } else return V{ .L = n };
    }
  }
  errdefer n.deinit(alloc);
  switch (target.?) {
    .b => {
      var res = try N(bool).init(alloc, slice.len);
      for (slice, 0..) |v, i| res.slice()[i] = v.b;
      n.deinit(alloc);
      return .{ .B = res };
    },
    .i => {
      var res = try N(i32).init(alloc, slice.len);
      for (slice, 0..) |v, i| {
        const tag = v.tag();
        res.slice()[i] = if (tag == .i) v.i else if (tag == .b) @intFromBool(v.b) else 0;
      }
      n.deinit(alloc);
      return .{ .I = res };
    },
    .f => {
      var res = try N(f32).init(alloc, slice.len);
      for (slice, 0..) |v, i| {
        const tag = v.tag();
        res.slice()[i] = if (tag == .f) v.f else if (tag == .i) @as(f32, @floatFromInt(v.i)) else @as(f32, if (v.b) 1 else 0);
      }
      n.deinit(alloc);
      return .{ .F = res };
    },
    .s => {
      var res = try N(u32).init(alloc, slice.len);
      for (slice, 0..) |v, i| res.slice()[i] = v.s;
      n.deinit(alloc);
      return .{ .S = res };
    },
    .c => {
      var res = try N(u8).init(alloc, slice.len);
      for (slice, 0..) |v, i| res.slice()[i] = @intCast(v.c);
      n.deinit(alloc);
      return .{ .C = res };
    },
    else => return V{ .L = n },
  }
}
