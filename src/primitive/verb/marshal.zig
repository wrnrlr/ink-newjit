const std = @import("std");
const Alloc = std.mem.Allocator;
const N = @import("../../noun/value.zig").N;
const V = @import("../../noun/value.zig").V;
const K = @import("../../noun/class.zig").K;
const Dict = @import("../../noun/value.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const csv    = @import("../../encoding/csv.zig");
const json   = @import("../../encoding/json.zig");
const xml    = @import("../../encoding/xml.zig");
const binary = @import("../../encoding/binary.zig");
const font   = @import("../../encoding/font.zig");
const shp    = @import("../../encoding/shapefile.zig");

/// Marshal/Serialize: value -> bytes
pub const Marshal = struct {
  pub const op = .@"?";
  _s_C: util.DyadFn = marshal_s_C,
  _s_B: util.DyadFn = marshal_s_B,
  _s_b: util.DyadFn = marshal_bin_only,
  _s_i: util.DyadFn = marshal_bin_only,
  _s_f: util.DyadFn = marshal_bin_only,
  _s_c: util.DyadFn = marshal_bin_only,
  _s_s: util.DyadFn = marshal_bin_only,
  _s_I: util.DyadFn = marshal_bin_only,
  _s_F: util.DyadFn = marshal_bin_only,
  _s_S: util.DyadFn = marshal_bin_only,
  _s_T: util.DyadFn = marshal_bin_only,
  _s_D: util.DyadFn = marshal_bin_only,
  _s_G: util.DyadFn = marshal_bin_only,
  _s_L: util.DyadFn = marshal_bin_only,
  _s_m: util.DyadFn = marshal_bin_only,
  _s_M: util.DyadFn = marshal_bin_only,
  _s_a: util.DyadFn = marshal_bin_only,
};

/// Unmarshal/Deserialize: bytes -> value
pub const Unmarshal = struct {
  pub const op = .@"@";
  _s_C: util.DyadFn = unmarshal_s_C,
  _s_B: util.DyadFn = unmarshal_s_B,
  _s_s: util.DyadFn = unmarshal_s_s,
  _s_i: util.DyadFn = unmarshal_s_i,
};

fn marshal_s_C(vm: *VM, x: V, y: V) !V {
  const s = vm.getSymbol(x.s);
  if (std.mem.eql(u8, s, "bin")) return binary.serialize(vm.alloc, &vm.symbols, y);
  return .{ .err = .domain };
}
fn marshal_s_B(vm: *VM, x: V, y: V) !V {
  const s = vm.getSymbol(x.s);
  if (std.mem.eql(u8, s, "") or std.mem.eql(u8, s, "bin")) return binary.serialize(vm.alloc, &vm.symbols, y);
  return .{ .err = .domain };
}
fn marshal_bin_only(vm: *VM, x: V, y: V) !V {
  const s = vm.getSymbol(x.s);
  if (std.mem.eql(u8, s, "bin")) return binary.serialize(vm.alloc, &vm.symbols, y);
  return .{ .err = .domain };
}

fn loadFile(alloc: Alloc, path: []const u8) ![]u8 {
  const io = std.Io.Threaded.global_single_threaded.io();
  return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(1024 * 1024 * 100));
}

fn unmarshal_s_C(vm: *VM, x: V, y: V) !V {
  return unmarshalDispatch(vm, vm.getSymbol(x.s), y.C.slice());
}

fn unmarshal_s_B(vm: *VM, x: V, y: V) !V {
  return unmarshalDispatch(vm, vm.getSymbol(x.s), std.mem.sliceAsBytes(y.B.slice()));
}

fn unmarshal_s_s(vm: *VM, x: V, y: V) !V {
  const data = loadFile(vm.alloc, vm.getSymbol(y.s)) catch return .{ .err = .io };
  defer vm.alloc.free(data);
  return unmarshalDispatch(vm, vm.getSymbol(x.s), data);
}

fn unmarshal_s_i(vm: *VM, x: V, y: V) !V {
  return unmarshalDispatch(vm, vm.getSymbol(x.s), vm.registry.getFileText(@intCast(y.i)));
}

fn unmarshalDispatch(vm: *VM, s: []const u8, data: []const u8) !V {
  const eql = std.mem.eql;
  if (eql(u8, s, "bin"))  return binary.deserialize(vm.alloc, &vm.symbols, data);
  if (eql(u8, s, "font")) return font.parse(vm.alloc, &vm.symbols, data);
  if (eql(u8, s, "csv"))  return csv.parse(vm.alloc, &vm.symbols, data);
  if (eql(u8, s, "json")) return json.parse(vm.alloc, &vm.symbols, data);
  if (eql(u8, s, "xml"))  return xml.parse(vm.alloc, &vm.symbols, data);
  if (eql(u8, s, "shp"))  return shp.parseShp(vm.alloc, &vm.symbols, data);
  if (eql(u8, s, "shx"))  return shp.parseShx(vm.alloc, &vm.symbols, data);
  if (eql(u8, s, "dbf"))  return shp.parseDbf(vm.alloc, &vm.symbols, data);
  if (eql(u8, s, "prj"))  return shp.parsePrj(vm.alloc, &vm.symbols, data);
  if (eql(u8, s, "cpg"))  return shp.parseCpg(vm.alloc, &vm.symbols, data);
  return .{ .err = .domain };
}
