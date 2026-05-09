const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../noun/class.zig").K;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;

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

/// Determine the common promotable kind for a slice of atoms.
/// Returns null if the slice is empty, contains a non-atom, or has incompatible types.
/// Does not check for .err — callers that need error propagation must check separately.
pub fn inferKind(slice: []const V) ?K {
  if (slice.len == 0) return null;
  var target = slice[0].tag();
  if (!target.isAtom()) return null;
  for (slice[1..]) |v| {
    const k = v.tag();
    if (!k.isAtom()) return null;
    if (target == k) continue;
    if (target.isNumeric() or target == .b and k.isNumeric() or k == .b) {
      if (target.isFloat() or k.isFloat()) target = .f else target = .i;
    } else return null;
  }
  return target;
}

/// Allocate a typed vector and cast all elements of n into kind k.
/// Caller guarantees inferKind already returned k for n's elements.
/// Takes ownership of n; deinits it on success or OOM.
pub fn promoteAs(alloc: Alloc, n: N(V), k: K) V {
  const slice = n.slice();
  inline for (promotable) |tk| {
    if (k == tk) {
      var res = N(tk.backing()).init(alloc, slice.len) catch { n.deinit(alloc); return V{ .err = .memory }; };
      for (slice, 0..) |v, i| res.slice()[i] = castAtom(tk, v);
      n.deinit(alloc);
      return V.wrap(tk.container(), res);
    }
  }
  unreachable; // k must be a promotable kind
}

pub fn promote(alloc: Alloc, n: N(V)) V {
  const slice = n.slice();
  for (slice) |v| if (v.tag() == .err) { n.deinit(alloc); return v; };
  if (inferKind(slice)) |k| return promoteAs(alloc, n, k);
  return V{ .L = n };
}
