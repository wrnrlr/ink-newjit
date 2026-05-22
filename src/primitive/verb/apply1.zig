const std = @import("std");
const value = @import("../../noun/value.zig");
const calc = @import("./calc.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const Dict = value.Dict;
const Alloc = std.mem.Allocator;

const pick = @import("pick.zig");

pub const Apply1 = struct {
  pub const op = .@"@";

};
