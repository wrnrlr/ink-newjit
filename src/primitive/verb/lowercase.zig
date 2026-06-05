const std = @import("std");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const LowercaseOp = struct {
  pub fn f(x: anytype) @TypeOf(x) { return std.ascii.toLower(@intCast(x)); }
};

pub const Lowercase = struct {
  pub const op = .@"_";
  _c: util.MonadFn = lowercase_c,
  _C: util.MonadFn = lowercase_C,
  // TODO lowercase of symbol?
};

fn lowercase_c(_: *VM, x: V) V {
  return .{ .c = std.ascii.toLower(@intCast(x.c)) };
}

fn lowercase_C(vm: *VM, x: V) V {
  const res = N(u8).init(vm.alloc, x.C.ptr.len) catch return V{ .err = .memory };
  for (x.C.slice(), res.slice()) |v, *r| r.* = std.ascii.toLower(v);
  return .{ .C = res };
}
