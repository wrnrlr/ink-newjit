const value = @import("../noun/value.zig");
const Op = @import("../runtime/tape.zig").Op;
const syms = @import("../runtime/syms.zig");
const util = @import("../util.zig");
const verbs = @import("verb/verbs.zig");
const concat = @import("verb/concat.zig");
const pair = @import("verb/pair.zig");
const promote = @import("promote.zig").promote;
const VM = @import("../runtime/vm.zig").VM;
const Call = @import("../runtime/call.zig").Call;
const K = @import("../noun/class.zig").K;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const Dict = @import("../noun/dict.zig").Dict;

pub fn dispatch1(vm: *VM, op: Op, x: V) V {
  const xt = x.tag();
  const key = op.code() * K.COUNT + xt.code();
  if (verbs.monad_table[key]) |f| return f(vm, x);
  return switch (xt) {
    .m => fallbackDict(vm, op, x.m.av(), x.m.bv(), .m),
    .M => fallbackDict(vm, op, x.M.av(), x.M.bv(), .M),
    .L => fallbackList(vm, op, x),
    else => .{ .err = .@"type" }
  };
}

pub fn dispatch2(vm: *VM, op: Op, x: V, y: V) V {
  const xt = x.tag();
  const yt = y.tag();
  const key = op.code() * K.COUNT * K.COUNT + xt.code() * K.COUNT + yt.code();
  if (verbs.dyad_table[key]) |f| return f(vm, x, y);
  if (op == .@",") return concat.apply(vm, x, y);
  if (op == .@"!") return pair.dict(vm, x, y);
  if (op == .@"~") return .{ .b = x.eq(y) };
  if (xt == .L or yt == .L or x.isDict() or y.isDict()) return listDyad(vm, op, x, y);
  if (op == .@"@" and xt == .s) return syms.apply(vm, x.s, &.{y}) catch V{ .err = .memory };
  if (op == .@"@" and (xt == .func or xt == .partial)) {
    var fc = Call{ .vm = vm };
    return fc.apply(x, &.{y}, false) catch V{ .err = .memory };
  }
  return .{ .err = .@"type" };
}

fn fallbackDict(vm: *VM, op: Op, av: V, bv: V, comptime k: K) V {
  const r = dispatch1(vm, op, bv);
  if (r.tag() == .err) return r;
  return V.wrap(k, Dict.init(vm.alloc, av.ref(), r) catch {
    r.deinit(vm.alloc);
    return V{ .err = .memory };
  });
}

fn fallbackList(vm: *VM, op: Op, x: V) V {
  // TODO cow?
  const n = x.len();
  const res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  @memset(res.slice(), .blank);

  for (res.slice(), 0..) |*r, i| {
    const val = x.at(i);
    defer val.deinit(vm.alloc);
    const rv = dispatch1(vm, op, val);
    if (rv.tag() == .err) {
      (V{ .L = res }).deinit(vm.alloc);
      return rv;
    }
    r.* = rv;
  }
  return V{ .L = res };
}

fn listDyad(vm: *VM, op: Op, x: V, y: V) V {
  if (x.isDict() or y.isDict()) {
    if (x.isDict() and y.isDict()) {
      const x_av = switch (x) { .m => |d| d.av(), .M => |d| d.av(), else => unreachable };
      const y_av = switch (y) { .m => |d| d.av(), .M => |d| d.av(), else => unreachable };
      if (!x_av.eq(y_av)) return V{ .err = .length };
      const x_bv = switch (x) { .m => |d| d.bv(), .M => |d| d.bv(), else => unreachable };
      const y_bv = switch (y) { .m => |d| d.bv(), .M => |d| d.bv(), else => unreachable };
      const vals = dispatch2(vm, op, x_bv, y_bv);
      if (vals.tag() == .err) return vals;
      return switch (x) {
        .m => V{ .m = Dict.init(vm.alloc, x_av.ref(), vals) catch { vals.deinit(vm.alloc); return V{ .err = .memory }; } },
        .M => V{ .M = Dict.init(vm.alloc, x_av.ref(), vals) catch { vals.deinit(vm.alloc); return V{ .err = .memory }; } },
        else => unreachable,
      };
    }
    if (x.isDict()) {
      const x_av = switch (x) { .m => |d| d.av(), .M => |d| d.av(), else => unreachable };
      const x_bv = switch (x) { .m => |d| d.bv(), .M => |d| d.bv(), else => unreachable };
      const vals = dispatch2(vm, op, x_bv, y);
      if (vals.tag() == .err) return vals;
      return switch (x) {
        .m => V{ .m = Dict.init(vm.alloc, x_av.ref(), vals) catch { vals.deinit(vm.alloc); return V{ .err = .memory }; } },
        .M => V{ .M = Dict.init(vm.alloc, x_av.ref(), vals) catch { vals.deinit(vm.alloc); return V{ .err = .memory }; } },
        else => unreachable,
      };
    }
    const y_av = switch (y) { .m => |d| d.av(), .M => |d| d.av(), else => unreachable };
    const y_bv = switch (y) { .m => |d| d.bv(), .M => |d| d.bv(), else => unreachable };
    const vals = dispatch2(vm, op, x, y_bv);
    if (vals.tag() == .err) return vals;
    return switch (y) {
      .m => V{ .m = Dict.init(vm.alloc, y_av.ref(), vals) catch { vals.deinit(vm.alloc); return V{ .err = .memory }; } },
      .M => V{ .M = Dict.init(vm.alloc, y_av.ref(), vals) catch { vals.deinit(vm.alloc); return V{ .err = .memory }; } },
      else => unreachable,
    };
  }
  const xn = x.len();
  const yn = y.len();
  const n = if (xn == 1) yn else if (yn == 1) xn else if (xn == yn) xn else return V{ .err = .length };
  const res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  @memset(res.slice(), .blank);

  for (res.slice(), 0..) |*r, i| {
    const xv = if (xn == 1) x.ref() else x.at(i);
    defer xv.deinit(vm.alloc);
    const yv = if (yn == 1) y.ref() else y.at(i);
    defer yv.deinit(vm.alloc);
    const rv = dispatch2(vm, op, xv, yv);
    if (rv.tag() == .err) {
      (V{ .L = res }).deinit(vm.alloc);
      return rv;
    }
    r.* = rv;
  }
  return promote(vm.alloc, res);
}
