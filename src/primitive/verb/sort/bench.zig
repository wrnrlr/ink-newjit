const std = @import("std");
const mergesort = @import("mergesort.zig");
const timsort = @import("timsort.zig");
const radixsort = @import("radixsort.zig");

fn nanos() u64 {
  var ts: std.c.timespec = undefined;
  _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
  return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn Context(comptime T: type) type {
  return struct {
    data: T,
    desc: bool,
    fn cmp(self: @This(), lhs: usize, rhs: usize) bool {
      const a = self.data[lhs];
      const b = self.data[rhs];
      if (a == b) return true;
      return if (self.desc) a > b else a < b;
    }
  };
}

test "benchmark sort algorithms" {
  const alloc = std.testing.allocator;
  const sizes = [_]usize{ 1_000, 10_000, 100_000 };
  var prng = std.Random.DefaultPrng.init(0xdeadbeef);
  const rng = prng.random();

  std.debug.print("\n--- sort benchmark (i64 ascending, random data) ---\n", .{});
  std.debug.print("{s:>10}  {s:>12}  {s:>12}  {s:>12}\n",
    .{ "n", "mergesort", "timsort", "radixsort" });

  for (sizes) |n| {
    const data = try alloc.alloc(i64, n);
    defer alloc.free(data);
    for (data) |*x| x.* = rng.int(i64);

    const idx_buf = try alloc.alloc(usize, n);
    defer alloc.free(idx_buf);

    const Ctx = Context([]const i64);
    const ctx = Ctx{ .data = data, .desc = false };

    for (0..n) |i| idx_buf[i] = i;
    var t0 = nanos();
    try mergesort.sort(alloc, idx_buf, ctx, Ctx.cmp);
    const ms_us = (nanos() - t0) / 1000;

    for (0..n) |i| idx_buf[i] = i;
    t0 = nanos();
    try timsort.sort(alloc, idx_buf, ctx, Ctx.cmp);
    const ts_us = (nanos() - t0) / 1000;

    for (0..n) |i| idx_buf[i] = i;
    t0 = nanos();
    try radixsort.sortI64(alloc, idx_buf, data, false);
    const rs_us = (nanos() - t0) / 1000;

    std.debug.print("{d:>10}  {d:>9}µs  {d:>9}µs  {d:>9}µs\n",
      .{ n, ms_us, ts_us, rs_us });
  }
}
