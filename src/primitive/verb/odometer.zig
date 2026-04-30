const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const N = @import("../../noun/value.zig").N;
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

fn odometerFn(vm: *VM, x: V) !V { return .{ .L = try odometer(vm.alloc, x.I) }; }

pub const Odometer = struct {
  pub const op = .@"!";
  _I: util.MonadFn = odometerFn,
};

pub fn odometer(alloc: Alloc, shape: N(i32)) !N(V) {
  const shape_slice = shape.slice();
  var ncols: usize = 1;
  for (shape_slice) |xi| {
    if (xi <= 0) {
      const r_list = try N(V).init(alloc, shape.ptr.len);
      @memset(r_list.slice(), .blank);
      return r_list;
    }
    ncols *= @as(usize, @intCast(xi));
  }
  const r_list = try N(V).init(alloc, shape.ptr.len);
  var reps = ncols;
  for (shape_slice, 0..) |xi, i| {
    const x_usize = @as(usize, @intCast(xi));
    reps /= x_usize;
    const row = try N(i32).init(alloc, ncols);
    odometerRow(row.slice(), x_usize, reps);
    r_list.slice()[i] = .{ .I = row };
  }
  return r_list;
}

fn odometerRow(a: []i32, x: usize, reps: usize) void {
  const period = x * reps;
  // Fill one period: each value j repeated reps times
  if (reps == 1) {
    for (0..x) |j| a[j] = @intCast(j);
  } else {
    var jk: usize = 0;
    for (0..x) |j| {
      @memset(a[jk..jk + reps], @intCast(j));
      jk += reps;
    }
  }
  // Tile the period across the rest of the row (no overlap: period ≤ i always)
  var i = period;
  while (i < a.len) {
    const end = @min(i + period, a.len);
    @memcpy(a[i..end], a[0..end - i]);
    i += period;
  }
}

test "odometer 2 3" {
  const alloc = std.testing.allocator;
  const shape = try N(i32).n1(alloc, &.{ 2, 3 });
  defer shape.deinit(alloc);
  var res = try odometer(alloc, shape);
  defer res.deinit(alloc);
  try std.testing.expectEqual(@as(usize, 2), res.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{ 0, 0, 0, 1, 1, 1 }, res.slice()[0].I.slice());
  try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2, 0, 1, 2 }, res.slice()[1].I.slice());
}

test "odometer 2 2 2" {
  const alloc = std.testing.allocator;
  const shape = try N(i32).n1(alloc, &.{ 2, 2, 2 });
  defer shape.deinit(alloc);
  var res = try odometer(alloc, shape);
  defer res.deinit(alloc);
  try std.testing.expectEqual(@as(usize, 3), res.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{ 0,0,0,0,1,1,1,1 }, res.slice()[0].I.slice());
  try std.testing.expectEqualSlices(i32, &.{ 0,0,1,1,0,0,1,1 }, res.slice()[1].I.slice());
  try std.testing.expectEqualSlices(i32, &.{ 0,1,0,1,0,1,0,1 }, res.slice()[2].I.slice());
}

test "odometer single dim" {
  const alloc = std.testing.allocator;
  const shape = try N(i32).n1(alloc, &.{4});
  defer shape.deinit(alloc);
  var res = try odometer(alloc, shape);
  defer res.deinit(alloc);
  try std.testing.expectEqual(@as(usize, 1), res.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3 }, res.slice()[0].I.slice());
}

test "odometer zero dimension returns blanks" {
  const alloc = std.testing.allocator;
  const shape = try N(i32).n1(alloc, &.{ 2, 0, 3 });
  defer shape.deinit(alloc);
  var res = try odometer(alloc, shape);
  defer res.deinit(alloc);
  try std.testing.expectEqual(@as(usize, 3), res.ptr.len);
  for (res.slice()) |v| try std.testing.expect(v == .blank);
}
