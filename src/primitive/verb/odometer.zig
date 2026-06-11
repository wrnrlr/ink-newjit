const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

fn odometerFn(vm: *VM, x: V) V { return .{ .L = odometer(vm.alloc, x.I) catch return V{ .err = .memory } }; }

pub const Odometer = struct {
  pub const op = .@"!";
  _I: VM.Monad = odometerFn,
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
