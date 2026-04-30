const std = @import("std");
const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const N = value.N;
const V = value.V;
const K = @import("../../noun/class.zig").K;
const Alloc = std.mem.Allocator;
const assert = std.debug.assert;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

pub const Reshape = struct {
  pub const op = .@"#";
  _I_b: util.DyadFn = reshapeAtom(.b),
  _I_i: util.DyadFn = reshapeAtom(.i),
  _I_f: util.DyadFn = reshapeAtom(.f),
  _I_s: util.DyadFn = reshapeAtom(.s),
  _I_c: util.DyadFn = reshapeAtom(.c),

  _I_B: util.DyadFn = reshapeVec(.B),
  _I_I: util.DyadFn = reshapeVec(.I),
  _I_F: util.DyadFn = reshapeVec(.F),
  _I_S: util.DyadFn = reshapeVec(.S),
  _I_C: util.DyadFn = reshapeVec(.C),

  _I_L: util.DyadFn = reshapeListFn,
};

// atom y: output type is known at comptime as k.container(), no promote needed
fn reshapeAtom(comptime k: K) util.DyadFn {
  comptime assert(k.isAtom());
  return struct {
    const T   = K.backing(k);
    const RK = k.container();
    fn f(vm: *VM, x: V, y: V) !V {
      const shape = x.I.slice();
      if (shape.len == 0) return .{ .err = .rank };
      return fill(vm.alloc, shape, y.unwrap(k));
    }
    // recursive: 1D → typed vec, ND → L of typed rows
    fn fill(alloc: Alloc, shape: []const i32, val: T) !V {
      const n: usize = @intCast(shape[0]);
      if (shape.len == 1) {
        const vec = try N(T).init(alloc, n);
        @memset(vec.slice(), val);
        return @unionInit(V, @tagName(RK), vec);
      }
      const rows = try N(V).init(alloc, n);
      errdefer { for (rows.slice()) |r| r.deinit(alloc); rows.deinit(alloc); }
      for (rows.slice()) |*r| r.* = try fill(alloc, shape[1..], val);
      return .{ .L = rows };
    }
  }.f;
}

// vec y: output type is k, no promote needed — pre-flatten with cycling, then partition
fn reshapeVec(comptime k: K) util.DyadFn {
  comptime assert(k.isVec());
  return struct {
    const T = K.backing(k);
    fn f(vm: *VM, x: V, y: V) !V {
      const shape = x.I.slice();
      if (shape.len == 0) return .{ .err = .rank };
      const src: []const T = @field(y, @tagName(k)).slice();
      if (src.len == 0) return .{ .err = .length };
      var total: usize = 1;
      for (shape) |d| total *= @intCast(d);
      // build a flat cycled array, then partition without promote
      const flat = try vm.alloc.alloc(T, total);
      defer vm.alloc.free(flat);
      for (flat, 0..) |*e, i| e.* = src[i % src.len];
      return fromFlat(vm.alloc, shape, flat);
    }
    fn fromFlat(alloc: Alloc, shape: []const i32, flat: []const T) !V {
      const n: usize = @intCast(shape[0]);
      if (shape.len == 1) {
        const vec = try N(T).init(alloc, n);
        @memcpy(vec.slice(), flat[0..n]);
        return @unionInit(V, @tagName(k), vec);
      }
      var inner: usize = 1;
      for (shape[1..]) |d| inner *= @intCast(d);
      const rows = try N(V).init(alloc, n);
      errdefer { for (rows.slice()) |r| r.deinit(alloc); rows.deinit(alloc); }
      for (0..n) |i| rows.slice()[i] = try fromFlat(alloc, shape[1..], flat[i * inner ..]);
      return .{ .L = rows };
    }
  }.f;
}

// L y: heterogeneous, still needs promote
fn reshapeListFn(vm: *VM, x: V, y: V) !V {
  const shape = x.I.slice();
  if (shape.len == 0) return .{ .err = .rank };
  if (shape.len == 1) return reshapeListFlat(vm.alloc, @intCast(shape[0]), y);
  return reshapeListN(vm.alloc, shape, y);
}

fn reshapeListFlat(alloc: Alloc, n: usize, y: V) !V {
  const yn = y.len();
  const res = try N(V).init(alloc, n);
  @memset(res.slice(), .blank); // Set to blank or errdefer can fail
  errdefer { const tmp = V{ .L = res }; tmp.deinit(alloc); }
  for (0..n) |i| res.slice()[i] = y.at(i % yn);
  return try promote(alloc, res);
}

fn reshapeListN(alloc: Alloc, shape: []const i32, y: V) !V {
  const nrows: usize = @intCast(shape[0]);
  var inner_total: usize = 1;
  for (shape[1..]) |d| inner_total *= @intCast(d);
  const total = nrows * inner_total;
  const yn = y.len();

  const flat = try N(V).init(alloc, total);
  @memset(flat.slice(), .blank); // Set to blank or errdefer can fail
  for (0..total) |i| flat.slice()[i] = y.at(i % yn);

  const rows = try N(V).init(alloc, nrows);
  @memset(rows.slice(), .blank); // Set to blank or errdefer can fail
  errdefer {
    for (rows.slice()) |r| r.deinit(alloc);
    const tmp = V{ .L = rows }; tmp.deinit(alloc);
  }

  for (0..nrows) |i| {
    const offset = i * inner_total;
    const row = try N(V).init(alloc, inner_total);
    for (flat.slice()[offset .. offset + inner_total], 0..) |v, j| row.slice()[j] = v.ref();
    rows.slice()[i] = try promote(alloc, row);
  }

  for (flat.slice()) |v| v.deinit(alloc);
  flat.deinit(alloc);

  return try promote(alloc, rows);
}
