const std = @import("std");
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;
const VM = @import("../../runtime/vm.zig").VM;
const so = @import("setops.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Alloc = std.mem.Allocator;

pub const Distinct = struct {
  pub const op = .@"?";
  _B: util.MonadFn = distinctB,
  _I: util.MonadFn = distinctI,
  _F: util.MonadFn = distinctF,
  _S: util.MonadFn = distinctS,
  _C: util.MonadFn = distinctC,
  _L: util.MonadFn = distinctL,
};

// Bool: at most 2 distinct values, zero allocation regardless of size
fn distinctB(vm: *VM, x: V) V {
  const data = x.B.slice();
  var has_f = false;
  var has_t = false;
  for (data) |v| {
    if (v) has_t = true else has_f = true;
    if (has_f and has_t) break;
  }
  const n: usize = @as(usize, @intFromBool(has_f)) + @intFromBool(has_t);
  const res = N(bool).init(vm.alloc, n) catch return V{ .err = .memory };
  var i: usize = 0;
  if (has_f) { res.slice()[i] = false; i += 1; }
  if (has_t) { res.slice()[i] = true; }
  return .{ .B = res };
}

// Char: 256-bucket seen table, zero allocation regardless of size
fn distinctC(vm: *VM, x: V) V {
  const data = x.C.slice();
  var seen:  [256]bool = .{false} ** 256;
  var order: [256]u8   = undefined;
  var n: usize = 0;
  for (data) |c| if (!seen[c]) { seen[c] = true; order[n] = c; n += 1; };
  const res = N(u8).init(vm.alloc, n) catch return V{ .err = .memory };
  @memcpy(res.slice(), order[0..n]);
  return .{ .C = res };
}

// Integer — stack dedup (≤ DEDUP_THRESHOLD, no map alloc) or ordered hash set
fn distinctI(vm: *VM, x: V) V {
  const data = x.I.slice();
  if (data.len <= so.DEDUP_THRESHOLD) {
    var buf: [so.DEDUP_THRESHOLD]i32 = undefined;
    var n: usize = 0;
    for (data) |v| if (std.mem.indexOfScalar(i32, buf[0..n], v) == null) {
      buf[n] = v; n += 1;
    };
    const res = N(i32).init(vm.alloc, n) catch return V{ .err = .memory };
    @memcpy(res.slice(), buf[0..n]);
    return .{ .I = res };
  }
  var map = so.buildOrderedSet(i32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit(vm.alloc);
  const res = N(i32).init(vm.alloc, map.count()) catch return V{ .err = .memory };
  @memcpy(res.slice(), map.keys());
  return .{ .I = res };
}

// Symbol — same as Integer but u32
fn distinctS(vm: *VM, x: V) V {
  const data = x.S.slice();
  if (data.len <= so.DEDUP_THRESHOLD) {
    var buf: [so.DEDUP_THRESHOLD]u32 = undefined;
    var n: usize = 0;
    for (data) |v| if (std.mem.indexOfScalar(u32, buf[0..n], v) == null) {
      buf[n] = v; n += 1;
    };
    const res = N(u32).init(vm.alloc, n) catch return V{ .err = .memory };
    @memcpy(res.slice(), buf[0..n]);
    return .{ .S = res };
  }
  var map = so.buildOrderedSet(u32, vm.alloc, data) catch return V{ .err = .memory };
  defer map.deinit(vm.alloc);
  const res = N(u32).init(vm.alloc, map.count()) catch return V{ .err = .memory };
  @memcpy(res.slice(), map.keys());
  return .{ .S = res };
}

// Float — NaN-safe via bit pattern; stack dedup or hash set
fn distinctF(vm: *VM, x: V) V {
  const data = x.F.slice();
  if (data.len <= so.DEDUP_THRESHOLD) {
    var buf: [so.DEDUP_THRESHOLD]u32 = undefined; // store as bits for NaN-safe ==
    var n: usize = 0;
    for (data) |v| {
      const bits: u32 = @bitCast(v);
      if (std.mem.indexOfScalar(u32, buf[0..n], bits) == null) { buf[n] = bits; n += 1; }
    }
    const res = N(f32).init(vm.alloc, n) catch return V{ .err = .memory };
    for (buf[0..n], res.slice()) |bits, *f| f.* = @bitCast(bits);
    return .{ .F = res };
  }
  // Bitcast so that NaN with identical bits lands in the same bucket
  var map: std.AutoArrayHashMapUnmanaged(u32, void) = .{};
  defer map.deinit(vm.alloc);
  map.ensureTotalCapacity(vm.alloc, data.len) catch return V{ .err = .memory };
  for (data) |v| map.put(vm.alloc, @bitCast(v), {}) catch return V{ .err = .memory };
  const res = N(f32).init(vm.alloc, map.count()) catch return V{ .err = .memory };
  for (map.keys(), res.slice()) |bits, *f| f.* = @bitCast(bits);
  return .{ .F = res };
}

// Heterogeneous list: O(n²) fallback, result promoted to typed array if uniform
fn distinctL(vm: *VM, x: V) V {
  const alloc = vm.alloc;
  const data = x.L.slice();
  var res_list: std.ArrayList(V) = .empty;
  res_list.ensureTotalCapacity(alloc, data.len) catch return V{ .err = .memory };
  for (data) |val| {
    var found = false;
    for (res_list.items) |s| if (val.eq(s)) { found = true; break; };
    if (!found) res_list.appendAssumeCapacity(val.ref());
  }
  const res = N(V).init(alloc, res_list.items.len) catch return V{ .err = .memory };
  @memcpy(res.slice(), res_list.items);
  res_list.deinit(alloc);
  return promote(alloc, res);
}

