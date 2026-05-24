const std = @import("std");
const Alloc = std.mem.Allocator;
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Op = @import("../../runtime/tape.zig").Op;
const promote = @import("../promote.zig").promote;
const h = @import("helper.zig");

fn scalarT(comptime vk: K) type {
  return switch (vk) {
    .I => i32, .F => f32, .B => bool, .S => u32, .C => u8,
    else => @compileError("no scalar for " ++ @tagName(vk)),
  };
}

inline fn atomVal(comptime VK: K, v: V) scalarT(VK) {
  return switch (VK) {
    .I => v.i, .F => v.f, .B => v.b, .S => v.s, .C => @intCast(v.c),
    else => unreachable,
  };
}

// ── Per-combination kernel generators ────────────────────────────────────────

fn listMerge(vm: *VM, x: V, y: V) V {
  const xl = x.L.ptr.len;
  const yl = y.L.ptr.len;
  const res = N(V).init(vm.alloc, xl + yl) catch return V{ .err = .memory };
  for (x.L.slice(), res.slice()[0..xl]) |v, *r| r.* = v.ref();
  for (y.L.slice(), res.slice()[xl..])  |v, *r| r.* = v.ref();
  return V{ .L = res };
}

fn listWithRight(comptime yk: K) util.DyadFn {
  return &struct {
    fn f(vm: *VM, x: V, y: V) V {
      const xl = x.L.ptr.len;
      const ylen: usize = if (comptime yk.isVec()) y.len() else 1;
      const res = N(V).init(vm.alloc, xl + ylen) catch return V{ .err = .memory };
      for (x.L.slice(), res.slice()[0..xl]) |v, *r| r.* = v.ref();
      if (comptime yk.isVec()) {
        for (0..ylen) |i| res.slice()[xl + i] = y.at(i);
      } else {
        res.slice()[xl] = y.ref();
      }
      return V{ .L = res };
    }
  }.f;
}

fn leftWithList(comptime xk: K) util.DyadFn {
  return &struct {
    fn f(vm: *VM, x: V, y: V) V {
      const xlen: usize = if (comptime xk.isVec()) x.len() else 1;
      const yl = y.L.ptr.len;
      const res = N(V).init(vm.alloc, xlen + yl) catch return V{ .err = .memory };
      if (comptime xk.isVec()) {
        for (0..xlen) |i| res.slice()[i] = x.at(i);
      } else {
        res.slice()[0] = x.ref();
      }
      for (y.L.slice(), res.slice()[xlen..]) |v, *r| r.* = v.ref();
      return V{ .L = res };
    }
  }.f;
}

// Same-base-type pair: atom+atom → vec, atom+vec → vec, vec+atom → vec, vec+vec → vec.
fn homoKernel(comptime xk: K, comptime yk: K) util.DyadFn {
  const VK: K = @enumFromInt((@intFromEnum(xk) & ~@as(u8, K.VEC_BIT)) | K.VEC_BIT);
  const T = K.backing(VK);
  return &struct {
    fn f(vm: *VM, x: V, y: V) V {
      if (comptime xk.isAtom() and yk.isAtom()) {
        const res = N(T).init(vm.alloc, 2) catch return V{ .err = .memory };
        res.slice()[0] = atomVal(VK, x);
        res.slice()[1] = atomVal(VK, y);
        return @unionInit(V, @tagName(VK), res);
      } else if (comptime xk.isAtom()) {
        const yv = @field(y, @tagName(VK));
        const res = N(T).init(vm.alloc, 1 + yv.ptr.len) catch return V{ .err = .memory };
        res.slice()[0] = atomVal(VK, x);
        @memcpy(res.slice()[1..], yv.slice());
        return @unionInit(V, @tagName(VK), res);
      } else if (comptime yk.isAtom()) {
        const xv = @field(x, @tagName(VK));
        const res = N(T).init(vm.alloc, xv.ptr.len + 1) catch return V{ .err = .memory };
        @memcpy(res.slice()[0..xv.ptr.len], xv.slice());
        res.slice()[xv.ptr.len] = atomVal(VK, y);
        return @unionInit(V, @tagName(VK), res);
      } else {
        const xv = @field(x, @tagName(VK));
        const yv = @field(y, @tagName(VK));
        const res = N(T).init(vm.alloc, xv.ptr.len + yv.ptr.len) catch return V{ .err = .memory };
        @memcpy(res.slice()[0..xv.ptr.len], xv.slice());
        @memcpy(res.slice()[xv.ptr.len..],  yv.slice());
        return @unionInit(V, @tagName(VK), res);
      }
    }
  }.f;
}

fn heteroConcat(vm: *VM, x: V, y: V) V {
  const res = N(V).init(vm.alloc, 2) catch return V{ .err = .memory };
  res.slice()[0] = x.ref();
  res.slice()[1] = y.ref();
  return V{ .L = res };
}

fn getConcatKernel(comptime xk: K, comptime yk: K) util.DyadFn {
  if (xk == .L and yk == .L) return &listMerge;
  if (xk == .L) return listWithRight(yk);
  if (yk == .L) return leftWithList(xk);
  const x_base = @intFromEnum(xk) & ~@as(u8, K.VEC_BIT);
  const y_base = @intFromEnum(yk) & ~@as(u8, K.VEC_BIT);
  if (x_base == y_base and x_base >= 2 and x_base <= 6) return homoKernel(xk, yk);
  return &heteroConcat;
}

// ── Concat struct ─────────────────────────────────────────────────────────────

// Excludes .m and .M — those are handled by DictMerge and Insert.
const concat_types = blk: {
  const fields = @typeInfo(K).@"enum".fields;
  var ts: [fields.len - 2]K = undefined;
  var n: usize = 0;
  for (fields) |f| {
    const k: K = @enumFromInt(f.value);
    if (k != .m and k != .M) { ts[n] = k; n += 1; }
  }
  break :blk ts;
};

fn makeConcat() type {
  const op_default: Op = .@",";
  var names: []const []const u8 = &.{ "op" };
  var field_types: []const type = &.{ Op };
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (concat_types) |xk| {
    for (concat_types) |yk| {
      const handler: util.DyadFn = getConcatKernel(xk, yk);
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{util.DyadFn};
      const attr: h.Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const Concat = makeConcat();

// ── Public helpers ────────────────────────────────────────────────────────────

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
