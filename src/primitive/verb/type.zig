const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Type = struct {
  pub const op = .@"@";
  _blank: VM.MonadFn = ktype(""),
  _b:     VM.MonadFn = ktype("i"),
  _i:     VM.MonadFn = ktype("i"),
  _f:     VM.MonadFn = ktype("f"),
  _s:     VM.MonadFn = ktype("s"),
  _c:     VM.MonadFn = ktype("c"),
  _B:     VM.MonadFn = ktype("I"),
  _I:     VM.MonadFn = ktype("I"),
  _F:     VM.MonadFn = ktype("F"),
  _S:     VM.MonadFn = ktype("S"),
  _C:     VM.MonadFn = ktype("C"),
  _L:     VM.MonadFn = ktype("L"),
  _m:     VM.MonadFn = ktype("m"),
  _M:     VM.MonadFn = ktype("M"),
  _o:   VM.MonadFn = ktype("func"),
  _p:   VM.MonadFn = ktype("p"),
  _err: VM.MonadFn = ktype("!"),
};

fn ktype(comptime s: []const u8) VM.MonadFn {
  return struct {
    fn f(vm: *VM, _: V) V { return .{ .s = vm.intern(s) catch return V{ .err = .memory } }; }
  }.f;
}
