const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const Dict = @import("../../noun/dict.zig").Dict;
const util = @import("../../util.zig");
const V = value.V;

// Monad handler: 9: cmd_list → {render:`gfx; cmds:L}
fn drawMonad(vm: *VM, x: V) V {
  const keys = V.Symbols(vm.alloc, &[_]u32{
    vm.intern("render") catch return V{ .err = .memory },
    vm.intern("cmds") catch return V{ .err = .memory },
  }) catch return V{ .err = .memory };
  const vals = V.Values(vm.alloc, &[_]V{
    V{ .s = vm.intern("gfx") catch return V{ .err = .memory } },
    x,
  }) catch return V{ .err = .memory };
  return V{ .m = Dict.init(vm.alloc, keys, vals) catch return V{ .err = .memory } };
}

// Dyad handler: h 9: cmds — integer window handle, ignores x → same as monad
fn drawDyad(vm: *VM, x: V, y: V) V {
  _ = x;
  return drawMonad(vm, y);
}

// Dyad fallback: data 9: spec → {render:`plot; data:x; spec:y}
fn drawPlot(vm: *VM, x: V, y: V) V {
  const keys = V.Symbols(vm.alloc, &[_]u32{
    vm.intern("render") catch return V{ .err = .memory },
    vm.intern("data") catch return V{ .err = .memory },
    vm.intern("spec") catch return V{ .err = .memory },
  }) catch return V{ .err = .memory };
  const vals = V.Values(vm.alloc, &[_]V{
    V{ .s = vm.intern("plot") catch return V{ .err = .memory } },
    x,
    y,
  }) catch return V{ .err = .memory };
  return V{ .m = Dict.init(vm.alloc, keys, vals) catch return V{ .err = .memory } };
}

// Monad dispatch table entry: 9: L  and  9: m
pub const Draw = struct {
  pub const op = .@"9:";
  _L: VM.MonadFn = drawMonad,
  _m: VM.MonadFn = drawMonad,
  _M: VM.MonadFn = drawMonad,
  _s: VM.MonadFn = drawMonad,
};

// Dyad dispatch table entries: i 9: L/m  and  data 9: spec
pub const DrawDyad = struct {
  pub const op = .@"9:";
  _i_L: VM.DyadFn = drawDyad,
  _i_m: VM.DyadFn = drawDyad,
  _i_M: VM.DyadFn = drawDyad,
  // ` 9: cmds — blank symbol left = draw inline (same as monad on right)
  _s_L: VM.DyadFn = drawDyad,
  _s_m: VM.DyadFn = drawDyad,
  _s_M: VM.DyadFn = drawDyad,
  _s_s: VM.DyadFn = drawDyad,
  _M_L: VM.DyadFn = drawPlot,
  _M_m: VM.DyadFn = drawPlot,
  _m_L: VM.DyadFn = drawPlot,
  _m_m: VM.DyadFn = drawPlot,
};
