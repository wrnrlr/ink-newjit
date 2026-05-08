const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const so = @import("setops.zig");
const V = value.V;
const N = value.N;
const util = @import("../../util.zig");

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
  _I_i: util.DyadFn = has_I_i,
  _I_I: util.DyadFn = has_I_I,
  _I_L: util.DyadFn = has_I_L,
  _S_s: util.DyadFn = has_S_s,
  _S_S: util.DyadFn = has_S_S,
  _S_L: util.DyadFn = has_S_L,
  _B_b: util.DyadFn = has_B_b,
  _B_B: util.DyadFn = has_B_B,
  _B_L: util.DyadFn = has_B_L,
  _C_c: util.DyadFn = has_C_c,
  _C_C: util.DyadFn = has_C_C,
  _C_L: util.DyadFn = has_C_L,
  _F_f: util.DyadFn = has_F_f,
  _F_F: util.DyadFn = has_F_F,
  _F_L: util.DyadFn = has_F_L,
  _L_i: util.DyadFn = has_L_atom,
  _L_f: util.DyadFn = has_L_atom,
  _L_s: util.DyadFn = has_L_atom,
  _L_c: util.DyadFn = has_L_atom,
  _L_b: util.DyadFn = has_L_atom,
  _L_I: util.DyadFn = has_L_vec,
  _L_F: util.DyadFn = has_L_vec,
  _L_S: util.DyadFn = has_L_vec,
  _L_C: util.DyadFn = has_L_vec,
  _L_B: util.DyadFn = has_L_vec,
  _L_L: util.DyadFn = has_L_vec,
};

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
  _b_B: util.DyadFn = in_b_B,
  _i_I: util.DyadFn = in_i_I,
  _s_S: util.DyadFn = in_s_S,
  _I_I: util.DyadFn = in_I_I,
  _L_I: util.DyadFn = in_L_I,
  _S_S: util.DyadFn = in_S_S,
  _L_S: util.DyadFn = in_L_S,
  _B_B: util.DyadFn = in_B_B,
  _L_B: util.DyadFn = in_L_B,
  _c_C: util.DyadFn = in_c_C,
  _C_C: util.DyadFn = in_C_C,
  _L_C: util.DyadFn = in_L_C,
  _f_F: util.DyadFn = in_f_F,
  _F_F: util.DyadFn = in_F_F,
  _L_F: util.DyadFn = in_L_F,
  _i_L: util.DyadFn = in_atom_L,
  _f_L: util.DyadFn = in_atom_L,
  _s_L: util.DyadFn = in_atom_L,
  _c_L: util.DyadFn = in_atom_L,
  _b_L: util.DyadFn = in_atom_L,
  _I_L: util.DyadFn = in_vec_L,
  _F_L: util.DyadFn = in_vec_L,
  _S_L: util.DyadFn = in_vec_L,
  _C_L: util.DyadFn = in_vec_L,
  _B_L: util.DyadFn = in_vec_L,
  _L_L: util.DyadFn = in_vec_L,
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

// ---------------------------------------------------------------------------
// Tests (direct, no VM/compiler)
// ---------------------------------------------------------------------------

test "has integers atom" {
  const alloc = std.testing.allocator;
  var x = try V.Ints(alloc, &.{ 1, 2, 3 });
  defer x.deinit(alloc);
  try std.testing.expect(containsOrdered(i32, alloc, x.I.slice(), 2) == true);
  try std.testing.expect(containsOrdered(i32, alloc, x.I.slice(), 9) == false);
}

test "has integers vector" {
  const alloc = std.testing.allocator;
  var x = try V.Ints(alloc, &.{ 1, 2, 3 });
  defer x.deinit(alloc);
  var y = try V.Ints(alloc, &.{ 3, 9, 1 });
  defer y.deinit(alloc);
  var res = lookupOrderedVec(i32, alloc, x.I.slice(), y.I.slice());
  defer res.deinit(alloc);
  try std.testing.expectEqualSlices(bool, &.{ true, false, true }, res.B.slice());
}

// Cross-threshold: x.len > HAS_THRESHOLD to exercise hash path
test "has integers large (hash path)" {
  const alloc = std.testing.allocator;
  var buf: [so.HAS_THRESHOLD + 1]i32 = undefined;
  for (&buf, 0..) |*v, i| v.* = @intCast(i);
  var x = try V.Ints(alloc, &buf);
  defer x.deinit(alloc);
  try std.testing.expect(containsOrdered(i32, alloc, x.I.slice(), 0) == true);
  try std.testing.expect(containsOrdered(i32, alloc, x.I.slice(), so.HAS_THRESHOLD) == true);
  try std.testing.expect(containsOrdered(i32, alloc, x.I.slice(), 999) == false);
}

test "has chars atom" {
  const alloc = std.testing.allocator;
  var x = try V.Chars(alloc, "aeiou");
  defer x.deinit(alloc);
  try std.testing.expect(hasCharAtom(x.C.slice(), 'e') == true);
  try std.testing.expect(hasCharAtom(x.C.slice(), 'z') == false);
}

test "has chars vector" {
  const alloc = std.testing.allocator;
  var x = try V.Chars(alloc, "aeiou");
  defer x.deinit(alloc);
  var y = try V.Chars(alloc, "azbz");
  defer y.deinit(alloc);
  var res = hasCharVec(alloc, x.C.slice(), y.C.slice());
  defer res.deinit(alloc);
  try std.testing.expectEqualSlices(bool, &.{ true, false, false, false }, res.B.slice());
}

test "has booleans" {
  const alloc = std.testing.allocator;
  const both = try N(bool).init(alloc, 2);
  both.slice()[0] = true; both.slice()[1] = false;
  var x = V{ .B = both };
  defer x.deinit(alloc);
  try std.testing.expect(hasBoolAtom(x.B.slice(), true) == true);
  try std.testing.expect(hasBoolAtom(x.B.slice(), false) == true);
  const only_true = try N(bool).init(alloc, 2);
  only_true.slice()[0] = true; only_true.slice()[1] = true;
  var x2 = V{ .B = only_true };
  defer x2.deinit(alloc);
  try std.testing.expect(hasBoolAtom(x2.B.slice(), false) == false);
}

test "has floats with NaN" {
  const alloc = std.testing.allocator;
  const nan = std.math.nan(f32);
  var x = try V.Floats(alloc, &.{ 1.0, nan, 3.0 });
  defer x.deinit(alloc);
  try std.testing.expect(containsF(x.F.slice(), 1.0) == true);
  try std.testing.expect(containsF(x.F.slice(), nan) == true);
  try std.testing.expect(containsF(x.F.slice(), 2.0) == false);
}

test "has empty haystack" {
  const alloc = std.testing.allocator;
  var x = try V.Ints(alloc, &.{});
  defer x.deinit(alloc);
  try std.testing.expect(containsOrdered(i32, alloc, x.I.slice(), 1) == false);
}
