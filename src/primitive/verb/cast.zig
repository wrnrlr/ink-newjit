const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const h = @import("helper.zig");
const eql = std.mem.eql;

pub const Cast = struct {
  pub const op = .@"$";

  _s_c: VM.Dyad = castChar,
  _s_i: VM.Dyad = castInt,
  _s_f: VM.Dyad = castFloat,
  _s_n: VM.Dyad = castNat,
  _s_d: VM.Dyad = castDbl,
  _s_h: VM.Dyad = castHlf,

  _s_C: VM.Dyad = castChars,
  _s_I: VM.Dyad = castInts,
  _s_F: VM.Dyad = castFloats,
  _s_N: VM.Dyad = castNats,
  _s_D: VM.Dyad = castDbls,
  _s_H: VM.Dyad = castHlfs,

  _s_L: VM.Dyad = h.containerFallback(.@"$"),
  _s_m: VM.Dyad = h.containerFallback(.@"$"),
  _s_M: VM.Dyad = h.containerFallback(.@"$"),
};

fn castChar(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  return if (eql(u8, type_name, "c")) y
         else if (eql(u8, type_name, "i")) .{ .i = @intCast(y.c) }
         else if (eql(u8, type_name, "f")) .{ .f = @floatFromInt(y.c) }
         else .{ .err = .domain };
}

fn castInt(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  return if (eql(u8, type_name, "c")) .{ .c = @intCast(y.i) }
         else if (eql(u8, type_name, "i")) y
         else if (eql(u8, type_name, "f")) .{ .f = @floatFromInt(y.i) }
         else if (eql(u8, type_name, "u")) .{ .n = i2n(y.i) }
         else if (eql(u8, type_name, "d")) .{ .d = @floatFromInt(y.i) }
         else if (eql(u8, type_name, "h")) .{ .h = @floatFromInt(y.i) }
         else .{ .err = .domain };
}


fn castFloat(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  return if (eql(u8, type_name, "c")) .{ .c = @intFromFloat(y.f) }
         else if (eql(u8, type_name, "i")) .{ .i = @intFromFloat(y.f) }
         else if (eql(u8, type_name, "f")) y
         else if (eql(u8, type_name, "u")) .{ .n = f2n(y.f) }
         else if (eql(u8, type_name, "d")) .{ .d = y.f }
         else if (eql(u8, type_name, "h")) .{ .h = @floatCast(y.f) }
         else if (eql(u8, type_name, "I")) .{ .i = @bitCast(y.f) }
         else .{ .err = .domain };
}

// f64 / f16 scalar → other types. Identity on same width.
fn castDbl(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  return if (eql(u8, t, "d")) y
         else if (eql(u8, t, "f")) .{ .f = @floatCast(y.d) }
         else if (eql(u8, t, "h")) .{ .h = @floatCast(y.d) }
         else if (eql(u8, t, "i")) .{ .i = @intFromFloat(y.d) }
         else if (eql(u8, t, "u")) .{ .n = f2n(@floatCast(y.d)) }
         else .{ .err = .domain };
}
fn castHlf(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  return if (eql(u8, t, "h")) y
         else if (eql(u8, t, "f")) .{ .f = @floatCast(y.h) }
         else if (eql(u8, t, "d")) .{ .d = @floatCast(y.h) }
         else if (eql(u8, t, "i")) .{ .i = @intFromFloat(y.h) }
         else if (eql(u8, t, "u")) .{ .n = f2n(@floatCast(y.h)) }
         else .{ .err = .domain };
}

// Natural (u32) scalar → other types. Clamps out-of-range on the way in
// (below), identity on `u32`.
fn castNat(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  return if (eql(u8, type_name, "u")) y
         else if (eql(u8, type_name, "i")) .{ .i = if (y.n > std.math.maxInt(i32)) V.@"0N" else @intCast(y.n) }
         else if (eql(u8, type_name, "f")) .{ .f = @floatFromInt(y.n) }
         else if (eql(u8, type_name, "c")) .{ .c = @truncate(y.n) }
         else .{ .err = .domain };
}

// Clamp helpers into the natural range [0, 2^32).
fn i2n(v: i32) u32 { return if (v < 0) 0 else @intCast(v); }
fn f2n(v: f32) u32 {
  if (std.math.isNan(v) or v <= 0) return 0;
  if (v >= 4294967296.0) return std.math.maxInt(u32);
  return @intFromFloat(v);
}

fn castChars(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  const src = y.C.slice();
  if (eql(u8, type_name, "c")) {
    return y.ref();  // identity: caller releases y, so hand back a retained ref
  } else if (eql(u8, type_name, "i")) {
    const res = N(i32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @intCast(v);
    return .{ .I = res };
  } else if (eql(u8, type_name, "f")) {
    const res = N(f32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatFromInt(v);
    return .{ .F = res };
  } else if (eql(u8, type_name, "I")) {
    const n = std.fmt.parseInt(i32, std.mem.trim(u8, src, " "), 10) catch return .{ .i = V.@"0N" };
    return .{ .i = n };
  } else if (eql(u8, type_name, "F")) {
    const f = std.fmt.parseFloat(f32, std.mem.trim(u8, src, " ")) catch return .{ .f = std.math.nan(f32) };
    return .{ .f = f };
  } else if (eql(u8, type_name, "s") or eql(u8, type_name, "")) {
    return .{ .s = vm.intern(src) catch return V{ .err = .memory } };
  } else return .{ .err = .domain };
}

fn castInts(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  const src = y.I.slice();
  if (eql(u8, type_name, "c")) {
    const res = N(u8).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @intCast(v);
    return .{ .C = res };
  } else if (eql(u8, type_name, "i")) {
    return y.ref();  // identity: caller releases y, so hand back a retained ref
  } else if (eql(u8, type_name, "f")) {
    const res = N(f32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatFromInt(v);
    return .{ .F = res };
  } else if (eql(u8, type_name, "u")) {
    const res = N(u32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = i2n(v);
    return .{ .N = res };
  } else if (eql(u8, type_name, "d")) {
    const res = N(f64).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatFromInt(v);
    return .{ .D = res };
  } else if (eql(u8, type_name, "h")) {
    const res = N(f16).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatFromInt(v);
    return .{ .H = res };
  } else return .{ .err = .domain };
}

fn castFloats(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  const src = y.F.slice();
  if (eql(u8, type_name, "c")) {
    const res = N(u8).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @intFromFloat(v);
    return .{ .C = res };
  } else if (eql(u8, type_name, "i")) {
    const res = N(i32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @intFromFloat(v);
    return .{ .I = res };
  } else if (eql(u8, type_name, "f")) {
    return y.ref();  // identity: caller releases y, so hand back a retained ref
  } else if (eql(u8, type_name, "u")) {
    const res = N(u32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = f2n(v);
    return .{ .N = res };
  } else if (eql(u8, type_name, "d")) {
    const res = N(f64).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = v;
    return .{ .D = res };
  } else if (eql(u8, type_name, "h")) {
    const res = N(f16).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatCast(v);
    return .{ .H = res };
  } else if (eql(u8, type_name, "I")) {
    const res = N(i32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @bitCast(v);
    return .{ .I = res };
  } else return .{ .err = .domain };
}

// f64 / f16 vectors → other typed vectors (f32, i, identity).
fn castDbls(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  const src = y.D.slice();
  if (eql(u8, t, "d")) {
    return y.ref();
  } else if (eql(u8, t, "f")) {
    const res = N(f32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatCast(v);
    return .{ .F = res };
  } else if (eql(u8, t, "h")) {
    const res = N(f16).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatCast(v);
    return .{ .H = res };
  } else if (eql(u8, t, "i")) {
    const res = N(i32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @intFromFloat(v);
    return .{ .I = res };
  } else return .{ .err = .domain };
}
fn castHlfs(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  const src = y.H.slice();
  if (eql(u8, t, "h")) {
    return y.ref();
  } else if (eql(u8, t, "f")) {
    const res = N(f32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatCast(v);
    return .{ .F = res };
  } else if (eql(u8, t, "d")) {
    const res = N(f64).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatCast(v);
    return .{ .D = res };
  } else if (eql(u8, t, "i")) {
    const res = N(i32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @intFromFloat(v);
    return .{ .I = res };
  } else return .{ .err = .domain };
}

// Natural (u32) vector → other typed vectors.
fn castNats(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  const src = y.N.slice();
  if (eql(u8, type_name, "u")) {
    return y.ref();  // identity: caller releases y, so hand back a retained ref
  } else if (eql(u8, type_name, "i")) {
    const res = N(i32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = if (v > std.math.maxInt(i32)) V.@"0N" else @intCast(v);
    return .{ .I = res };
  } else if (eql(u8, type_name, "f")) {
    const res = N(f32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatFromInt(v);
    return .{ .F = res };
  } else if (eql(u8, type_name, "c")) {
    const res = N(u8).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @truncate(v);
    return .{ .C = res };
  } else return .{ .err = .domain };
}
