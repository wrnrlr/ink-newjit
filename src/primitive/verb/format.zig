const std = @import("std");
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const TerseFormatter = @import("../../noun/format.zig").TerseFormatter;
const MockWriter = @import("../../util.zig").MockWriter;
const util = @import("../../util.zig");

// TODO maybe we can jump to the precize type directly
pub const Format = struct {
  pub const op = .@"$";
  _b: VM.MonadFn = fmt,
  _i: VM.MonadFn = fmt,
  _f: VM.MonadFn = fmt,
  _s: VM.MonadFn = fmt,
  _c: VM.MonadFn = fmt,
  _o: VM.MonadFn = fmt,
  _p: VM.MonadFn = fmt,
  _x: VM.MonadFn = fmt,
  _B: VM.MonadFn = fmt,
  _I: VM.MonadFn = fmt,
  _F: VM.MonadFn = fmt,
  _S: VM.MonadFn = fmt,
  _C: VM.MonadFn = fmt,
  _L: VM.MonadFn = fmt,
  _m: VM.MonadFn = fmt,
  _M: VM.MonadFn = fmt,
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
