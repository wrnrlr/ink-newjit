const std = @import("std");
const Alloc = std.mem.Allocator;
const util = @import("../util.zig");
const promote = @import("promote.zig").promote;
const opmod = @import("../noun/operator.zig");
const V = @import("../noun/value.zig").V;
const K = @import("../noun/class.zig").K;
const N = @import("../noun/array.zig").N;
const VM = @import("../runtime/vm.zig").VM;
const Call = @import("../runtime/call.zig").Call;

fn Amend3Vec(comptime k: K) type {
  const rt = k.atom();
  const T = K.backing(k);
  return struct {
    fn single(vm: *VM, a: N(T), idx: i32, f: V) !void {
      const s = a.slice();
      const i: usize = @intCast(idx);
      var fc = Call{ .vm = vm };
      const res = fc.apply(f, &[_]V{V.wrap(rt, s[i])}, false);
      if (res.tag() != rt) { res.deinit(vm.alloc); return error.Domain; }
      s[i] = V.unwrap(res, rt);
    }
    fn multiple(vm: *VM, a: N(T), ix: N(i32), f: V) !void {
      const s = a.slice();
      var fc = Call{ .vm = vm };
      for (ix.slice()) |raw_i| {
        const i: usize = @intCast(raw_i);
        const res = fc.apply(f, &[_]V{V.wrap(rt, s[i])}, false);
        if (res.tag() != rt) { res.deinit(vm.alloc); return error.Domain; }
        s[i] = V.unwrap(res, rt);
      }
    }
  };
}

fn Amend4Vec(comptime k: K) type {
  const rt = k.atom();
  const T = K.backing(k);
  return struct {
    fn single(vm: *VM, a: N(T), idx: i32, f: V, b: V) !void {
      const s = a.slice();
      const i: usize = @intCast(idx);
      var fc = Call{ .vm = vm };
      const res = fc.apply(f, &[_]V{ V.wrap(rt, s[i]), b }, false);
      if (res.tag() != rt) { res.deinit(vm.alloc); return error.Domain; }
      s[i] = V.unwrap(res, rt);
    }
    fn multiple(vm: *VM, a: N(T), ix: N(i32), f: V, b: V) !void {
      const s = a.slice();
      const b_is_vec = b.isVec() and b.len() == ix.slice().len;
      var fc = Call{ .vm = vm };
      for (ix.slice(), 0..) |raw_i, n| {
        const i: usize = @intCast(raw_i);
        const bv = if (b_is_vec) b.at(n) else b.ref();
        defer bv.deinit(vm.alloc);
        const res = fc.apply(f, &[_]V{ V.wrap(rt, s[i]), bv }, false);
        if (res.tag() != rt) { res.deinit(vm.alloc); return error.Domain; }
        s[i] = V.unwrap(res, rt);
      }
    }
  };
}

const AmendList3 = struct {
  fn single(vm: *VM, a: N(V), idx: i32, f: V) !void {
    const s = a.slice();
    const i: usize = @intCast(idx);
    var fc = Call{ .vm = vm };
    const new_val = fc.apply(f, &[_]V{s[i]}, false);
    if (new_val.tag() == .err) return error.Domain;
    s[i].deinit(vm.alloc);
    s[i] = new_val;
  }
  fn multiple(vm: *VM, a: N(V), ix: N(i32), f: V) !void {
    const s = a.slice();
    var fc = Call{ .vm = vm };
    for (ix.slice()) |raw_i| {
      const i: usize = @intCast(raw_i);
      const new_val = fc.apply(f, &[_]V{s[i]}, false);
      if (new_val.tag() == .err) return error.Domain;
      s[i].deinit(vm.alloc);
      s[i] = new_val;
    }
  }
};

const AmendList4 = struct {
  fn single(vm: *VM, a: N(V), idx: i32, f: V, b: V) !void {
    const s = a.slice();
    const i: usize = @intCast(idx);
    var fc = Call{ .vm = vm };
    const new_val = fc.apply(f, &[_]V{ s[i], b }, false);
    if (new_val.tag() == .err) return error.Domain;
    s[i].deinit(vm.alloc);
    s[i] = new_val;
  }
  fn multiple(vm: *VM, a: N(V), ix: N(i32), f: V, b: V) !void {
    const s = a.slice();
    const b_is_vec = b.isVec() and b.len() == ix.slice().len;
    var fc = Call{ .vm = vm };
    for (ix.slice(), 0..) |raw_i, n| {
      const i: usize = @intCast(raw_i);
      const bv = if (b_is_vec) b.at(n) else b.ref();
      defer bv.deinit(vm.alloc);
      const new_val = fc.apply(f, &[_]V{ s[i], bv }, false);
      if (new_val.tag() == .err) return error.Domain;
      s[i].deinit(vm.alloc);
      s[i] = new_val;
    }
  }
};

const Amend3 = struct {
  const ints    = Amend3Vec(.I);
  const floats  = Amend3Vec(.F);
  const symbols = Amend3Vec(.S);
  const chars   = Amend3Vec(.C);
  const bools   = Amend3Vec(.B);
  const list    = AmendList3;
};

const Amend4 = struct {
  const ints    = Amend4Vec(.I);
  const floats  = Amend4Vec(.F);
  const symbols = Amend4Vec(.S);
  const chars   = Amend4Vec(.C);
  const bools   = Amend4Vec(.B);
  const list    = AmendList4;
};

fn amendMap(vm: *VM, a_in: V, indices: V, f: V, b: V) V {
  var a = a_in;
  if (indices.isAtom()) {
    applyAt(vm, &a, indices, f, b.ref()) catch |e| {
      a.deinit(vm.alloc);
      return if (e == error.TypeError) .{ .err = .@"type" } else .{ .err = .memory };
    };
  } else if (indices.isVec()) {
    const ilen = indices.len();
    const b_is_vec = b.isVec() and b.len() == ilen;
    for (0..ilen) |n| {
      const key = indices.at(n);
      defer key.deinit(vm.alloc);
      const bv = if (b_is_vec) b.at(n) else b.ref();
      applyAt(vm, &a, key, f, bv) catch |e| {
        a.deinit(vm.alloc);
        return if (e == error.TypeError) .{ .err = .@"type" } else .{ .err = .memory };
      };
    }
  } else {
    a.deinit(vm.alloc);
    return .{ .err = .@"type" };
  }
  return a;
}

pub fn amend(vm: *VM, args: []V) V {
  if (args.len < 3) return .{ .err = .rank };
  var a = args[0];
  const at = a.tag();
  if (!a.isVec() and !a.isDict() and at != .L) return .{ .err = .@"type" };

  a = a.ref();
  a.cow(vm.alloc) catch {
    a.deinit(vm.alloc);
    return .{ .err = .memory };
  };

  const idx = args[1];
  const f   = args[2];
  const atom_idx = idx.tag() == .i;
  if (!atom_idx and idx.tag() != .I) {
    a.deinit(vm.alloc);
    return .{ .err = .@"type" };
  }

  const applied: anyerror!void = if (args.len == 3) switch (at) {
    .I => if (atom_idx) Amend3.ints.single(vm, a.I, idx.i, f) else Amend3.ints.multiple(vm, a.I, idx.I, f),
    .F => if (atom_idx) Amend3.floats.single(vm, a.F, idx.i, f) else Amend3.floats.multiple(vm, a.F, idx.I, f),
    .S => if (atom_idx) Amend3.symbols.single(vm, a.S, idx.i, f) else Amend3.symbols.multiple(vm, a.S, idx.I, f),
    .C => if (atom_idx) Amend3.chars.single(vm, a.C, idx.i, f) else Amend3.chars.multiple(vm, a.C, idx.I, f),
    .B => if (atom_idx) Amend3.bools.single(vm, a.B, idx.i, f) else Amend3.bools.multiple(vm, a.B, idx.I, f),
    .L => if (atom_idx) Amend3.list.single(vm, a.L, idx.i, f) else Amend3.list.multiple(vm, a.L, idx.I, f),
    .m, .M => return amendMap(vm, a, idx, f, .blank),
    else => { a.deinit(vm.alloc); return .{ .err = .@"type" }; },
  } else if (args.len == 4) blk: {
    const b = args[3];
    break :blk switch (at) {
      .I => if (atom_idx) Amend4.ints.single(vm, a.I, idx.i, f, b) else Amend4.ints.multiple(vm, a.I, idx.I, f, b),
      .F => if (atom_idx) Amend4.floats.single(vm, a.F, idx.i, f, b) else Amend4.floats.multiple(vm, a.F, idx.I, f, b),
      .S => if (atom_idx) Amend4.symbols.single(vm, a.S, idx.i, f, b) else Amend4.symbols.multiple(vm, a.S, idx.I, f, b),
      .C => if (atom_idx) Amend4.chars.single(vm, a.C, idx.i, f, b) else Amend4.chars.multiple(vm, a.C, idx.I, f, b),
      .B => if (atom_idx) Amend4.bools.single(vm, a.B, idx.i, f, b) else Amend4.bools.multiple(vm, a.B, idx.I, f, b),
      .L => if (atom_idx) Amend4.list.single(vm, a.L, idx.i, f, b) else Amend4.list.multiple(vm, a.L, idx.I, f, b),
      .m, .M => return amendMap(vm, a, idx, f, b),
      else => { a.deinit(vm.alloc); return .{ .err = .@"type" }; },
    };
  } else {
    a.deinit(vm.alloc);
    return .{ .err = .rank };
  };
  applied catch { a.deinit(vm.alloc); return .{ .err = .domain }; };
  return a;
}

pub fn dmend(vm: *VM, args: []V) V {
  if (args.len < 2) return .{ .err = .rank };
  var target = args[0].ref();
  const path = args[1];
  const func = if (args.len > 2) args[2] else V{ .blank = {} };
  const val  = if (args.len > 3) args[3] else V{ .blank = {} };
  drill(vm, &target, path, 0, func, val) catch |e| {
    target.deinit(vm.alloc);
    return switch (e) {
      error.OutOfMemory => .{ .err = .memory },
      error.TypeError   => .{ .err = .@"type" },
      else              => .{ .err = .nyi },
    };
  };
  return target;
}

// Recurses along `path`, cow-ing each level, then applies func at the leaf.
// Caller owns *target and must deinit it on error.
fn drill(vm: *VM, target: *V, path: V, path_idx: usize, func: V, val: V) !void {
  const path_len = if (path.tag() == .blank) 0 else path.len();

  if (path_idx == path_len) {
    if (func.tag() == .blank) return;

    if (func.tag() == .func and func.func.isBuiltinFn() and opmod.isOp2Idx(func.func.idx) and func.func.getOp2() == .@":") {
      target.deinit(vm.alloc);
      target.* = val.ref();
      return;
    }

    const old = target.*;
    var fc = Call{ .vm = vm };
    const f_args = if (val.tag() == .blank) &[_]V{old} else &[_]V{old, val};
    target.* = fc.apply(func, f_args, false);
    old.deinit(vm.alloc);
    return;
  }

  try target.cow(vm.alloc);

  const key = path.at(path_idx);
  defer key.deinit(vm.alloc);

  var item = if (target.isDict()) blk: {
    const d = target.m;
    var found_idx: ?usize = null;
    const dav = d.av();
    for (0..dav.len()) |i| {
      const k = dav.at(i);
      defer k.deinit(vm.alloc);
      if (k.eq(key)) { found_idx = i; break; }
    }
    break :blk if (found_idx) |i| d.bv().at(i) else V{ .blank = {} };
  } else blk: {
    const i = try asIndex(key, target.len());
    break :blk target.at(i);
  };

  // On drill error we own item; on setAt error, setAt's errdefer owns it.
  drill(vm, &item, path, path_idx + 1, func, val) catch |e| {
    item.deinit(vm.alloc);
    return e;
  };
  try setAt(vm, target, key, item);
}

fn asIndex(v: V, max: usize) !usize {
  const i = switch (v) {
    .i => |val| val,
    .b => |val| if (val) @as(i32, 1) else 0,
    else => return error.InvalidIndex,
  };
  if (i < 0 or i >= @as(i32, @intCast(max))) return error.IndexOutOfBounds;
  return @intCast(i);
}

fn applyAt(vm: *VM, target: *V, key: V, func: V, val: V) !void {
  // val is owned by this function
  errdefer val.deinit(vm.alloc);

  if (func.tag() == .func and func.func.isBuiltinFn() and opmod.isOp2Idx(func.func.idx) and func.func.getOp2() == .@":") {
    try setAt(vm, target, key, val);
    return;
  }

  const current = if (target.isDict()) blk: {
    const d = target.m;
    var found_idx: ?usize = null;
    const dav = d.av();
    for (0..dav.len()) |i| {
      const k = dav.at(i);
      defer k.deinit(vm.alloc);
      if (k.eq(key)) { found_idx = i; break; }
    }
    break :blk if (found_idx) |i| d.bv().at(i) else .blank;
  } else blk: {
    const i = try asIndex(key, target.len());
    break :blk target.at(i);
  };
  defer current.deinit(vm.alloc);

  var fc = Call{ .vm = vm };
  const f_args = if (val.tag() == .blank) &[_]V{current} else &[_]V{current, val};
  const result = fc.apply(func, f_args, false);
  val.deinit(vm.alloc);
  try setAt(vm, target, key, result);
}

fn appendOne(alloc: Alloc, arr: V, val: V) V {
  const n = arr.len();
  const res = N(V).init(alloc, n + 1) catch return V{ .err = .memory };
  for (0..n) |i| res.slice()[i] = arr.at(i);
  res.slice()[n] = val.ref();
  return promote(alloc, res);
}

pub fn setAt(vm: *VM, target: *V, key: V, val: V) !void {
  // val is owned by this function
  errdefer val.deinit(vm.alloc);

  if (target.isDict()) {
    const d = target.m;
    var found_idx: ?usize = null;
    const dav = d.av();
    for (0..dav.len()) |i| {
      const k = dav.at(i);
      defer k.deinit(vm.alloc);
      if (k.eq(key)) { found_idx = i; break; }
    }

    if (found_idx) |idx| {
      try d.bvPtr().cow(vm.alloc);
      try setPositional(vm.alloc, d.bvPtr(), idx, val);
    } else {
      try d.avPtr().cow(vm.alloc);
      try d.bvPtr().cow(vm.alloc);
      const new_a = appendOne(vm.alloc, d.av(), key);
      const new_b = appendOne(vm.alloc, d.bv(), val);
      d.avPtr().deinit(vm.alloc);
      d.bvPtr().deinit(vm.alloc);
      d.avPtr().* = new_a;
      d.bvPtr().* = new_b;
      val.deinit(vm.alloc);
    }
  } else {
    const i = try asIndex(key, target.len());
    try setPositional(vm.alloc, target, i, val);
  }
}

fn setPositional(alloc: Alloc, target: *V, i: usize, val: V) !void {
  // val is owned by this function
  errdefer val.deinit(alloc);

  const target_kind = std.meta.activeTag(target.*);
  const val_kind = std.meta.activeTag(val);

  var needs_promotion = false;
  if (target_kind != .L) {
    if (val_kind == .L or val.tag().isVec()) {
      needs_promotion = true;
    } else {
      switch (target_kind) {
        .I => if (val_kind != .i) { needs_promotion = true; },
        .F => if (val_kind != .f) { needs_promotion = true; },
        .S => if (val_kind != .s) { needs_promotion = true; },
        .C => if (val_kind != .c) { needs_promotion = true; },
        .B => if (val_kind != .b) { needs_promotion = true; },
        else => {},
      }
    }
  }

  if (needs_promotion) return error.TypeError;

  switch (target.*) {
    .I => |n| { n.slice()[i] = val.i; val.deinit(alloc); },
    .F => |n| { n.slice()[i] = val.f; val.deinit(alloc); },
    .S => |n| { n.slice()[i] = val.s; val.deinit(alloc); },
    .C => |n| { n.slice()[i] = @intCast(val.c); val.deinit(alloc); },
    .B => |n| { n.slice()[i] = val.b; val.deinit(alloc); },
    .L => |n| { n.slice()[i].deinit(alloc); n.slice()[i] = val; },
    else => { val.deinit(alloc); return error.NotACollection; },
  }
}
