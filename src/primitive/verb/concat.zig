const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const K = @import("../../noun/class.zig").K;
const N = value.N;
const V = value.V;
const promote = @import("../promote.zig").promote; // for promote() via pub fn concat()

// Returns the shared vector kind if x and y have compatible base types, else null.
// e.g. .i+.I → .I,  .f+.f → .F,  .i+.f → null
fn vecKind(xk: K, yk: K) ?K {
  const xv: ?K = switch (xk) { .i, .I => .I, .f, .F => .F, .b, .B => .B, .s, .S => .S, .c, .C => .C, else => null };
  const yv: ?K = switch (yk) { .i, .I => .I, .f, .F => .F, .b, .B => .B, .s, .S => .S, .c, .C => .C, else => null };
  if (xv == null or yv == null or xv.? != yv.?) return null;
  return xv.?;
}

fn scalarT(comptime vk: K) type {
  return switch (vk) {
    .I => i32, .F => f32, .B => bool, .S => u32, .C => u8,
    else => @compileError("no scalar for " ++ @tagName(vk)),
  };
}
 
// Extract the atom value of a value known to be compatible with VK.
inline fn atomVal(comptime VK: K, v: V) scalarT(VK) {
  return switch (VK) {
    .I => v.i, .F => v.f, .B => v.b, .S => v.s, .C => @intCast(v.c),
    else => unreachable,
  };
}

// --- Public helpers ---

// Appends y to x: if y is a vector/list, its elements are merged; otherwise y is a single new element.
// Used by amend.zig for dict key/value extension.
pub fn concat(alloc: Alloc, x: V, y: V) V {
  const xl = if (x.tag().isVec() or x.tag() == .L) x.len() else 1;
  const yl = if (y.tag().isVec() or y.tag() == .L) y.len() else 1;
  const res = N(V).init(alloc, xl + yl) catch return V{ .err = .memory };
  for (0..xl) |i| res.slice()[i] = x.at(i);
  for (0..yl) |i| res.slice()[xl + i] = y.at(i);
  return promote(alloc, res);
}

pub fn apply(vm: *VM, x: V, y: V) V {
  const xk = x.tag();
  const yk = y.tag();

  // L + L: merge element arrays
  if (xk == .L and yk == .L) {
    const xl = x.L.ptr.len;
    const yl = y.L.ptr.len;
    const res = N(V).init(vm.alloc, xl + yl) catch return V{ .err = .memory };
    for (x.L.slice(), res.slice()[0..xl]) |v, *r| r.* = v.ref();
    for (y.L.slice(), res.slice()[xl..])  |v, *r| r.* = v.ref();
    return V{ .L = res };
  }
  // L + anything
  if (xk == .L) {
    const xl = x.L.ptr.len;
    const ylen: usize = if (yk.isVec()) y.len() else 1;
    const res = N(V).init(vm.alloc, xl + ylen) catch return V{ .err = .memory };
    for (x.L.slice(), res.slice()[0..xl]) |v, *r| r.* = v.ref();
    if (yk.isVec()) {
      for (0..ylen) |i| res.slice()[xl + i] = y.at(i);
    } else {
      res.slice()[xl] = y.ref();
    }
    return V{ .L = res };
  }
  // anything + L
  if (yk == .L) {
    const xlen: usize = if (xk.isVec()) x.len() else 1;
    const yl = y.L.ptr.len;
    const res = N(V).init(vm.alloc, xlen + yl) catch return V{ .err = .memory };
    if (xk.isVec()) {
      for (0..xlen) |i| res.slice()[i] = x.at(i);
    } else {
      res.slice()[0] = x.ref();
    }
    for (y.L.slice(), res.slice()[xlen..]) |v, *r| r.* = v.ref();
    return V{ .L = res };
  }

  // Homogeneous typed: same base type → typed vec result
  if (vecKind(xk, yk)) |vk| {
    const x_atom = xk.isAtom();
    const y_atom = yk.isAtom();
    switch (vk) {
      inline .I, .F, .B, .S, .C => |VK| {
        const T = comptime scalarT(VK);
        if (x_atom and y_atom) {
          const res = N(T).init(vm.alloc, 2) catch return V{ .err = .memory };
          res.slice()[0] = atomVal(VK, x);
          res.slice()[1] = atomVal(VK, y);
          return @unionInit(V, @tagName(VK), res);
        }
        if (x_atom) { // atom + vec
          const yv = @field(y, @tagName(VK));
          const res = N(T).init(vm.alloc, 1 + yv.ptr.len) catch return V{ .err = .memory };
          res.slice()[0] = atomVal(VK, x);
          @memcpy(res.slice()[1..], yv.slice());
          return @unionInit(V, @tagName(VK), res);
        }
        if (y_atom) { // vec + atom
          const xv = @field(x, @tagName(VK));
          const res = N(T).init(vm.alloc, xv.ptr.len + 1) catch return V{ .err = .memory };
          @memcpy(res.slice()[0..xv.ptr.len], xv.slice());
          res.slice()[xv.ptr.len] = atomVal(VK, y);
          return @unionInit(V, @tagName(VK), res);
        }
        // vec + vec
        const xv = @field(x, @tagName(VK));
        const yv = @field(y, @tagName(VK));
        const res = N(T).init(vm.alloc, xv.ptr.len + yv.ptr.len) catch return V{ .err = .memory };
        @memcpy(res.slice()[0..xv.ptr.len], xv.slice());
        @memcpy(res.slice()[xv.ptr.len..],  yv.slice());
        return @unionInit(V, @tagName(VK), res);
      },
      else => unreachable,
    }
  }

  // Heterogeneous: 2-element list
  const res = N(V).init(vm.alloc, 2) catch return V{ .err = .memory };
  res.slice()[0] = x.ref();
  res.slice()[1] = y.ref();
  return V{ .L = res };
}
