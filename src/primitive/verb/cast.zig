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

// Clamp helpers into the natural range [0, 2^32).
fn i2n(v: i32) u32 { return if (v < 0) 0 else @intCast(v); }
fn f2n(v: f32) u32 {
  if (std.math.isNan(v) or v <= 0) return 0;
  if (v >= 4294967296.0) return std.math.maxInt(u32);
  return @intFromFloat(v);
}

// The single numeric conversion matrix. One arm per (From→To) pair the casts
// use, preserving each operator exactly: clamping into naturals (i2n/f2n),
// truncating u32→c, and 0N-guarding the u32→i32 overflow. The bit-reinterpret
// forms (`` `I$f ``) are NOT here — those are a distinct verb, handled inline.
inline fn numCast(comptime From: type, comptime To: type, v: From) To {
  if (From == To) return v;
  return switch (To) {
    u8 => switch (From) {                 // → c
      i32 => @truncate(@as(u32, @bitCast(v))),  // wrap out-of-range (incl. neg) like u32→c
      u32 => @truncate(v),
      f32, f64, f16 => @intFromFloat(v),
      else => @compileError("no cast " ++ @typeName(From) ++ "→c"),
    },
    i32 => switch (From) {                 // → i
      u8 => @intCast(v),
      u32 => if (v > std.math.maxInt(i32)) V.@"0N" else @intCast(v),
      f32, f64, f16 => @intFromFloat(v),
      else => @compileError("no cast " ++ @typeName(From) ++ "→i"),
    },
    u32 => switch (From) {                 // → u
      i32 => i2n(v),
      f32 => f2n(v),
      f64, f16 => f2n(@floatCast(v)),
      else => @compileError("no cast " ++ @typeName(From) ++ "→u"),
    },
    f32 => switch (From) {                 // → f
      u8, i32, u32 => @floatFromInt(v),
      f64, f16 => @floatCast(v),
      else => @compileError("no cast " ++ @typeName(From) ++ "→f"),
    },
    f64 => switch (From) {                 // → d
      i32 => @floatFromInt(v),
      f32, f16 => @floatCast(v),
      else => @compileError("no cast " ++ @typeName(From) ++ "→d"),
    },
    f16 => switch (From) {                 // → h
      i32 => @floatFromInt(v),
      f32, f64 => @floatCast(v),
      else => @compileError("no cast " ++ @typeName(From) ++ "→h"),
    },
    else => @compileError("no cast target " ++ @typeName(To)),
  };
}

// Allocate a typed vector and fill it by casting every element From→To.
inline fn mapVec(vm: *VM, comptime From: type, comptime To: type, comptime vk: K, src: []const From) V {
  const res = N(To).init(vm.alloc, src.len) catch return V{ .err = .memory };
  for (src, res.slice()) |v, *d| d.* = numCast(From, To, v);
  return V.wrap(vk, res);
}

fn castChar(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  return if (eql(u8, t, "c")) y
         else if (eql(u8, t, "i")) V.wrap(.i, numCast(u8, i32, y.c))
         else if (eql(u8, t, "f")) V.wrap(.f, numCast(u8, f32, y.c))
         else .{ .err = .domain };
}

fn castInt(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  return if (eql(u8, t, "c")) V.wrap(.c, numCast(i32, u8,  y.i))
         else if (eql(u8, t, "i")) y
         else if (eql(u8, t, "f")) V.wrap(.f, numCast(i32, f32, y.i))
         else if (eql(u8, t, "u")) V.wrap(.n, numCast(i32, u32, y.i))
         else if (eql(u8, t, "d")) V.wrap(.d, numCast(i32, f64, y.i))
         else if (eql(u8, t, "h")) V.wrap(.h, numCast(i32, f16, y.i))
         else .{ .err = .domain };
}

fn castFloat(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  return if (eql(u8, t, "c")) V.wrap(.c, numCast(f32, u8,  y.f))
         else if (eql(u8, t, "i")) V.wrap(.i, numCast(f32, i32, y.f))
         else if (eql(u8, t, "f")) y
         else if (eql(u8, t, "u")) V.wrap(.n, numCast(f32, u32, y.f))
         else if (eql(u8, t, "d")) V.wrap(.d, numCast(f32, f64, y.f))
         else if (eql(u8, t, "h")) V.wrap(.h, numCast(f32, f16, y.f))
         else if (eql(u8, t, "I")) .{ .i = @bitCast(y.f) }  // bit reinterpret
         else .{ .err = .domain };
}

// f64 / f16 scalar → other types. Identity on same width.
fn castDbl(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  return if (eql(u8, t, "d")) y
         else if (eql(u8, t, "f")) V.wrap(.f, numCast(f64, f32, y.d))
         else if (eql(u8, t, "h")) V.wrap(.h, numCast(f64, f16, y.d))
         else if (eql(u8, t, "i")) V.wrap(.i, numCast(f64, i32, y.d))
         else if (eql(u8, t, "u")) V.wrap(.n, numCast(f64, u32, y.d))
         else .{ .err = .domain };
}
fn castHlf(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  return if (eql(u8, t, "h")) y
         else if (eql(u8, t, "f")) V.wrap(.f, numCast(f16, f32, y.h))
         else if (eql(u8, t, "d")) V.wrap(.d, numCast(f16, f64, y.h))
         else if (eql(u8, t, "i")) V.wrap(.i, numCast(f16, i32, y.h))
         else if (eql(u8, t, "u")) V.wrap(.n, numCast(f16, u32, y.h))
         else .{ .err = .domain };
}

// Natural (u32) scalar → other types. Clamps out-of-range, identity on `u32`.
fn castNat(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  return if (eql(u8, t, "u")) y
         else if (eql(u8, t, "i")) V.wrap(.i, numCast(u32, i32, y.n))
         else if (eql(u8, t, "f")) V.wrap(.f, numCast(u32, f32, y.n))
         else if (eql(u8, t, "c")) V.wrap(.c, numCast(u32, u8,  y.n))
         else .{ .err = .domain };
}

fn castChars(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  const src = y.C.slice();
  if (eql(u8, t, "c")) {
    return y.ref();  // identity: caller releases y, so hand back a retained ref
  } else if (eql(u8, t, "i")) {
    return mapVec(vm, u8, i32, .I, src);
  } else if (eql(u8, t, "f")) {
    return mapVec(vm, u8, f32, .F, src);
  } else if (eql(u8, t, "I")) {
    const n = std.fmt.parseInt(i32, std.mem.trim(u8, src, " "), 10) catch return .{ .i = V.@"0N" };
    return .{ .i = n };
  } else if (eql(u8, t, "F")) {
    const f = std.fmt.parseFloat(f32, std.mem.trim(u8, src, " ")) catch return .{ .f = std.math.nan(f32) };
    return .{ .f = f };
  } else if (eql(u8, t, "s") or eql(u8, t, "")) {
    return .{ .s = vm.intern(src) catch return V{ .err = .memory } };
  } else return .{ .err = .domain };
}

fn castInts(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  const src = y.I.slice();
  return if (eql(u8, t, "i")) y.ref()  // identity: hand back a retained ref
         else if (eql(u8, t, "c")) mapVec(vm, i32, u8,  .C, src)
         else if (eql(u8, t, "f")) mapVec(vm, i32, f32, .F, src)
         else if (eql(u8, t, "u")) mapVec(vm, i32, u32, .N, src)
         else if (eql(u8, t, "d")) mapVec(vm, i32, f64, .D, src)
         else if (eql(u8, t, "h")) mapVec(vm, i32, f16, .H, src)
         else .{ .err = .domain };
}

fn castFloats(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  const src = y.F.slice();
  if (eql(u8, t, "f")) return y.ref();  // identity: hand back a retained ref
  if (eql(u8, t, "I")) {                // bit reinterpret f32→i32
    const res = N(i32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @bitCast(v);
    return .{ .I = res };
  }
  return if (eql(u8, t, "c")) mapVec(vm, f32, u8,  .C, src)
         else if (eql(u8, t, "i")) mapVec(vm, f32, i32, .I, src)
         else if (eql(u8, t, "u")) mapVec(vm, f32, u32, .N, src)
         else if (eql(u8, t, "d")) mapVec(vm, f32, f64, .D, src)
         else if (eql(u8, t, "h")) mapVec(vm, f32, f16, .H, src)
         else .{ .err = .domain };
}

// f64 / f16 vectors → other typed vectors.
fn castDbls(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  const src = y.D.slice();
  return if (eql(u8, t, "d")) y.ref()
         else if (eql(u8, t, "f")) mapVec(vm, f64, f32, .F, src)
         else if (eql(u8, t, "h")) mapVec(vm, f64, f16, .H, src)
         else if (eql(u8, t, "i")) mapVec(vm, f64, i32, .I, src)
         else .{ .err = .domain };
}
fn castHlfs(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  const src = y.H.slice();
  return if (eql(u8, t, "h")) y.ref()
         else if (eql(u8, t, "f")) mapVec(vm, f16, f32, .F, src)
         else if (eql(u8, t, "d")) mapVec(vm, f16, f64, .D, src)
         else if (eql(u8, t, "i")) mapVec(vm, f16, i32, .I, src)
         else .{ .err = .domain };
}

// Natural (u32) vector → other typed vectors.
fn castNats(vm: *VM, x: V, y: V) V {
  const t = vm.getSymbol(x.s);
  const src = y.N.slice();
  return if (eql(u8, t, "u")) y.ref()  // identity: hand back a retained ref
         else if (eql(u8, t, "i")) mapVec(vm, u32, i32, .I, src)
         else if (eql(u8, t, "f")) mapVec(vm, u32, f32, .F, src)
         else if (eql(u8, t, "c")) mapVec(vm, u32, u8,  .C, src)
         else .{ .err = .domain };
}
