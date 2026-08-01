const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const so = @import("setops.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

// Has: x contains y?
fn has_B_b(_: *VM, x: V, y: V) V  { return .{ .b = hasBoolAtom(x.B.slice(), y.b) }; }
fn has_I_i(vm: *VM, x: V, y: V) V { return .{ .b = containsOrdered(i32, vm.alloc, x.I.slice(), y.i) }; }
fn has_F_f(_: *VM, x: V, y: V) V  { return .{ .b = containsF(x.F.slice(), y.f) }; }
fn has_S_s(vm: *VM, x: V, y: V) V { return .{ .b = containsOrdered(u32, vm.alloc, x.S.slice(), y.s) }; }
fn has_C_c(_: *VM, x: V, y: V) V  { return .{ .b = hasCharAtom(x.C.slice(), y.c) }; }

fn has_B_B(vm: *VM, x: V, y: V) V { return hasBoolVec(vm.alloc, x.B.slice(), y.B.slice()); }
fn has_C_C(vm: *VM, x: V, y: V) V { return hasCharVec(vm.alloc, x.C.slice(), y.C.slice()); }
fn has_I_I(vm: *VM, x: V, y: V) V { return lookupOrderedVec(i32, vm.alloc, x.I.slice(), y.I.slice()); }
fn has_F_F(vm: *VM, x: V, y: V) V { return lookupFloatVec(vm.alloc, x.F.slice(), y.F.slice()); }
fn has_S_S(vm: *VM, x: V, y: V) V { return lookupOrderedVec(u32, vm.alloc, x.S.slice(), y.S.slice()); }

fn has_B_L(vm: *VM, x: V, y: V) V { return hasBoolList(vm.alloc, x.B.slice(), y.L.slice()); }
fn has_I_L(vm: *VM, x: V, y: V) V { return lookupOrderedList(i32, .i, vm.alloc, x.I.slice(), y.L.slice()); }
fn has_S_L(vm: *VM, x: V, y: V) V { return lookupOrderedList(u32, .s, vm.alloc, x.S.slice(), y.L.slice()); }
fn has_C_L(vm: *VM, x: V, y: V) V { return hasCharList(vm.alloc, x.C.slice(), y.L.slice()); }

fn has_F_L(vm: *VM, x: V, y: V) V { return lookupFloatList(vm.alloc, x.F.slice(), y.L.slice()); }
fn has_L_atom(vm: *VM, x: V, y: V) V { return .{ .b = hasListAtom(vm.alloc, x.L.slice(), y) }; }
fn has_L_vec(vm: *VM, x: V, y: V) V  { return hasListVec(vm.alloc, x.L.slice(), y); }

pub const Has = struct {
  pub const op = .has;
  pub const fallback: VM.Dyad = hasFalse;
  _I_i: VM.Dyad = has_I_i,
  _I_I: VM.Dyad = has_I_I,
  _I_L: VM.Dyad = has_I_L,
  _S_s: VM.Dyad = has_S_s,
  _S_S: VM.Dyad = has_S_S,
  _S_L: VM.Dyad = has_S_L,
  _B_b: VM.Dyad = has_B_b,
  _B_B: VM.Dyad = has_B_B,
  _B_L: VM.Dyad = has_B_L,
  _C_c: VM.Dyad = has_C_c,
  _C_C: VM.Dyad = has_C_C,
  _C_L: VM.Dyad = has_C_L,
  _F_f: VM.Dyad = has_F_f,
  _F_F: VM.Dyad = has_F_F,
  _F_L: VM.Dyad = has_F_L,
  _L_i: VM.Dyad = has_L_atom,
  _L_f: VM.Dyad = has_L_atom,
  _L_s: VM.Dyad = has_L_atom,
  _L_c: VM.Dyad = has_L_atom,
  _L_b: VM.Dyad = has_L_atom,
  _L_I: VM.Dyad = has_L_vec,
  _L_F: VM.Dyad = has_L_vec,
  _L_S: VM.Dyad = has_L_vec,
  _L_C: VM.Dyad = has_L_vec,
  _L_B: VM.Dyad = has_L_vec,
  _L_L: VM.Dyad = has_L_vec,
};

// Membership across types that cannot compare — `` `a`b in 1 2 3 ``, or a probe
// against an EMPTY typed vector, whose element type says nothing about what it
// could have held — is not an error: nothing is a member, so the answer is
// false, shaped like the probe. (`~` takes the same line for mismatched tags:
// see matchFalse.) Dicts and tables are NOT covered — `in` has no kernel for
// them at all, and answering "false" would hide that rather than report it.
fn plainOperand(v: V) bool {
  const t = v.tag();
  return t.isAtom() or t.isVec() or t == .L;
}

fn falseLike(vm: *VM, probe: V) V {
  if (!plainOperand(probe)) return V{ .err = .@"type" };
  if (probe.isAtom()) return .{ .b = false };
  const n = N(bool).init(vm.alloc, probe.len()) catch return V{ .err = .memory };
  @memset(n.slice(), false);
  return .{ .B = n };
}

// `x in y` answers about x; `x has y` answers about y.
fn inFalse(vm: *VM, x: V, y: V) V { return if (plainOperand(y)) falseLike(vm, x) else V{ .err = .@"type" }; }
fn hasFalse(vm: *VM, x: V, y: V) V { return if (plainOperand(x)) falseLike(vm, y) else V{ .err = .@"type" }; }

// In: x in y? (x and y swapped relative to Has)
fn in_b_B(_: *VM, x: V, y: V) V  { return .{ .b = hasBoolAtom(y.B.slice(), x.b) }; }
fn in_i_I(vm: *VM, x: V, y: V) V { return .{ .b = containsOrdered(i32, vm.alloc, y.I.slice(), x.i) }; }
fn in_s_S(vm: *VM, x: V, y: V) V { return .{ .b = containsOrdered(u32, vm.alloc, y.S.slice(), x.s) }; }
fn in_I_I(vm: *VM, x: V, y: V) V { return lookupOrderedVec(i32, vm.alloc, y.I.slice(), x.I.slice()); }
fn in_L_I(vm: *VM, x: V, y: V) V { return lookupOrderedList(i32, .i, vm.alloc, y.I.slice(), x.L.slice()); }
fn in_S_S(vm: *VM, x: V, y: V) V { return lookupOrderedVec(u32, vm.alloc, y.S.slice(), x.S.slice()); }
fn in_L_S(vm: *VM, x: V, y: V) V { return lookupOrderedList(u32, .s, vm.alloc, y.S.slice(), x.L.slice()); }
fn in_B_B(vm: *VM, x: V, y: V) V { return hasBoolVec(vm.alloc, y.B.slice(), x.B.slice()); }
fn in_L_B(vm: *VM, x: V, y: V) V { return hasBoolList(vm.alloc, y.B.slice(), x.L.slice()); }
fn in_c_C(_: *VM, x: V, y: V) V  { return .{ .b = hasCharAtom(y.C.slice(), x.c) }; }
fn in_C_C(vm: *VM, x: V, y: V) V { return hasCharVec(vm.alloc, y.C.slice(), x.C.slice()); }
fn in_L_C(vm: *VM, x: V, y: V) V { return hasCharList(vm.alloc, y.C.slice(), x.L.slice()); }
fn in_f_F(_: *VM, x: V, y: V) V  { return .{ .b = containsF(y.F.slice(), x.f) }; }
fn in_F_F(vm: *VM, x: V, y: V) V { return lookupFloatVec(vm.alloc, y.F.slice(), x.F.slice()); }
fn in_L_F(vm: *VM, x: V, y: V) V { return lookupFloatList(vm.alloc, y.F.slice(), x.L.slice()); }
fn in_atom_L(vm: *VM, x: V, y: V) V { return .{ .b = hasListAtom(vm.alloc, y.L.slice(), x) }; }
fn in_vec_L(vm: *VM, x: V, y: V) V  { return hasListVec(vm.alloc, y.L.slice(), x); }

pub const In = struct {
  pub const op = .in;
  pub const fallback: VM.Dyad = inFalse;
  _b_B: VM.Dyad = in_b_B,
  _i_I: VM.Dyad = in_i_I,
  _s_S: VM.Dyad = in_s_S,
  _I_I: VM.Dyad = in_I_I,
  _L_I: VM.Dyad = in_L_I,
  _S_S: VM.Dyad = in_S_S,
  _L_S: VM.Dyad = in_L_S,
  _B_B: VM.Dyad = in_B_B,
  _L_B: VM.Dyad = in_L_B,
  _c_C: VM.Dyad = in_c_C,
  _C_C: VM.Dyad = in_C_C,
  _L_C: VM.Dyad = in_L_C,
  _f_F: VM.Dyad = in_f_F,
  _F_F: VM.Dyad = in_F_F,
  _L_F: VM.Dyad = in_L_F,
  _i_L: VM.Dyad = in_atom_L,
  _f_L: VM.Dyad = in_atom_L,
  _s_L: VM.Dyad = in_atom_L,
  _c_L: VM.Dyad = in_atom_L,
  _b_L: VM.Dyad = in_atom_L,
  _I_L: VM.Dyad = in_vec_L,
  _F_L: VM.Dyad = in_vec_L,
  _S_L: VM.Dyad = in_vec_L,
  _C_L: VM.Dyad = in_vec_L,
  _B_L: VM.Dyad = in_vec_L,
  _L_L: VM.Dyad = in_vec_L,
};

// ---------------------------------------------------------------------------
// Bool: two-flag scan — O(n) zero allocation
// ---------------------------------------------------------------------------

fn boolTable(data: []const bool) [2]bool {
  var has_f = false;
  var has_t = false;
  for (data) |v| {
    if (v) has_t = true else has_f = true;
    if (has_f and has_t) break;
  }
  return .{ has_f, has_t };
}

fn hasBoolAtom(data: []const bool, v: bool) bool {
  const t = boolTable(data);
  return t[@intFromBool(v)];
}
fn hasBoolVec(alloc: Alloc, data: []const bool, ny: []const bool) V {
  const t = boolTable(data);
  const res = N(bool).init(alloc, ny.len) catch return V{ .err = .memory };
  for (ny, res.slice()) |v, *b| b.* = t[@intFromBool(v)];
  return .{ .B = res };
}
fn hasBoolList(alloc: Alloc, data: []const bool, ny: []const V) V {
  const t = boolTable(data);
  const res = N(bool).init(alloc, ny.len) catch return V{ .err = .memory };
  for (ny, res.slice()) |yv, *b| b.* = if (yv == .b) t[@intFromBool(yv.b)] else false;
  return .{ .B = res };
}

// ---------------------------------------------------------------------------
// Char: 256-entry bool table — O(n+m) zero allocation
// ---------------------------------------------------------------------------

fn charTable(data: []const u8) [256]bool {
  var table: [256]bool = .{false} ** 256;
  for (data) |c| table[c] = true;
  return table;
}

fn hasCharAtom(data: []const u8, v: u32) bool {
  const table = charTable(data);
  return v < 256 and table[@intCast(v)];
}
fn hasCharVec(alloc: Alloc, data: []const u8, ny: []const u8) V {
  const table = charTable(data);
  if (ny.len == 1) return .{ .b = table[ny[0]] };
  const res = N(bool).init(alloc, ny.len) catch return V{ .err = .memory };
  for (ny, res.slice()) |c, *b| b.* = table[c];
  return .{ .B = res };
}
fn hasCharList(alloc: Alloc, data: []const u8, ny: []const V) V {
  const table = charTable(data);
  const res = N(bool).init(alloc, ny.len) catch return V{ .err = .memory };
  for (ny, res.slice()) |yv, *b| b.* = if (yv == .c) (yv.c < 256 and table[@intCast(yv.c)]) else false;
  return .{ .B = res };
}

// ---------------------------------------------------------------------------
// Ordered scalars (i32, u32): linear (≤ threshold) or hash set
// ---------------------------------------------------------------------------

fn containsOrdered(comptime T: type, alloc: Alloc, data: []const T, v: T) bool {
  _ = alloc; // atom lookup is always linear — building a set for one query costs the same
  return std.mem.indexOfScalar(T, data, v) != null;
}

fn lookupOrderedVec(comptime T: type, alloc: Alloc, data: []const T, ny: []const T) V {
  const res = N(bool).init(alloc, ny.len) catch return V{ .err = .memory };
  if (data.len <= so.HAS_THRESHOLD) {
    for (ny, res.slice()) |v, *b| b.* = std.mem.indexOfScalar(T, data, v) != null;
  } else {
    var set = so.buildOrderedSet(T, alloc, data) catch return V{ .err = .memory };
    defer set.deinit(alloc);
    for (ny, res.slice()) |v, *b| b.* = set.contains(v);
  }
  return .{ .B = res };
}

fn lookupOrderedList(comptime T: type, comptime ak: std.meta.Tag(V), alloc: Alloc, data: []const T, ny: []const V) V {
  const res = N(bool).init(alloc, ny.len) catch return V{ .err = .memory };
  if (data.len <= so.HAS_THRESHOLD) {
    for (ny, res.slice()) |yv, *b|
      b.* = if (yv == ak) std.mem.indexOfScalar(T, data, @field(yv, @tagName(ak))) != null else false;
  } else {
    var set = so.buildOrderedSet(T, alloc, data) catch return V{ .err = .memory };
    defer set.deinit(alloc);
    for (ny, res.slice()) |yv, *b|
      b.* = if (yv == ak) set.contains(@field(yv, @tagName(ak))) else false;
  }
  return .{ .B = res };
}

// ---------------------------------------------------------------------------
// Float — NaN-safe (bit-pattern comparison or hash)
// ---------------------------------------------------------------------------

fn containsF(data: []const f32, v: f32) bool { return so.containsF64(data, v); }

fn lookupFloatVec(alloc: Alloc, data: []const f32, ny: []const f32) V {
  const res = N(bool).init(alloc, ny.len) catch return V{ .err = .memory };
  if (data.len <= so.HAS_THRESHOLD) {
    for (ny, res.slice()) |v, *b| b.* = so.containsF64(data, v);
  } else {
    var set = std.AutoHashMap(u32, void).init(alloc);
    defer set.deinit();
    set.ensureTotalCapacity(@intCast(data.len)) catch return V{ .err = .memory };
    for (data) |v| set.put(@bitCast(v), {}) catch return V{ .err = .memory };
    for (ny, res.slice()) |v, *b| b.* = set.contains(@bitCast(v));
  }
  return .{ .B = res };
}

fn lookupFloatList(alloc: Alloc, data: []const f32, ny: []const V) V {
  const res = N(bool).init(alloc, ny.len) catch return V{ .err = .memory };
  if (data.len <= so.HAS_THRESHOLD) {
    for (ny, res.slice()) |yv, *b| b.* = if (yv == .f) so.containsF64(data, yv.f) else false;
  } else {
    var set = std.AutoHashMap(u32, void).init(alloc);
    defer set.deinit();
    set.ensureTotalCapacity(@intCast(data.len)) catch return V{ .err = .memory };
    for (data) |v| set.put(@bitCast(v), {}) catch return V{ .err = .memory };
    for (ny, res.slice()) |yv, *b| b.* = if (yv == .f) set.contains(@bitCast(yv.f)) else false;
  }
  return .{ .B = res };
}

// ---------------------------------------------------------------------------
// Heterogeneous list: O(n×m) fallback
// ---------------------------------------------------------------------------

fn hasListAtom(_: Alloc, data: []const V, y: V) bool {
  for (data) |xv| if (xv.eq(y)) return true;
  return false;
}

fn hasListVec(alloc: Alloc, data: []const V, y: V) V {
  const ylen = y.len();
  const res = N(bool).init(alloc, ylen) catch return V{ .err = .memory };
  for (res.slice(), 0..) |*b, j| {
    const yv = y.at(j);
    defer yv.deinit(alloc);
    b.* = hasListAtom(alloc, data, yv);
  }
  return .{ .B = res };
}
