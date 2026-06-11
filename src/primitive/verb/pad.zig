const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

pub const Pad = struct {
  pub const op = .@"$";
  _i_C: VM.Dyad = pad,
};

fn pad(vm: *VM, x: V, y: V) V {
  const n: usize = @intCast(@abs(x.i));
  const r = N(u8).init(vm.alloc, n) catch return V{ .err = .memory };
  const slice = r.slice();
  @memset(slice, ' ');
  const s = y.C.slice();
  if (x.i >= 0) {
    const lMin = @min(s.len, n);
    @memcpy(slice[0..lMin], s[0..lMin]);
  } else {
    if (n >= s.len) @memcpy(slice[n - s.len ..], s)
    else @memcpy(slice, s[s.len - n ..]);
  }
  return .{ .C = r };
}
