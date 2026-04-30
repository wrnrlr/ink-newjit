const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const V = value.V;

// Monad handler: 9: cmd_list → {render:`gfx; cmds:L}
fn drawMonad(vm: *VM, x: V) !V {
  const keys = try V.symbolsFromSlice(vm.alloc, &[_]u32{
    try vm.intern("render"),
    try vm.intern("cmds"),
  });
  errdefer keys.deinit(vm.alloc);
  const vals = try V.valuesFromSlice(vm.alloc, &[_]V{
    V{ .s = try vm.intern("gfx") },
    x,
  });
  errdefer vals.deinit(vm.alloc);
  return V{ .m = try value.Dict.init(vm.alloc, keys, vals) };
}

// Dyad handler: h 9: cmds — integer window handle, ignores x → same as monad
fn drawDyad(vm: *VM, x: V, y: V) !V {
  _ = x;
  return drawMonad(vm, y);
}

// Dyad fallback: data 9: spec → {render:`plot; data:x; spec:y}
fn drawPlot(vm: *VM, x: V, y: V) !V {
  const keys = try V.symbolsFromSlice(vm.alloc, &[_]u32{
    try vm.intern("render"),
    try vm.intern("data"),
    try vm.intern("spec"),
  });
  errdefer keys.deinit(vm.alloc);
  const vals = try V.valuesFromSlice(vm.alloc, &[_]V{
    V{ .s = try vm.intern("plot") },
    x,
    y,
  });
  errdefer vals.deinit(vm.alloc);
  return V{ .m = try value.Dict.init(vm.alloc, keys, vals) };
}

// Monad dispatch table entry: 9: L  and  9: m
pub const Draw = struct {
  pub const op: @import("../../runtime/tape.zig").Op = .@"9:";
  _L: util.MonadFn = drawMonad,
  _m: util.MonadFn = drawMonad,
  _M: util.MonadFn = drawMonad,
  _s: util.MonadFn = drawMonad,
};

// Dyad dispatch table entries: i 9: L/m  and  data 9: spec
pub const DrawDyad = struct {
  pub const op: @import("../../runtime/tape.zig").Op = .@"9:";
  _i_L: util.DyadFn = drawDyad,
  _i_m: util.DyadFn = drawDyad,
  _i_M: util.DyadFn = drawDyad,
  // ` 9: cmds — blank symbol left = draw inline (same as monad on right)
  _s_L: util.DyadFn = drawDyad,
  _s_m: util.DyadFn = drawDyad,
  _s_M: util.DyadFn = drawDyad,
  _s_s: util.DyadFn = drawDyad,
  _M_L: util.DyadFn = drawPlot,
  _M_m: util.DyadFn = drawPlot,
  _m_L: util.DyadFn = drawPlot,
  _m_m: util.DyadFn = drawPlot,
};
