const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const h = @import("helper.zig");
const K = @import("../../noun/class.zig").K;

// An error is not a one-element value: measuring it would report `1`, which is
// TRUE, so `$[#f x; …]` on a failed call recurses instead of stopping. Errors
// propagate out of `#` rather than being counted.
fn tally(_: *VM, x: V) V {
  if (x.tag() == .err) return x;
  return .{ .i = @intCast(x.len()) };
}

// Callables count as the atoms they are: `#{x}` and `#::` are 1. Null used to
// have its own type slot here; now that it is the identity verb `::` it counts
// through the `.o` slot like any other verb.
const tally_types = h.all_types ++ [_]K{ .o, .p };

pub const Tally      = h._Y(.@"#",  &tally_types, tally);
pub const Count_Name = h._Y(.count, &tally_types, tally);
