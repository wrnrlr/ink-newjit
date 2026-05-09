const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

/// B_Y: keep elements of y where the bool mask is false (weed out truthy rows).
pub const WeedOut = struct {
  pub const op = .@"_";
  _B_I: util.DyadFn = weedOutI,
  _B_F: util.DyadFn = weedOutF,
  _B_S: util.DyadFn = weedOutS,
  _B_C: util.DyadFn = weedOutC,
  _B_B: util.DyadFn = weedOutB,
  _B_L: util.DyadFn = weedOutL,
  _B_M: util.DyadFn = weedOutA,
};

fn weedOutI(vm: *VM, x: V, y: V) V { return filterTyped(.I, i32,  vm.alloc, x.B.slice(), y.I.slice()); }
fn weedOutF(vm: *VM, x: V, y: V) V { return filterTyped(.F, f32,  vm.alloc, x.B.slice(), y.F.slice()); }
fn weedOutS(vm: *VM, x: V, y: V) V { return filterTyped(.S, u32,  vm.alloc, x.B.slice(), y.S.slice()); }
fn weedOutC(vm: *VM, x: V, y: V) V { return filterTyped(.C, u8,   vm.alloc, x.B.slice(), y.C.slice()); }
fn weedOutB(vm: *VM, x: V, y: V) V { return filterTyped(.B, bool, vm.alloc, x.B.slice(), y.B.slice()); }
fn weedOutL(vm: *VM, x: V, y: V) V { return filterGeneric(vm.alloc, x.B.slice(), y); }
fn weedOutA(vm: *VM, x: V, y: V) V { return filterTable(vm.alloc, x.B.slice(), y.M); }

/// Keep data[i] where mask[i] is false. Returns a typed V.
fn filterTyped(
  comptime k: K, comptime T: type,
  alloc: Alloc, mask: []const bool, data: []const T,
) V {
  var count: usize = 0;
  for (mask) |keep| if (!keep) { count += 1; };
  const res = N(T).init(alloc, count) catch return V{ .err = .memory };
  var j: usize = 0;
  for (mask, data) |keep, v| if (!keep) { res.slice()[j] = v; j += 1; };
  return @unionInit(V, @tagName(k), res);
}

fn filterTable(alloc: Alloc, mask: []const bool, t: Dict) V {
  const keys = t.av();
  const vals = t.bv();
  const n_cols = keys.len();
  const res_vals_n = N(V).init(alloc, n_cols) catch return V{ .err = .memory };
  @memset(res_vals_n.slice(), .blank);
  for (0..n_cols) |i| {
    const col = vals.at(i);
    defer col.deinit(alloc);
    res_vals_n.slice()[i] = switch (col) {
      .I => |n| filterTyped(.I, i32,  alloc, mask, n.slice()),
      .F => |n| filterTyped(.F, f32,  alloc, mask, n.slice()),
      .S => |n| filterTyped(.S, u32,  alloc, mask, n.slice()),
      .C => |n| filterTyped(.C, u8,   alloc, mask, n.slice()),
      .B => |n| filterTyped(.B, bool, alloc, mask, n.slice()),
      else => filterGeneric(alloc, mask, col),
    };
  }
  return V{ .M = Dict.init(alloc, keys.ref(), .{ .L = res_vals_n }) catch return V{ .err = .memory } };
}

/// Generic fallback: works for any f/y combination (L, integer mask, etc.)
fn filterGeneric(alloc: Alloc, mask: []const bool, y: V) V {
  const ylen = y.len();
  var res_list: std.ArrayList(V) = .empty;
  defer res_list.deinit(alloc);
  res_list.ensureTotalCapacity(alloc, ylen) catch return V{ .err = .memory };
  for (mask, 0..) |keep, i| {
    if (!keep) res_list.appendAssumeCapacity(y.at(i));
  }
  const res = N(V).init(alloc, res_list.items.len) catch return V{ .err = .memory };
  @memcpy(res.slice(), res_list.items);
  res_list.items.len = 0;
  return promote(alloc, res);

}

const testing = std.testing;

test "weedout int array" {
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  const mask = try V.make(.B, bool, vm.alloc, &.{ false, true, false });
  defer mask.deinit(vm.alloc);
  const data = try V.make(.I, i32, vm.alloc, &.{ 10, 20, 30 });
  defer data.deinit(vm.alloc);
  const res = weedOutI(vm, mask, data);
  defer res.deinit(vm.alloc);
  try testing.expectEqual(K.I, res.tag());
  try testing.expectEqualSlices(i32, &.{ 10, 30 }, res.I.slice());
}

test "weedout char array" {
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  const mask = try V.make(.B, bool, vm.alloc, &.{ true, false, true, false, true });
  defer mask.deinit(vm.alloc);
  const data = try V.make(.C, u8, vm.alloc, "aeiou");
  defer data.deinit(vm.alloc);
  const res = weedOutC(vm, mask, data);
  defer res.deinit(vm.alloc);
  try testing.expectEqual(K.C, res.tag());
  try testing.expectEqualSlices(u8, "eo", res.C.slice());
}

test "weedout float array" {
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  const mask = try V.make(.B, bool, vm.alloc, &.{ false, false, true });
  defer mask.deinit(vm.alloc);
  const data = try V.make(.F, f32, vm.alloc, &.{ 1.1, 2.2, 3.3 });
  defer data.deinit(vm.alloc);
  const res = weedOutF(vm, mask, data);
  defer res.deinit(vm.alloc);
  try testing.expectEqual(K.F, res.tag());
  try testing.expectEqualSlices(f32, &.{ 1.1, 2.2 }, res.F.slice());
}

test "weedout keep all" {
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  const mask = try V.make(.B, bool, vm.alloc, &.{ false, false, false });
  defer mask.deinit(vm.alloc);
  const data = try V.make(.I, i32, vm.alloc, &.{ 1, 2, 3 });
  defer data.deinit(vm.alloc);
  const res = weedOutI(vm, mask, data);
  defer res.deinit(vm.alloc);
  try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, res.I.slice());
}

test "weedout remove all" {
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  const mask = try V.make(.B, bool, vm.alloc, &.{ true, true, true });
  defer mask.deinit(vm.alloc);
  const data = try V.make(.I, i32, vm.alloc, &.{ 1, 2, 3 });
  defer data.deinit(vm.alloc);
  const res = weedOutI(vm, mask, data);
  defer res.deinit(vm.alloc);
  try testing.expectEqual(@as(usize, 0), res.I.slice().len);
}
