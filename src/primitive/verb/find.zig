const std = @import("std");
const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const so = @import("setops.zig");

const V = value.V;
const N = value.N;

// Find the first element of x that matches y otherwise return 0N
// TODO k9 returns the length of the vector if nothing is found, why could this be usefull?
pub const Find = struct {
  pub const op = .@"?";
  _I_i: util.DyadFn = findI_i,
  _I_I: util.DyadFn = findI_I,
  _I_L: util.DyadFn = findI_L,
  
  _S_s: util.DyadFn = findS_s,
  _S_S: util.DyadFn = findS_S,
  _S_L: util.DyadFn = findS_L,
  
  // _B_b: util.DyadFn = findB_b,
  // _B_B: util.DyadFn = findB_B,
  // _B_L: util.DyadFn = findB_L,
  
  _C_c: util.DyadFn = findC_c,
  _C_C: util.DyadFn = findC_C,
  _C_L: util.DyadFn = findC_L,
  
  _F_f: util.DyadFn = findF_f,
  _F_F: util.DyadFn = findF_F,
  _F_L: util.DyadFn = findF_L,
  
  _L_i: util.DyadFn = findFallback,
  _L_I: util.DyadFn = findFallback,
  _L_f: util.DyadFn = findFallback,
  _L_F: util.DyadFn = findFallback,
  _L_s: util.DyadFn = findFallback,
  _L_S: util.DyadFn = findFallback,
  _L_c: util.DyadFn = findFallback,
  _L_C: util.DyadFn = findFallback,
  _L_L: util.DyadFn = findFallback,
  
  // TODO support find for Dict & Table, maybe this should be part of the fallback logic.
};

fn find_vec_atom() util.DyadFn {
  return struct {
    fn f(_: *VM, _: V, _: V) !V {
    }
  }.f;
}

fn find_vec_vec() util.DyadFn {
  return struct {
    fn f(_: *VM, _: V, _: V) !V {
    }
  }.f;
}

fn find_list() util.DyadFn {
  return struct {
    fn f(_: *VM, _: V, _: V) !V {
    }
  }.f;
}

// Bool helpers — build a 2-entry lookup from data, then index by bool
fn boolLookup(data: []const bool) [2]i32 {
  var idx_f: i32 = V.@"0N";
  var idx_t: i32 = V.@"0N";
  for (data, 0..) |v, i| {
    if ( v and idx_t == V.@"0N") idx_t = @intCast(i);
    if (!v and idx_f == V.@"0N") idx_f = @intCast(i);
    if (idx_f != V.@"0N" and idx_t != V.@"0N") break;
  }
  return .{ idx_f, idx_t };
}

fn findB_b(vm: *VM, x: V, y: V) !V {
  _ = vm;
  const lut = boolLookup(x.B.slice());
  return .{ .i = lut[@intFromBool(y.b)] };
}

fn findB_B(vm: *VM, x: V, y: V) !V {
  const lut = boolLookup(x.B.slice());
  const res = try N(i32).init(vm.alloc, y.B.ptr.len);
  for (y.B.slice(), res.slice()) |v, *r| r.* = lut[@intFromBool(v)];
  return .{ .I = res };
}

fn findB_L(vm: *VM, x: V, y: V) !V {
  const lut = boolLookup(x.B.slice());
  const res = try N(i32).init(vm.alloc, y.L.ptr.len);
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .b => |v| lut[@intFromBool(v)], else => V.@"0N" };
  return .{ .I = res };
}

// Char helpers — build 256-entry table of first-occurrence indices
fn charTable(data: []const u8) [256]i32 {
  var table: [256]i32 = undefined;
  @memset(&table, V.@"0N");
  for (data, 0..) |c, i| if (table[c] == V.@"0N") { table[c] = @intCast(i); };
  return table;
}

fn findC_c(vm: *VM, x: V, y: V) !V {
  _ = vm;
  const table = charTable(x.C.slice());
  return .{ .i = if (y.c < 256) table[@intCast(y.c)] else V.@"0N" };
}

fn findC_C(vm: *VM, x: V, y: V) !V {
  const table = charTable(x.C.slice());
  if (y.C.ptr.len == 1) return .{ .i = table[y.C.slice()[0]] };
  const res = try N(i32).init(vm.alloc, y.C.ptr.len);
  for (y.C.slice(), res.slice()) |c, *r| r.* = table[c];
  return .{ .I = res };
}

fn findC_L(vm: *VM, x: V, y: V) !V {
  const table = charTable(x.C.slice());
  const res = try N(i32).init(vm.alloc, y.L.ptr.len);
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .c => |v| (if (v < 256) table[@intCast(v)] else V.@"0N"), else => V.@"0N" };
  return .{ .I = res };
}

// Integer — linear (≤ FIND_THRESHOLD) or hash map
fn findI_i(vm: *VM, x: V, y: V) !V {
  const data = x.I.slice();
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (std.mem.indexOfScalar(i32, data, y.i)) |i| @intCast(i) else V.@"0N" };
  var map = try so.buildIndexMap(i32, vm.alloc, data);
  defer map.deinit();
  return .{ .i = map.get(y.i) orelse V.@"0N" };
}

fn findI_I(vm: *VM, x: V, y: V) !V {
  const data = x.I.slice();
  const res = try N(i32).init(vm.alloc, y.I.ptr.len);
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.I.slice(), res.slice()) |v, *r|
      r.* = if (std.mem.indexOfScalar(i32, data, v)) |i| @intCast(i) else V.@"0N";
    return .{ .I = res };
  }
  var map = try so.buildIndexMap(i32, vm.alloc, data);
  defer map.deinit();
  for (y.I.slice(), res.slice()) |v, *r| r.* = map.get(v) orelse V.@"0N";
  return .{ .I = res };
}

fn findI_L(vm: *VM, x: V, y: V) !V {
  const data = x.I.slice();
  const res = try N(i32).init(vm.alloc, y.L.ptr.len);
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.L.slice(), res.slice()) |yv, *r|
      r.* = switch (yv) {
        .i => |v| if (std.mem.indexOfScalar(i32, data, v)) |i| @intCast(i) else V.@"0N",
        else => V.@"0N",
      };
    return .{ .I = res };
  }
  var map = try so.buildIndexMap(i32, vm.alloc, data);
  defer map.deinit();
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .i => |v| map.get(v) orelse V.@"0N", else => V.@"0N" };
  return .{ .I = res };
}

// Symbol — same structure as Integer but u32
fn findS_s(vm: *VM, x: V, y: V) !V {
  const data = x.S.slice();
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (std.mem.indexOfScalar(u32, data, y.s)) |i| @intCast(i) else V.@"0N" };
  var map = try so.buildIndexMap(u32, vm.alloc, data);
  defer map.deinit();
  return .{ .i = map.get(y.s) orelse V.@"0N" };
}

fn findS_S(vm: *VM, x: V, y: V) !V {
  const data = x.S.slice();
  const res = try N(i32).init(vm.alloc, y.S.ptr.len);
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.S.slice(), res.slice()) |v, *r|
      r.* = if (std.mem.indexOfScalar(u32, data, v)) |i| @intCast(i) else V.@"0N";
    return .{ .I = res };
  }
  var map = try so.buildIndexMap(u32, vm.alloc, data);
  defer map.deinit();
  for (y.S.slice(), res.slice()) |v, *r| r.* = map.get(v) orelse V.@"0N";
  return .{ .I = res };
}

fn findS_L(vm: *VM, x: V, y: V) !V {
  const data = x.S.slice();
  const res = try N(i32).init(vm.alloc, y.L.ptr.len);
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.L.slice(), res.slice()) |yv, *r|
      r.* = switch (yv) {
        .s => |v| if (std.mem.indexOfScalar(u32, data, v)) |i| @intCast(i) else V.@"0N",
        else => V.@"0N",
      };
    return .{ .I = res };
  }
  var map = try so.buildIndexMap(u32, vm.alloc, data);
  defer map.deinit();
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .s => |v| map.get(v) orelse V.@"0N", else => V.@"0N" };
  return .{ .I = res };
}

// Float — NaN-safe via bit pattern; linear or hash map
fn buildFloatMap(vm: *VM, data: []const f32) !std.AutoHashMap(u32, i32) {
  var map = std.AutoHashMap(u32, i32).init(vm.alloc);
  try map.ensureTotalCapacity(@intCast(data.len));
  for (data, 0..) |v, i| {
    const gop = try map.getOrPut(@bitCast(v));
    if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
  }
  return map;
}

fn findF_f(vm: *VM, x: V, y: V) !V {
  const data = x.F.slice();
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (so.indexOfF64(data, y.f)) |i| @intCast(i) else V.@"0N" };
  var map = try buildFloatMap(vm, data);
  defer map.deinit();
  return .{ .i = map.get(@bitCast(y.f)) orelse V.@"0N" };
}

fn findF_F(vm: *VM, x: V, y: V) !V {
  const data = x.F.slice();
  const res = try N(i32).init(vm.alloc, y.F.ptr.len);
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.F.slice(), res.slice()) |v, *r|
      r.* = if (so.indexOfF64(data, v)) |i| @intCast(i) else V.@"0N";
    return .{ .I = res };
  }
  var map = try buildFloatMap(vm, data);
  defer map.deinit();
  for (y.F.slice(), res.slice()) |v, *r| r.* = map.get(@bitCast(v)) orelse V.@"0N";
  return .{ .I = res };
}

fn findF_L(vm: *VM, x: V, y: V) !V {
  const data = x.F.slice();
  const res = try N(i32).init(vm.alloc, y.L.ptr.len);
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.L.slice(), res.slice()) |yv, *r|
      r.* = switch (yv) {
        .f => |v| if (so.indexOfF64(data, v)) |i| @intCast(i) else V.@"0N",
        else => V.@"0N",
      };
    return .{ .I = res };
  }
  var map = try buildFloatMap(vm, data);
  defer map.deinit();
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .f => |v| map.get(@bitCast(v)) orelse V.@"0N", else => V.@"0N" };
  return .{ .I = res };
}

// Fallback for heterogeneous lists and other types — O(n×m)
fn findFallback(vm: *VM, x: V, y: V) !V {
  const alloc = vm.alloc;
  const xlen = x.len();
  if (y.isAtom()) {
    for (0..xlen) |i| {
      const xv = x.at(i);
      defer xv.deinit(alloc);
      if (xv.eq(y)) return .{ .i = @intCast(i) };
    }
    return .{ .i = V.@"0N" };
  }
  const ylen = y.len();
  const res = try N(i32).init(alloc, ylen);
  for (res.slice(), 0..) |*r, j| {
    const yv = y.at(j);
    defer yv.deinit(alloc);
    var found = false;
    for (0..xlen) |i| {
      const xv = x.at(i);
      defer xv.deinit(alloc);
      if (xv.eq(yv)) { r.* = @intCast(i); found = true; break; }
    }
    if (!found) r.* = V.@"0N";
  }
  return .{ .I = res };
}

test "find integers atom" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var x = try V.intsFromSlice(vm.alloc, &.{ 3, 1, 4, 1, 5 });
  defer x.deinit(vm.alloc);
  try std.testing.expectEqual(@as(i32, 0), (try findI_i(vm, x, .{ .i = 3 })).i);
  try std.testing.expectEqual(@as(i32, 1), (try findI_i(vm, x, .{ .i = 1 })).i); // first of two 1s
  try std.testing.expectEqual(V.@"0N",     (try findI_i(vm, x, .{ .i = 9 })).i);
}

test "find integers vector" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var x = try V.intsFromSlice(vm.alloc, &.{ 3, 1, 4 });
  defer x.deinit(vm.alloc);
  var y = try V.intsFromSlice(vm.alloc, &.{ 4, 9, 3 });
  defer y.deinit(vm.alloc);
  var res = try findI_I(vm, x, y);
  defer res.deinit(vm.alloc);
  try std.testing.expectEqualSlices(i32, &.{ 2, V.@"0N", 0 }, res.I.slice());
}

test "find integers large (hash path)" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var buf: [so.FIND_THRESHOLD + 1]i32 = undefined;
  for (&buf, 0..) |*v, i| v.* = @intCast(i * 2); // even numbers 0,2,4,...
  var x = try V.intsFromSlice(vm.alloc, &buf);
  defer x.deinit(vm.alloc);
  try std.testing.expectEqual(@as(i32, 0), (try findI_i(vm, x, .{ .i = 0 })).i);
  try std.testing.expectEqual(@as(i32, 1), (try findI_i(vm, x, .{ .i = 2 })).i);
  try std.testing.expectEqual(V.@"0N",     (try findI_i(vm, x, .{ .i = 1 })).i);
}

test "find chars atom" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var x = try V.charsFromSlice(vm.alloc, "abcba");
  defer x.deinit(vm.alloc);
  try std.testing.expectEqual(@as(i32, 1), (try findC_c(vm, x, .{ .c = 'b' })).i); // first b
  try std.testing.expectEqual(V.@"0N",     (try findC_c(vm, x, .{ .c = 'z' })).i);
}

test "find chars vector" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var x = try V.charsFromSlice(vm.alloc, "abc");
  defer x.deinit(vm.alloc);
  var y = try V.charsFromSlice(vm.alloc, "bza");
  defer y.deinit(vm.alloc);
  var res = try findC_C(vm, x, y);
  defer res.deinit(vm.alloc);
  try std.testing.expectEqualSlices(i32, &.{ 1, V.@"0N", 0 }, res.I.slice());
}

test "find booleans" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  const bv = try N(bool).init(vm.alloc, 3);
  bv.slice()[0] = true; bv.slice()[1] = false; bv.slice()[2] = true;
  var x = V{ .B = bv };
  defer x.deinit(vm.alloc);
  try std.testing.expectEqual(@as(i32, 0), (try findB_b(vm, x, .{ .b = true })).i);
  try std.testing.expectEqual(@as(i32, 1), (try findB_b(vm, x, .{ .b = false })).i);
}

test "find floats with NaN" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  const nan = std.math.nan(f32);
  var x = try V.floatsFromSlice(vm.alloc, &.{ 1.0, nan, 3.0 });
  defer x.deinit(vm.alloc);
  try std.testing.expectEqual(@as(i32, 0), (try findF_f(vm, x, .{ .f = 1.0 })).i);
  try std.testing.expectEqual(@as(i32, 1), (try findF_f(vm, x, .{ .f = nan })).i);
  try std.testing.expectEqual(V.@"0N",     (try findF_f(vm, x, .{ .f = 9.9 })).i);
}
