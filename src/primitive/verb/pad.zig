const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const TerseFormatter = @import("../../noun/format.zig").TerseFormatter;
const util = @import("../../util.zig");
const MockWriter = util.MockWriter;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

pub const Pad = struct {
  pub const op = .@"$";
  
  // _i_C: util.DyadFn = pad, // TODO
  _i_C: util.DyadFn = pad,
};

fn pad(vm: *VM, x: V, y: V) V {
  const i = x.i;
  const s = y.C.slice();
  const target_len: usize = @intCast(@abs(i));
  const res = N(u8).init(vm.alloc, target_len) catch return V{ .err = .memory };
  const slice = res.slice();
  @memset(slice, ' ');

  if (i >= 0) {
    // Right pad: "abc  "
    const copy_len = @min(s.len, target_len);
    @memcpy(slice[0..copy_len], s[0..copy_len]);
  } else {
    // Left pad: "  abc"
    if (target_len >= s.len) @memcpy(slice[target_len - s.len ..], s)
    else @memcpy(slice, s[s.len - target_len ..]);
  }
  return .{ .C = res };
}
