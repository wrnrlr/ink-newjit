const std = @import("std");
const Alloc = std.mem.Allocator;
const util = @import("../util.zig");
const calc = @import("verb/calc.zig");
const concat = @import("verb/concat.zig");
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const VM = @import("../runtime/vm.zig").VM;
const Call = @import("../runtime/call.zig").Call;

// const Amend3 = struct {
//   _I_i_f: util.TriadFn,
//   _I_I_f: util.TriadFn,
// };

// const Amend4 = struct {
//   _I_i_f_i: util.TetradFn,
//   _I_I_f_i: util.TetradFn,
// };

pub fn amend(vm: *VM, args: []V) anyerror!V {
  if (args.len < 3) return V{ .err = .rank };

  var target = args[0].ref();
  errdefer target.deinit(vm.alloc);

  const indices = args[1];
  const func = args[2];
  const val = if (args.len > 3) args[3] else .blank;

  try target.cow(vm.alloc);

  if (indices.isAtom()) {
    try applyAt(vm, &target, indices, func, val.ref());
  } else if (indices.tag().isVec()) {
    const ilen = indices.len();
    const vlen = if (val.tag() == .blank) 0 else val.len();
    const val_is_plural = val.tag().isVec();

    for (0..ilen) |i| {
      const idx_v = indices.at(i);
      defer idx_v.deinit(vm.alloc);

      const item_val = if (val.tag() != .blank and val_is_plural and vlen == ilen)
        val.at(i)
      else
        val.ref();
      
      try applyAt(vm, &target, idx_v, func, item_val);
    }
  } else {
    return V{ .err = .@"type" };
  }

  return target;
}

pub fn dmend(vm: *VM, args: []V) anyerror!V {
  if (args.len < 2) return V{ .err = .rank };

  const target = args[0].ref();
  const path = args[1];
  const func = if (args.len > 2) args[2] else .blank;
  const val = if (args.len > 3) args[3] else .blank;

  return try drill(vm, target, path, 0, func, val);
}

fn drill(vm: *VM, target: V, path: V, path_idx: usize, func: V, val: V) anyerror!V {
  errdefer target.deinit(vm.alloc);

  const path_len = if (path.tag() == .blank) 0 else path.len();
  if (path_idx == path_len) {
    if (func.tag() == .blank) return target;
    
    // Identity assignment optimization at leaf
    if (func.tag() == .func and func.func.getKind() == .builtin and func.func.getOp() == .@":") {
      target.deinit(vm.alloc);
      return val.ref();
    }

    var fc = Call{ .vm = vm };
    const f_args = if (val.tag() == .blank) &[_]V{target} else &[_]V{target, val};
    const result = try fc.apply(func, f_args, false);
    target.deinit(vm.alloc);
    return result;
  }

  var mut_target = target;
  try mut_target.cow(vm.alloc);

  const key = path.at(path_idx);
  defer key.deinit(vm.alloc);

  const old_item = if (mut_target.isDict()) blk: {
    const d = mut_target.m;
    var found_idx: ?usize = null;
    const dav = d.av();
    for (0..dav.len()) |i| {
      const k = dav.at(i);
      defer k.deinit(vm.alloc);
      if (k.eq(key)) { found_idx = i; break; }
    }
    break :blk if (found_idx) |idx| d.bv().at(idx) else .blank;
  } else blk: {
    const i = try asIndex(key, mut_target.len());
    break :blk mut_target.at(i);
  };

  const new_item = try drill(vm, old_item, path, path_idx + 1, func, val);
  try setAt(vm, &mut_target, key, new_item);

  return mut_target;
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

  if (func.tag() == .func and func.func.getKind() == .builtin and func.func.getOp() == .@":") {
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
    break :blk if (found_idx) |idx| d.bv().at(idx) else .blank;
  } else blk: {
    const i = try asIndex(key, target.len());
    break :blk target.at(i);
  };
  defer current.deinit(vm.alloc);

  var fc = Call{ .vm = vm };
  const f_args = if (val.tag() == .blank) &[_]V{current} else &[_]V{current, val};
  const result = try fc.apply(func, f_args, false);
  val.deinit(vm.alloc);
  try setAt(vm, target, key, result);
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
      const new_a = concat.concat(vm.alloc, d.av(), key);
      const new_b = concat.concat(vm.alloc, d.bv(), val);
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

  if (needs_promotion) {
    try promoteToGeneralList(alloc, target);
  }

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

fn promoteToGeneralList(alloc: Alloc, target: *V) !void {
  const t = target.*;
  const len = t.len();
  const next = try N(V).init(alloc, len);
  for (0..len) |i| {
    next.slice()[i] = t.at(i);
  }
  t.deinit(alloc);
  target.* = .{ .L = next };
}
