const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Alloc = std.mem.Allocator;
const assert = std.debug.assert;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

pub const Reshape = struct {
  pub const op = .@"#";
  _I_b: VM.DyadFn = reshapeAtom(.b),
  _I_i: VM.DyadFn = reshapeAtom(.i),
  _I_f: VM.DyadFn = reshapeAtom(.f),
  _I_s: VM.DyadFn = reshapeAtom(.s),
  _I_c: VM.DyadFn = reshapeAtom(.c),

  _I_B: VM.DyadFn = reshapeVec(.B),
  _I_I: VM.DyadFn = reshapeVec(.I),
  _I_F: VM.DyadFn = reshapeVec(.F),
  _I_S: VM.DyadFn = reshapeVec(.S),
  _I_C: VM.DyadFn = reshapeVec(.C),

  _I_L: VM.DyadFn = reshapeListFn,
};

// atom y: output type is known at comptime as k.container(), no promote needed
fn reshapeAtom(comptime k: K) VM.DyadFn {
  comptime assert(k.isAtom());
  return struct {
    const T   = K.backing(k);
    const RK = k.container();
    fn f(vm: *VM, x: V, y: V) V {
      const shape = x.I.slice();
      if (shape.len == 0) return .{ .err = .rank };
      return fill(vm.alloc, shape, y.unwrap(k));
    }
    // recursive: 1D → typed vec, ND → L of typed rows
    fn fill(alloc: Alloc, shape: []const i32, val: T) V {
      const n: usize = @intCast(shape[0]);
      if (shape.len == 1) {
        const vec = N(T).init(alloc, n) catch return V{ .err = .memory };
        @memset(vec.slice(), val);
        return @unionInit(V, @tagName(RK), vec);
      }
      const rows = N(V).init(alloc, n) catch return V{ .err = .memory };
      for (rows.slice()) |*r| r.* = fill(alloc, shape[1..], val);
      return .{ .L = rows };
    }
  }.f;
}

// vec y: output type is k, no promote needed — pre-flatten with cycling, then partition
fn reshapeVec(comptime k: K) VM.DyadFn {
  comptime assert(k.isVec());
  return struct {
    const T = K.backing(k);
    fn f(vm: *VM, x: V, y: V) V {
      const shape = x.I.slice();
      if (shape.len == 0) return .{ .err = .rank };
      const src: []const T = @field(y, @tagName(k)).slice();
      if (src.len == 0) return .{ .err = .length };
      var total: usize = 1;
      for (shape) |d| total *= @intCast(d);
      // build a flat cycled array, then partition without promote
      const flat = vm.alloc.alloc(T, total) catch return V{ .err = .memory };
      defer vm.alloc.free(flat);
      for (flat, 0..) |*e, i| e.* = src[i % src.len];
      return fromFlat(vm.alloc, shape, flat);
    }
    fn fromFlat(alloc: Alloc, shape: []const i32, flat: []const T) V {
      const n: usize = @intCast(shape[0]);
      if (shape.len == 1) {
        const vec = N(T).init(alloc, n) catch return V{ .err = .memory };
        @memcpy(vec.slice(), flat[0..n]);
        return @unionInit(V, @tagName(k), vec);
      }
      var inner: usize = 1;
      for (shape[1..]) |d| inner *= @intCast(d);
      const rows = N(V).init(alloc, n) catch return V{ .err = .memory };
      @memset(rows.slice(), .blank);
      for (0..n) |i| rows.slice()[i] = fromFlat(alloc, shape[1..], flat[i * inner ..]);
      return .{ .L = rows };
    }
  }.f;
}

// L y: heterogeneous, still needs promote
fn reshapeListFn(vm: *VM, x: V, y: V) V {
  const shape = x.I.slice();
  if (shape.len == 0) return .{ .err = .rank };
  if (shape.len == 1) return reshapeListFlat(vm.alloc, @intCast(shape[0]), y);
  return reshapeListN(vm.alloc, shape, y);
}

fn reshapeListFlat(alloc: Alloc, n: usize, y: V) V {
  const yn = y.len();
  const res = N(V).init(alloc, n) catch return V{ .err = .memory };
  for (0..n) |i| res.slice()[i] = y.at(i % yn);
  return promote(alloc, res);
}

fn reshapeListN(alloc: Alloc, shape: []const i32, y: V) V {
  const nrows: usize = @intCast(shape[0]);
  var inner_total: usize = 1;
  for (shape[1..]) |d| inner_total *= @intCast(d);
  const total = nrows * inner_total;
  const yn = y.len();

  const flat = N(V).init(alloc, total) catch return V{ .err = .memory };
  for (0..total) |i| flat.slice()[i] = y.at(i % yn);

  const rows = N(V).init(alloc, nrows) catch {
    (V{ .L = flat }).deinit(alloc);
    return V{ .err = .memory };
  };
  @memset(rows.slice(), .blank);

  for (0..nrows) |i| {
    const offset = i * inner_total;
    const row = N(V).init(alloc, inner_total) catch {
      (V{ .L = flat }).deinit(alloc);
      (V{ .L = rows }).deinit(alloc);
      return V{ .err = .memory };
    };
    for (flat.slice()[offset .. offset + inner_total], 0..) |v, j| row.slice()[j] = v.ref();
    rows.slice()[i] = promote(alloc, row);
  }

  for (flat.slice()) |v| v.deinit(alloc);
  flat.deinit(alloc);

  return promote(alloc, rows);
}
