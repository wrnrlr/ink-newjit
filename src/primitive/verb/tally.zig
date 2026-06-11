const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const h = @import("helper.zig");

fn tally(_: *VM, x: V) V { return .{ .i = @intCast(x.len()) }; }

pub const Tally      = h._Y(.@"#",  &h.all_types, tally);
pub const Count_Name = h._Y(.count, &h.all_types, tally);
