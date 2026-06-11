const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const so = @import("setops.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

// Find the first element of x that matches y otherwise return 0N
// TODO k9 returns the length of the vector if nothing is found, why could this be usefull?
pub const Find = struct {
  pub const op = .@"?";
  _I_i: VM.Dyad = findI_i,
  _I_I: VM.Dyad = findI_I,
  _I_L: VM.Dyad = findI_L,
  
  _S_s: VM.Dyad = findS_s,
  _S_S: VM.Dyad = findS_S,
  _S_L: VM.Dyad = findS_L,
  
  _C_c: VM.Dyad = findC_c,
  _C_C: VM.Dyad = findC_C,
  _C_L: VM.Dyad = findC_L,
  
  _F_f: VM.Dyad = findF_f,
  _F_F: VM.Dyad = findF_F,
  _F_L: VM.Dyad = findF_L,
  
  _L_i: VM.Dyad = findFallback,
  _L_I: VM.Dyad = findFallback,
  _L_f: VM.Dyad = findFallback,
  _L_F: VM.Dyad = findFallback,
  _L_s: VM.Dyad = findFallback,
  _L_S: VM.Dyad = findFallback,
  _L_c: VM.Dyad = findFallback,
  _L_C: VM.Dyad = findFallback,
  _L_L: VM.Dyad = findFallback,
  
  // TODO support find for Dict & Table, maybe this should be part of the fallback logic.
};

// Char helpers — build 256-entry table of first-occurrence indices
fn charTable(data: []const u8) [256]i32 {
  var table: [256]i32 = undefined;
  @memset(&table, V.@"0N");
  for (data, 0..) |c, i| if (table[c] == V.@"0N") { table[c] = @intCast(i); };
  return table;
}

fn findC_c(vm: *VM, x: V, y: V) V {
  _ = vm;
  const table = charTable(x.C.slice());
  return .{ .i = if (y.c < 256) table[@intCast(y.c)] else V.@"0N" };
}

fn findC_C(vm: *VM, x: V, y: V) V {
  const table = charTable(x.C.slice());
  if (y.C.ptr.len == 1) return .{ .i = table[y.C.slice()[0]] };
  const res = N(i32).init(vm.alloc, y.C.ptr.len) catch return V{ .err = .memory };
  for (y.C.slice(), res.slice()) |c, *r| r.* = table[c];
  return .{ .I = res };
}

fn findC_L(vm: *VM, x: V, y: V) V {
  const table = charTable(x.C.slice());
  const res = N(i32).init(vm.alloc, y.L.ptr.len) catch return V{ .err = .memory };
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .c => |v| (if (v < 256) table[@intCast(v)] else V.@"0N"), else => V.@"0N" };
  return .{ .I = res };
}

// Integer — linear (≤ FIND_THRESHOLD) or hash map
fn findI_i(vm: *VM, x: V, y: V) V {
  const data = x.I.slice();
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (std.mem.indexOfScalar(i32, data, y.i)) |i| @intCast(i) else V.@"0N" };
  var map = so.buildIndexMap(i32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  return .{ .i = map.get(y.i) orelse V.@"0N" };
}

fn findI_I(vm: *VM, x: V, y: V) V {
  const data = x.I.slice();
  const res = N(i32).init(vm.alloc, y.I.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.I.slice(), res.slice()) |v, *r|
      r.* = if (std.mem.indexOfScalar(i32, data, v)) |i| @intCast(i) else V.@"0N";
    return .{ .I = res };
  }
  var map = so.buildIndexMap(i32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.I.slice(), res.slice()) |v, *r| r.* = map.get(v) orelse V.@"0N";
  return .{ .I = res };
}

fn findI_L(vm: *VM, x: V, y: V) V {
  const data = x.I.slice();
  const res = N(i32).init(vm.alloc, y.L.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.L.slice(), res.slice()) |yv, *r|
      r.* = switch (yv) {
        .i => |v| if (std.mem.indexOfScalar(i32, data, v)) |i| @intCast(i) else V.@"0N",
        else => V.@"0N",
      };
    return .{ .I = res };
  }
  var map = so.buildIndexMap(i32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .i => |v| map.get(v) orelse V.@"0N", else => V.@"0N" };
  return .{ .I = res };
}

// Symbol — same structure as Integer but u32
fn findS_s(vm: *VM, x: V, y: V) V {
  const data = x.S.slice();
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (std.mem.indexOfScalar(u32, data, y.s)) |i| @intCast(i) else V.@"0N" };
  var map = so.buildIndexMap(u32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  return .{ .i = map.get(y.s) orelse V.@"0N" };
}

fn findS_S(vm: *VM, x: V, y: V) V {
  const data = x.S.slice();
  const res = N(i32).init(vm.alloc, y.S.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.S.slice(), res.slice()) |v, *r|
      r.* = if (std.mem.indexOfScalar(u32, data, v)) |i| @intCast(i) else V.@"0N";
    return .{ .I = res };
  }
  var map = so.buildIndexMap(u32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.S.slice(), res.slice()) |v, *r| r.* = map.get(v) orelse V.@"0N";
  return .{ .I = res };
}

fn findS_L(vm: *VM, x: V, y: V) V {
  const data = x.S.slice();
  const res = N(i32).init(vm.alloc, y.L.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.L.slice(), res.slice()) |yv, *r|
      r.* = switch (yv) {
        .s => |v| if (std.mem.indexOfScalar(u32, data, v)) |i| @intCast(i) else V.@"0N",
        else => V.@"0N",
      };
    return .{ .I = res };
  }
  var map = so.buildIndexMap(u32, vm.alloc, data) catch return V{ .err = .memory };
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

fn findF_f(vm: *VM, x: V, y: V) V {
  const data = x.F.slice();
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (so.indexOfF64(data, y.f)) |i| @intCast(i) else V.@"0N" };
  var map = buildFloatMap(vm, data) catch return V{ .err = .memory };
  defer map.deinit();
  return .{ .i = map.get(@bitCast(y.f)) orelse V.@"0N" };
}

fn findF_F(vm: *VM, x: V, y: V) V {
  const data = x.F.slice();
  const res = N(i32).init(vm.alloc, y.F.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.F.slice(), res.slice()) |v, *r|
      r.* = if (so.indexOfF64(data, v)) |i| @intCast(i) else V.@"0N";
    return .{ .I = res };
  }
  var map = buildFloatMap(vm, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.F.slice(), res.slice()) |v, *r| r.* = map.get(@bitCast(v)) orelse V.@"0N";
  return .{ .I = res };
}

fn findF_L(vm: *VM, x: V, y: V) V {
  const data = x.F.slice();
  const res = N(i32).init(vm.alloc, y.L.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.L.slice(), res.slice()) |yv, *r|
      r.* = switch (yv) {
        .f => |v| if (so.indexOfF64(data, v)) |i| @intCast(i) else V.@"0N",
        else => V.@"0N",
      };
    return .{ .I = res };
  }
  var map = buildFloatMap(vm, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .f => |v| map.get(@bitCast(v)) orelse V.@"0N", else => V.@"0N" };
  return .{ .I = res };
}

// Fallback for heterogeneous lists and other types — O(n×m)
fn findFallback(vm: *VM, x: V, y: V) V {
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
  const res = N(i32).init(alloc, ylen) catch return V{ .err = .memory };
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
