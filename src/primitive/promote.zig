const std = @import("std");
const value = @import("../noun/value.zig");
const Alloc = std.mem.Allocator;
const K = @import("../noun/class.zig").K;
const V = value.V;
const N = value.N;

const promotable = [_]K{ .b, .i, .f, .s, .c };

fn castAtom(comptime tk: K, v: V) tk.backing() {
  return switch (tk) {
    .b => V.unwrap(v, .b),
    .i => switch (v) {
      .b => |b| @intFromBool(b),
      .i => |x| x,
      else => unreachable,
    },
    .f => switch (v) {
      .b => |b| @as(f32, if (b) 1 else 0),
      .i => |x| @as(f32, @floatFromInt(x)),
      .f => |x| x,
      else => unreachable,
    },
    .s => V.unwrap(v, .s),
    .c => V.unwrap(v, .c),
    else => @compileError("not a promotable scalar"),
  };
}

pub fn promote(alloc: Alloc, n: N(V)) V {
  const slice = n.slice();
  if (slice.len == 0) return V{ .L = n };
  var target: ?K = null;
  for (slice) |v| {
    const k = v.tag();
    if (k == .err) { n.deinit(alloc); return v; }
    if (!k.isAtom()) return V{ .L = n };
    if (target == null) target = k;
    const t = target.?;
    if (t == k) continue;
    if (t.isNumeric() or t == .b and k.isNumeric() or k == .b) {
      if (t.isFloat() or k.isFloat()) target = .f else target = .i;
    } else return V{ .L = n };
  }
  inline for (promotable) |tk| {
    if (target.? == tk) {
      var res = N(tk.backing()).init(alloc, slice.len) catch { n.deinit(alloc); return V{ .err = .memory }; };
      for (slice, 0..) |v, i| res.slice()[i] = castAtom(tk, v);
      n.deinit(alloc);
      return V.wrap(tk.container(), res);
    }
  }
  return V{ .L = n };
}
