const std = @import("std");
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const TerseFormatter = @import("../../noun/format.zig").TerseFormatter;
const MockWriter = @import("../../util.zig").MockWriter;
const util = @import("../../util.zig");

// TODO maybe we can jump to the precize type directly
pub const Format = struct {
  pub const op = .@"$";
  _b: VM.Monad = fmt,
  _i: VM.Monad = fmt,
  _f: VM.Monad = fmt,
  _s: VM.Monad = fmt,
  _c: VM.Monad = fmt,
  _o: VM.Monad = fmt,
  _p: VM.Monad = fmt,
  _x: VM.Monad = fmt,
  _B: VM.Monad = fmt,
  _I: VM.Monad = fmt,
  _F: VM.Monad = fmt,
  _S: VM.Monad = fmt,
  _C: VM.Monad = fmt,
  _L: VM.Monad = fmt,
  _m: VM.Monad = fmt,
  _M: VM.Monad = fmt,
};

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
