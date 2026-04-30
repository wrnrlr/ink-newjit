const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const N = @import("../../noun/value.zig").N;
const Rc = @import("../../noun/value.zig").Rc;
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Iota = struct {
  pub const op = .@"!";
  _i: util.MonadFn = iota,
};

// Dispatch iota to the GPU when a backend is attached and n is big
// enough to amortize launch + arena alloc cost.
const GPU_THRESHOLD: i32 = 4096;

pub fn iota(vm: *VM, x: V) !V {
  const n = x.i;
  if (n > 0 and n <= IOTA_MAX) {
    // Return a view into the static pool — zero allocation.
    return .{ .I = .{ .ptr = poolEntry(@intCast(n)) } };
  }
  if (vm.gpu) |g| if (n >= GPU_THRESHOLD) {
    const count: u32 = @intCast(n);
    const range = try g.allocRange(count * @sizeOf(i32));
    try g.iotaI32(range, count);
    return .{ .I = try N(i32).initGpu(g, range, count) };
  };
  return if (x.i > 0)
    .{.I=try N(i32).fromRange(vm.alloc, 0, 1, @intCast(x.i))}
  else
    .{.I=try N(i32).fromRange(vm.alloc, x.i, 1, @intCast(-x.i))};
}

pub const IOTA_MAX: usize = 256;

const NI = N(i32);
const alignment = NI.alignment;
const data_offset = NI.data_offset;

// Each entry: data_offset bytes of header + n * @sizeOf(i32) bytes of data.
// data_offset == 8 for i32 (Header is 8 bytes, alignOf(i32) == 8).
const OFFSETS: [IOTA_MAX + 1]usize = blk: {
  var offs: [IOTA_MAX + 1]usize = undefined;
  var pos: usize = 0;
  for (0..IOTA_MAX + 1) |n| {
    offs[n] = pos;
    pos += data_offset + n * @sizeOf(i32);
  }
  break :blk offs;
};

const POOL_SIZE: usize = OFFSETS[IOTA_MAX] + data_offset + IOTA_MAX * @sizeOf(i32);

// Mutable so we can hand out aligned pointers; never mutated at runtime (maxInt(u32) guard).
var pool: [POOL_SIZE]u8 align(alignment) = blk: {
  @setEvalBranchQuota(1_000_000);
  var buf = [_]u8{0} ** POOL_SIZE;
  for (0..IOTA_MAX + 1) |n| {
    const off = OFFSETS[n];
    const header = Rc{ .rc = std.math.maxInt(u32), .len = @intCast(n) };
    const header_bytes = std.mem.toBytes(header);
    for (header_bytes, 0..) |b, j| buf[off + j] = b;
    for (0..n) |i| {
      const v: i32 = @intCast(i);
      const v_bytes = std.mem.toBytes(v);
      for (v_bytes, 0..) |b, j| buf[off + data_offset + i * @sizeOf(i32) + j] = b;
    }
  }
  break :blk buf;
};

fn poolEntry(n: usize) *align(alignment) Rc {
  return @ptrCast(@alignCast(&pool[OFFSETS[n]]));
}
