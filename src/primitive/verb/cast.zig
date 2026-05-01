const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const V = value.V;
const N = value.N;
const VM = @import("../../runtime/vm.zig").VM;
const eql = std.mem.eql;

pub const Cast = struct {
  pub const op = .@"$";

  _s_c: util.DyadFn = castChar,
  _s_i: util.DyadFn = castInt,
  _s_f: util.DyadFn = castFloat,
  
  _s_C: util.DyadFn = castChars,
  _s_I: util.DyadFn = castInts,
  _s_F: util.DyadFn = castFloats,
  
  // _s_m: util.DyadFn = castFloats,
  // _s_M: util.DyadFn = castFloats,
  // _s_L: util.DyadFn = castFloats,
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
         else .{ .err = .domain };
}


fn castFloat(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  return if (eql(u8, type_name, "c")) .{ .c = @intFromFloat(y.f) }
         else if (eql(u8, type_name, "i")) .{ .i = @intFromFloat(y.f) }
         else if (eql(u8, type_name, "f")) y
         else .{ .err = .domain };
}

fn castChars(vm: *VM, x: V, y: V) V {
  const type_name = vm.getSymbol(x.s);
  const src = y.C.slice();
  if (eql(u8, type_name, "c")) {
    return y;
  } else if (eql(u8, type_name, "i")) {
    const res = N(i32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @intCast(v);
    return .{ .I = res };
  } else if (eql(u8, type_name, "f")) {
    const res = N(f32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatFromInt(v);
    return .{ .F = res };
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
    return y;
  } else if (eql(u8, type_name, "f")) {
    const res = N(f32).init(vm.alloc, src.len) catch return V{ .err = .memory };
    for (src, res.slice()) |v, *d| d.* = @floatFromInt(v);
    return .{ .F = res };
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
    return y;
  } else return .{ .err = .domain };
}

// fn castDict(vm: *VM, x: V, y: V) V {
  
// }
