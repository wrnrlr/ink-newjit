const std = @import("std");
const Alloc = std.mem.Allocator;
const promote = @import("promote.zig").promote;
const opmod = @import("../noun/operator.zig");
const V = @import("../noun/value.zig").V;
const K = @import("../noun/class.zig").K;
const N = @import("../noun/array.zig").N;
const VM = @import("../runtime/vm.zig").VM;
const Call = @import("../runtime/call.zig").Call;
const Dict = @import("../noun/dict.zig").Dict;
const insert = @import("verb/insert.zig");

// A dict (m) and a table (M) share the same Dict payload, so amend-by-key works for
// both — for a table the "keys" are column names, so amending a key replaces a column.
// The active union tag must NOT be assumed to be `.m`: accessing `.m` on an `.M` value
// is the wrong union field (a crash). This reads the Dict for whichever tag is active.
inline fn dictOf(v: V) Dict { return switch (v) { .m, .M => |d| d, else => unreachable }; }

fn Amend3Vec(comptime k: K) type {
  const rt = k.atom();
  const T = K.backing(k);
  return struct {
    fn single(vm: *VM, a: N(T), idx: i32, f: V) !void {
      const s = a.slice();
      const i: usize = @intCast(idx);
      var fc = Call{ .vm = vm };
      const res = fc.apply(f, &[_]V{V.wrap(rt, s[i])}, false);
      if (res.tag() != rt) { res.deinit(vm.alloc); return error.TypeError; }
      s[i] = V.unwrap(res, rt);
    }
    fn multiple(vm: *VM, a: N(T), ix: N(i32), f: V) !void {
      const s = a.slice();
      var fc = Call{ .vm = vm };
      for (ix.slice()) |raw_i| {
        const i: usize = @intCast(raw_i);
        const res = fc.apply(f, &[_]V{V.wrap(rt, s[i])}, false);
        if (res.tag() != rt) { res.deinit(vm.alloc); return error.TypeError; }
        s[i] = V.unwrap(res, rt);
      }
    }
  };
}

// True when f is the builtin assignment verb `:` (dyadic right). Amend with `:`
// is plain element assignment, so it can skip the per-element verb dispatch.
inline fn isAssign(f: V) bool {
  return f.tag() == .o and f.o.isBuiltinFn()
    and opmod.isOp2Idx(f.o.idx) and f.o.getOp2() == .@":";
}

// Numeric widening rank: bool < int < float. A scalar of a narrower-or-equal type
// coerces losslessly into a typed numeric vector (the k semantics for `@[x;i;:;y]` —
// e.g. int 3 into a float vector becomes 3.0). This is why `@[1. 2. 3.; 0; :; 3]` and
// `L[k]:v` with a numeric literal work without a type error.
inline fn numRank(k: K) ?u8 { return switch (k) { .b => 0, .i => 1, .f => 2, else => null }; }
// Coerce numeric scalar `b` to the backing type T of atom kind `rt`; null if `b` is
// not numeric or is WIDER than rt (that case needs a whole-vector promotion, handled
// in `amend` before dispatch).
inline fn coerceNum(comptime T: type, comptime rt: K, b: V) ?T {
  const bt = b.tag();
  if (bt == rt) return V.unwrap(b, rt);
  const br = numRank(bt) orelse return null;
  const tr = comptime numRank(rt) orelse return null;
  if (br > tr) return null;
  const fv: f64 = switch (bt) { .b => if (b.b) 1.0 else 0.0, .i => @floatFromInt(b.i), .f => b.f, else => unreachable };
  return switch (rt) { .b => fv != 0.0, .i => @intFromFloat(fv), .f => @floatCast(fv), else => null };
}

fn Amend4Vec(comptime k: K) type {
  const rt = k.atom();
  const T = K.backing(k);
  return struct {
    fn single(vm: *VM, a: N(T), idx: i32, f: V, b: V) !void {
      const s = a.slice();
      const i: usize = @intCast(idx);
      if (isAssign(f)) {
        s[i] = coerceNum(T, rt, b) orelse return error.TypeError;
        return;
      }
      var fc = Call{ .vm = vm };
      const res = fc.apply(f, &[_]V{ V.wrap(rt, s[i]), b }, false);
      if (res.tag() != rt) { res.deinit(vm.alloc); return error.TypeError; }
      s[i] = V.unwrap(res, rt);
    }
    fn multiple(vm: *VM, a: N(T), ix: N(i32), f: V, b: V) !void {
      const s = a.slice();
      const ixs = ix.slice();
      const b_is_vec = b.isVec() and b.len() == ixs.len;
      // Fast path: `@[Xvec;I;:;vals]` is a typed scatter — no per-element verb
      // dispatch, no V boxing. Values are scalars of `rt` (or atoms thereof).
      if (isAssign(f)) {
        for (ixs, 0..) |raw_i, n| {
          const bv = if (b_is_vec) b.at(n) else b;
          s[@intCast(raw_i)] = coerceNum(T, rt, bv) orelse return error.TypeError;
        }
        return;
      }
      var fc = Call{ .vm = vm };
      for (ixs, 0..) |raw_i, n| {
        const i: usize = @intCast(raw_i);
        const bv = if (b_is_vec) b.at(n) else b.ref();
        defer bv.deinit(vm.alloc);
        const res = fc.apply(f, &[_]V{ V.wrap(rt, s[i]), bv }, false);
        if (res.tag() != rt) { res.deinit(vm.alloc); return error.TypeError; }
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
    if (isAssign(f)) {
      s[i].deinit(vm.alloc);
      s[i] = b.ref();
      return;
    }
    var fc = Call{ .vm = vm };
    const new_val = fc.apply(f, &[_]V{ s[i], b }, false);
    if (new_val.tag() == .err) return error.Domain;
    s[i].deinit(vm.alloc);
    s[i] = new_val;
  }
  fn multiple(vm: *VM, a: N(V), ix: N(i32), f: V, b: V) !void {
    const s = a.slice();
    const ixs = ix.slice();
    // Conform on a length-matching collection (vec or general list); see amendMap.
    const b_is_vec = (b.isVec() or b.tag() == .L) and b.len() == ixs.len;
    if (isAssign(f)) {
      for (ixs, 0..) |raw_i, n| {
        const i: usize = @intCast(raw_i);
        const bv = if (b_is_vec) b.at(n) else b.ref(); // owned, transferred to s[i]
        s[i].deinit(vm.alloc);
        s[i] = bv;
      }
      return;
    }
    var fc = Call{ .vm = vm };
    for (ixs, 0..) |raw_i, n| {
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
    // Conform: a value collection (typed vector OR general list) whose length
    // matches the key count distributes element-wise (vals[n] → keys[n]); any
    // other value (atom, or mismatched length) broadcasts to every key. Mirrors
    // `d[keys]:vals` so the two assignment forms agree.
    const b_conforms = (b.isVec() or b.tag() == .L) and b.len() == ilen;
    for (0..ilen) |n| {
      const key = indices.at(n);
      defer key.deinit(vm.alloc);
      const bv = if (b_conforms) b.at(n) else b.ref();
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

fn symInVec(names: V, s: u32) bool {
  if (names.tag() == .S) { for (names.S.slice()) |k| if (k == s) return true; }
  else if (names.tag() == .s) return names.s == s;
  return false;
}

// `@[u; keyval; :; valrow]` — upsert by key. Build the full row dict (keyName!keyval),valrow
// and upsert into u (replace the entity's value columns, or append a new row). Only the
// assign form with a dict value row is supported — this backs `u[keyval]:valrow`.
fn amendUTableByKey(vm: *VM, u: V, args: []V) V {
  const alloc = vm.alloc;
  if (args.len != 4 or !isAssign(args[2]) or args[3].tag() != .m) return .{ .err = .@"type" };
  const key_names = u.m.av().M.av();
  if (key_names.len() != 1) return .{ .err = .rank };       // single key column only
  const valrow = args[3];
  const vk = valrow.m.av();
  const vv = valrow.m.bv();
  const n = vk.len() + 1;
  const rk = N(V).init(alloc, n) catch return V{ .err = .memory };
  const rv = N(V).init(alloc, n) catch return V{ .err = .memory };
  rk.slice()[0] = key_names.at(0);                          // key column name (symbol)
  rv.slice()[0] = args[1].ref();                            // the key value
  for (0..vk.len()) |i| { rk.slice()[1 + i] = vk.at(i); rv.slice()[1 + i] = vv.at(i); }
  const row = V{ .m = Dict.init(alloc, promote(alloc, rk), .{ .L = rv }) catch return V{ .err = .memory } };
  defer row.deinit(alloc);
  return insert.upsert(vm, u, row);
}

pub fn amend(vm: *VM, args: []V) V {
  if (args.len < 3) return .{ .err = .rank };
  var a = args[0];
  const at = a.tag();
  if (!a.isVec() and !a.isDict() and at != .L) return .{ .err = .@"type" };

  // A keyed table (utable) is an `m` whose keys/values are tables (M). Two amend modes:
  //  • `@[u;`valcol;:;newcol]` — a value-COLUMN name updates that column of the value table
  //    (a whole-column system), keeping the key table.
  //  • `@[u;keyval;:;valrow]` — any other index is a KEY value: UPSERT the row (replace the
  //    entity's value columns, or append it). This is what `u[keyval]:valrow` lowers to.
  if (at == .m and a.m.av().tag() == .M) {
    const ix = args[1];
    if (ix.tag() == .s and symInVec(a.m.bv().M.av(), ix.s)) {
      var sub: [4]V = undefined;
      sub[0] = a.m.bv();               // value table M (amend refs + cows it internally)
      for (1..args.len) |i| sub[i] = args[i];
      const new_val = amend(vm, sub[0..args.len]);
      if (new_val.tag() == .err) return new_val;
      const key_t = a.m.av().ref();
      return .{ .m = Dict.init(vm.alloc, key_t, new_val) catch return V{ .err = .memory } };
    }
    return amendUTableByKey(vm, a, args);
  }

  a = a.ref();
  a.cow(vm.alloc) catch {
    a.deinit(vm.alloc);
    return .{ .err = .memory };
  };

  const idx = args[1];
  const f   = args[2];
  const atom_idx = idx.tag() == .i;
  // Dict/table targets are keyed by arbitrary values (e.g. symbols), handled by
  // amendMap; only positional (array/list) targets require an i/I index.
  const is_map = at == .m or at == .M;
  if (!is_map and !atom_idx and idx.tag() != .I) {
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
  applied catch |e| {
    a.deinit(vm.alloc);
    return if (e == error.TypeError) .{ .err = .@"type" } else .{ .err = .domain };
  };
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

    if (func.tag() == .o and func.o.isBuiltinFn() and opmod.isOp2Idx(func.o.idx) and func.o.getOp2() == .@":") {
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
    const d = dictOf(target.*);
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

  if (func.tag() == .o and func.o.isBuiltinFn() and opmod.isOp2Idx(func.o.idx) and func.o.getOp2() == .@":") {
    try setAt(vm, target, key, val);
    return;
  }

  const current = if (target.isDict()) blk: {
    const d = dictOf(target.*);
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
    const d = dictOf(target.*);
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
