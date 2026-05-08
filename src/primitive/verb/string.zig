const std = @import("std");
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const TerseFormatter = @import("../../noun/format.zig").TerseFormatter;
const MockWriter = @import("../../util.zig").MockWriter;
const util = @import("../../util.zig");

// TODO maybe we can jump to the precize type directly
pub const Format = struct {
  pub const op = .@"$";
  _b: util.MonadFn = fmt,
  _i: util.MonadFn = fmt,
  _f: util.MonadFn = fmt,
  _s: util.MonadFn = fmt,
  _c: util.MonadFn = fmt,
  _g: util.MonadFn = fmt,
  _B: util.MonadFn = fmt,
  _I: util.MonadFn = fmt,
  _F: util.MonadFn = fmt,
  _S: util.MonadFn = fmt,
  _C: util.MonadFn = fmt,
  _T: util.MonadFn = fmt,
  _D: util.MonadFn = fmt,
  _G: util.MonadFn = fmt,
  _L: util.MonadFn = fmt,
  _m: util.MonadFn = fmt,
  _M: util.MonadFn = fmt,
  _y: util.MonadFn = fmt,
  _v: util.MonadFn = fmt,
  _p: util.MonadFn = fmt,
  _q: util.MonadFn = fmt,
};

// TODO: Move Formatter to VM
fn fmt(vm: *VM, x: V) V {
  var mock = MockWriter.init(vm.alloc) catch return V{ .err = .memory };
  defer mock.deinit();
  var tf = TerseFormatter.init(vm, vm.alloc, .Text);
  var f = tf.formatter();
  var w = mock.writer();
  f.format(x, &w.interface) catch return V{ .err = .io };
  return V.Chars(vm.alloc, mock.getText()) catch return V{ .err = .memory };
}
