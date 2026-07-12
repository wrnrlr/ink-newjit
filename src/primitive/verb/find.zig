const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const so = @import("setops.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

// Find the first index of x that matches y; if not found return the length of x (#x).
// Returning #x (not 0N) is deliberate, matching k9/ngn-k: it makes find compose with
// index-with-fallback. The idiom `(vals,default)@keys?probe` appends a default at index
// #keys, so every miss lands exactly on it — no separate "is it present?" pass needed.
//
// TODO(Q2): out-of-bounds indexing (`X@i` past the end, or `d@key` for a missing key)
// currently errors (!length). ngn/k instead returns the null/identity of the element type,
// making `@` total. Decide whether to adopt that generally. Note it is ORTHOGONAL to this
// find→length change and does NOT suit grouped buckets: a miss there must index an EMPTY
// list, not a null, or raze/count-each pollute the result with phantom 0N entries.
pub const Find = struct {
  pub const op = .@"?";
  _I_i: VM.Dyad = findI_i,
  _I_I: VM.Dyad = findI_I,
  _I_L: VM.Dyad = findI_L,
  
  _S_s: VM.Dyad = findS_s,
  _S_S: VM.Dyad = findS_S,
  _S_L: VM.Dyad = findS_L,

  _N_n: VM.Dyad = findN_n,
  _N_N: VM.Dyad = findN_N,
  _N_L: VM.Dyad = findFallback,
  
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

// Char helpers — build 256-entry table of first-occurrence indices. Missing bytes hold
// `#data` (the not-found sentinel), which doubles as the value we want to return on a miss.
fn charTable(data: []const u8) [256]i32 {
  const miss: i32 = @intCast(data.len);
  var table: [256]i32 = undefined;
  @memset(&table, miss);
  for (data, 0..) |c, i| if (table[c] == miss) { table[c] = @intCast(i); };
  return table;
}

fn findC_c(vm: *VM, x: V, y: V) V {
  _ = vm;
  const table = charTable(x.C.slice());
  return .{ .i = if (y.c < 256) table[@intCast(y.c)] else @as(i32, @intCast(x.C.ptr.len)) };
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
  const miss: i32 = @intCast(x.C.ptr.len);
  const res = N(i32).init(vm.alloc, y.L.ptr.len) catch return V{ .err = .memory };
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .c => |v| (if (v < 256) table[@intCast(v)] else miss), else => miss };
  return .{ .I = res };
}

// Integer — linear (≤ FIND_THRESHOLD) or hash map
fn findI_i(vm: *VM, x: V, y: V) V {
  const data = x.I.slice();
  const miss: i32 = @intCast(data.len);
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (std.mem.indexOfScalar(i32, data, y.i)) |i| @intCast(i) else miss };
  var map = so.buildIndexMap(i32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  return .{ .i = map.get(y.i) orelse miss };
}

fn findI_I(vm: *VM, x: V, y: V) V {
  const data = x.I.slice();
  const miss: i32 = @intCast(data.len);
  const res = N(i32).init(vm.alloc, y.I.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.I.slice(), res.slice()) |v, *r|
      r.* = if (std.mem.indexOfScalar(i32, data, v)) |i| @intCast(i) else miss;
    return .{ .I = res };
  }
  var map = so.buildIndexMap(i32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.I.slice(), res.slice()) |v, *r| r.* = map.get(v) orelse miss;
  return .{ .I = res };
}

fn findI_L(vm: *VM, x: V, y: V) V {
  const data = x.I.slice();
  const miss: i32 = @intCast(data.len);
  const res = N(i32).init(vm.alloc, y.L.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.L.slice(), res.slice()) |yv, *r|
      r.* = switch (yv) {
        .i => |v| if (std.mem.indexOfScalar(i32, data, v)) |i| @intCast(i) else miss,
        else => miss,
      };
    return .{ .I = res };
  }
  var map = so.buildIndexMap(i32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .i => |v| map.get(v) orelse miss, else => miss };
  return .{ .I = res };
}

// Symbol — same structure as Integer but u32
// Natural (u32) find — same interned-id scan as symbols on x.N / y.n.
fn findN_n(vm: *VM, x: V, y: V) V {
  const data = x.N.slice();
  const miss: i32 = @intCast(data.len);
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (std.mem.indexOfScalar(u32, data, y.n)) |i| @intCast(i) else miss };
  var map = so.buildIndexMap(u32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  return .{ .i = map.get(y.n) orelse miss };
}
fn findN_N(vm: *VM, x: V, y: V) V {
  const data = x.N.slice();
  const miss: i32 = @intCast(data.len);
  const res = N(i32).init(vm.alloc, y.N.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.N.slice(), res.slice()) |v, *r|
      r.* = if (std.mem.indexOfScalar(u32, data, v)) |i| @intCast(i) else miss;
    return .{ .I = res };
  }
  var map = so.buildIndexMap(u32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.N.slice(), res.slice()) |v, *r| r.* = map.get(v) orelse miss;
  return .{ .I = res };
}

fn findS_s(vm: *VM, x: V, y: V) V {
  const data = x.S.slice();
  const miss: i32 = @intCast(data.len);
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (std.mem.indexOfScalar(u32, data, y.s)) |i| @intCast(i) else miss };
  var map = so.buildIndexMap(u32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  return .{ .i = map.get(y.s) orelse miss };
}

fn findS_S(vm: *VM, x: V, y: V) V {
  const data = x.S.slice();
  const miss: i32 = @intCast(data.len);
  const res = N(i32).init(vm.alloc, y.S.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.S.slice(), res.slice()) |v, *r|
      r.* = if (std.mem.indexOfScalar(u32, data, v)) |i| @intCast(i) else miss;
    return .{ .I = res };
  }
  var map = so.buildIndexMap(u32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.S.slice(), res.slice()) |v, *r| r.* = map.get(v) orelse miss;
  return .{ .I = res };
}

fn findS_L(vm: *VM, x: V, y: V) V {
  const data = x.S.slice();
  const miss: i32 = @intCast(data.len);
  const res = N(i32).init(vm.alloc, y.L.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.L.slice(), res.slice()) |yv, *r|
      r.* = switch (yv) {
        .s => |v| if (std.mem.indexOfScalar(u32, data, v)) |i| @intCast(i) else miss,
        else => miss,
      };
    return .{ .I = res };
  }
  var map = so.buildIndexMap(u32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .s => |v| map.get(v) orelse miss, else => miss };
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
  const miss: i32 = @intCast(data.len);
  if (data.len <= so.FIND_THRESHOLD)
    return .{ .i = if (so.indexOfF64(data, y.f)) |i| @intCast(i) else miss };
  var map = buildFloatMap(vm, data) catch return V{ .err = .memory };
  defer map.deinit();
  return .{ .i = map.get(@bitCast(y.f)) orelse miss };
}

fn findF_F(vm: *VM, x: V, y: V) V {
  const data = x.F.slice();
  const miss: i32 = @intCast(data.len);
  const res = N(i32).init(vm.alloc, y.F.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.F.slice(), res.slice()) |v, *r|
      r.* = if (so.indexOfF64(data, v)) |i| @intCast(i) else miss;
    return .{ .I = res };
  }
  var map = buildFloatMap(vm, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.F.slice(), res.slice()) |v, *r| r.* = map.get(@bitCast(v)) orelse miss;
  return .{ .I = res };
}

fn findF_L(vm: *VM, x: V, y: V) V {
  const data = x.F.slice();
  const miss: i32 = @intCast(data.len);
  const res = N(i32).init(vm.alloc, y.L.ptr.len) catch return V{ .err = .memory };
  if (data.len <= so.FIND_THRESHOLD) {
    for (y.L.slice(), res.slice()) |yv, *r|
      r.* = switch (yv) {
        .f => |v| if (so.indexOfF64(data, v)) |i| @intCast(i) else miss,
        else => miss,
      };
    return .{ .I = res };
  }
  var map = buildFloatMap(vm, data) catch return V{ .err = .memory };
  defer map.deinit();
  for (y.L.slice(), res.slice()) |yv, *r|
    r.* = switch (yv) { .f => |v| map.get(@bitCast(v)) orelse miss, else => miss };
  return .{ .I = res };
}

// Fallback for heterogeneous lists and other types — O(n×m)
fn findFallback(vm: *VM, x: V, y: V) V {
  const alloc = vm.alloc;
  const xlen = x.len();
  const miss: i32 = @intCast(xlen);
  if (y.isAtom()) {
    for (0..xlen) |i| {
      const xv = x.at(i);
      defer xv.deinit(alloc);
      if (xv.eq(y)) return .{ .i = @intCast(i) };
    }
    return .{ .i = miss };
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
    if (!found) r.* = miss;
  }
  return .{ .I = res };
}
