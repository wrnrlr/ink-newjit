const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const binary = @import("../../encoding/binary.zig");

/// Marshal/Serialize: value -> bytes
pub const Marshal = struct {
  pub const op = .@"?";
  _s_C: VM.Dyad = marshal_s_C,
  _s_B: VM.Dyad = marshal_s_B,
  _s_b: VM.Dyad = marshal_bin_only,
  _s_i: VM.Dyad = marshal_bin_only,
  _s_f: VM.Dyad = marshal_bin_only,
  _s_c: VM.Dyad = marshal_bin_only,
  _s_s: VM.Dyad = marshal_bin_only,
  _s_I: VM.Dyad = marshal_bin_only,
  _s_F: VM.Dyad = marshal_bin_only,
  _s_S: VM.Dyad = marshal_bin_only,
  _s_L: VM.Dyad = marshal_bin_only,
  _s_m: VM.Dyad = marshal_bin_only,
  _s_M: VM.Dyad = marshal_bin_only,
};

/// Unmarshal/Deserialize: bytes -> value
pub const Unmarshal = struct {
  pub const op = .@"@";
  _s_C: VM.Dyad = unmarshal_s_C,
  _s_B: VM.Dyad = unmarshal_s_B,
  _s_s: VM.Dyad = unmarshal_s_s,
  _s_i: VM.Dyad = unmarshal_s_i,
};

fn marshal_s_C(vm: *VM, x: V, y: V) V {
  const s = vm.getSymbol(x.s);
  if (std.mem.eql(u8, s, "bin")) return binary.serialize(vm.alloc, &vm.symbols, y) catch return V{ .err = .memory };
  return .{ .err = .domain };
}
fn marshal_s_B(vm: *VM, x: V, y: V) V {
  const s = vm.getSymbol(x.s);
  if (std.mem.eql(u8, s, "") or std.mem.eql(u8, s, "bin")) return binary.serialize(vm.alloc, &vm.symbols, y) catch return V{ .err = .memory };
  return .{ .err = .domain };
}
fn marshal_bin_only(vm: *VM, x: V, y: V) V {
  const s = vm.getSymbol(x.s);
  if (std.mem.eql(u8, s, "bin")) return binary.serialize(vm.alloc, &vm.symbols, y) catch return V{ .err = .memory };
  return .{ .err = .domain };
}

fn loadFile(alloc: Alloc, path: []const u8) ![]u8 {
  const io = std.Io.Threaded.global_single_threaded.io();
  return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(1024 * 1024 * 100));
}

fn unmarshal_s_C(vm: *VM, x: V, y: V) V {
  return unmarshalDispatch(vm, vm.getSymbol(x.s), y.C.slice());
}

fn unmarshal_s_B(vm: *VM, x: V, y: V) V {
  return unmarshalDispatch(vm, vm.getSymbol(x.s), std.mem.sliceAsBytes(y.B.slice()));
}

fn unmarshal_s_s(vm: *VM, x: V, y: V) V {
  const data = loadFile(vm.alloc, vm.getSymbol(y.s)) catch return .{ .err = .io };
  defer vm.alloc.free(data);
  return unmarshalDispatch(vm, vm.getSymbol(x.s), data);
}

fn unmarshal_s_i(vm: *VM, x: V, y: V) V {
  return unmarshalDispatch(vm, vm.getSymbol(x.s), vm.fs.getFileText(@intCast(y.i)));
}

fn unmarshalDispatch(vm: *VM, s: []const u8, data: []const u8) V {
  const eql = std.mem.eql;
  if (eql(u8, s, "bin")) return binary.deserialize(vm.alloc, &vm.symbols, data) catch return V{ .err = .memory };
  return .{ .err = .domain };
}
