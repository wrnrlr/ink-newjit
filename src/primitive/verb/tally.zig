const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const h = @import("helper.zig");

// An error is not a one-element value: measuring it would report `1`, which is
// TRUE, so `$[#f x; …]` on a failed call recurses instead of stopping. Errors
// propagate out of `#` rather than being counted.
fn tally(_: *VM, x: V) V {
  if (x.tag() == .err) return x;
  return .{ .i = @intCast(x.len()) };
}

pub const Tally      = h._Y(.@"#",  &h.all_types, tally);
pub const Count_Name = h._Y(.count, &h.all_types, tally);
