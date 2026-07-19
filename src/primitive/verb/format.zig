const std = @import("std");
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const TerseFormatter = @import("../../noun/format.zig").TerseFormatter;
const MockWriter = @import("../../util.zig").MockWriter;
const h = @import("helper.zig");

// TODO maybe we can jump to the precize type directly
pub const Format = h._Y(.@"$", &.{ .b, .i, .f, .s, .c, .o, .p, .x, .B, .I, .F, .S, .C, .L, .m, .M }, fmt);

// TODO: Move TerseFormatter instance to VM
fn fmt(vm: *VM, x: V) V {
  var mock = MockWriter.init(vm.alloc) catch return V{ .err = .memory };
  defer mock.deinit();
  var tf = TerseFormatter.init(vm, vm.alloc, .Text);
  var f = tf.formatter();
  var w = mock.writer();
  f.fmt(x, &w.interface) catch return V{ .err = .io };
  return V.Chars(vm.alloc, mock.getText()) catch return V{ .err = .memory };
}
