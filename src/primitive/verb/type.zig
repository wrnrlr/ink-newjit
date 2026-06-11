const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Type = struct {
  pub const op = .@"@";
  _blank: VM.Monad = ktype(""),
  _b:     VM.Monad = ktype("i"),
  _i:     VM.Monad = ktype("i"),
  _f:     VM.Monad = ktype("f"),
  _s:     VM.Monad = ktype("s"),
  _c:     VM.Monad = ktype("c"),
  _B:     VM.Monad = ktype("I"),
  _I:     VM.Monad = ktype("I"),
  _F:     VM.Monad = ktype("F"),
  _S:     VM.Monad = ktype("S"),
  _C:     VM.Monad = ktype("C"),
  _L:     VM.Monad = ktype("L"),
  _m:     VM.Monad = ktype("m"),
  _M:     VM.Monad = ktype("M"),
  _o:   VM.Monad = ktype("func"),
  _p:   VM.Monad = ktype("p"),
  _err: VM.Monad = ktype("!"),
};

fn ktype(comptime s: []const u8) VM.Monad {
  return struct {
    fn f(vm: *VM, _: V) V { return .{ .s = vm.intern(s) catch return V{ .err = .memory } }; }
  }.f;
}
