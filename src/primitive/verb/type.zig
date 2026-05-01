const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Type = struct {
  pub const op = .@"@";
  _blank: util.MonadFn = ktype(""),
  _b:     util.MonadFn = ktype("i"),
  _i:     util.MonadFn = ktype("i"),
  _f:     util.MonadFn = ktype("f"),
  _s:     util.MonadFn = ktype("s"),
  _c:     util.MonadFn = ktype("c"),
  _B:     util.MonadFn = ktype("I"),
  _I:     util.MonadFn = ktype("I"),
  _F:     util.MonadFn = ktype("F"),
  _S:     util.MonadFn = ktype("S"),
  _C:     util.MonadFn = ktype("C"),
  _L:     util.MonadFn = ktype("L"),
  _m:     util.MonadFn = ktype("m"),
  _M:     util.MonadFn = ktype("M"),
  _func:  util.MonadFn = ktype("func"),
  _partial: util.MonadFn = ktype("p"),
  _err:     util.MonadFn = ktype("!"),
};

fn ktype(comptime s: []const u8) util.MonadFn {
  return struct {
    fn f(vm: *VM, _: V) V { return .{ .s = vm.intern(s) catch return V{ .err = .memory } }; }
  }.f;
}
