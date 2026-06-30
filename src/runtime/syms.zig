const std = @import("std");
const builtin = @import("builtin");
const eql = std.mem.eql;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const Dict = @import("../noun/dict.zig").Dict;
const VM = @import("vm.zig").VM;
const exec_mod = @import("../primitive/verb/exec.zig");

// Microsecond clock.  std.time has no timestamp fns and posix clock_gettime
// doesn't compile for Windows, so branch at comptime per platform.
extern "kernel32" fn GetSystemTimeAsFileTime(*std.os.windows.FILETIME) callconv(.winapi) void;

fn microsNow() i64 {
  if (builtin.os.tag == .windows) {
    var ft: std.os.windows.FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    // 100ns ticks since 1601; we only use it for relative timing, so the epoch
    // offset is irrelevant — convert ticks to microseconds.
    const ticks = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return @bitCast(@divTrunc(ticks, 10));
  } else {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return ts.sec * 1_000_000 + @divTrunc(ts.nsec, 1000);
  }
}

pub fn apply(vm: *VM, sym_idx: u32, args: []const V) !V {
  const name = vm.getSymbol(sym_idx);
  if (eql(u8, name, "t")) return .{ .i = @truncate(microsNow()) };
  if (eql(u8, name, "argv")) {
    const has_arg = args.len == 1 and args[0] != .blank;
    if (!has_arg) return vm.argv.ref();
    if (vm.argv == .blank) return V{ .err = .domain };
    const items = vm.argv.L.slice();
    const arg = args[0];
    if (arg.tag() != .i) return V{ .err = .@"type" };
    const idx = arg.i;
    if (idx < 0 or @as(usize, @intCast(idx)) >= items.len) return V{ .err = .domain };
    return items[@as(usize, @intCast(idx))].ref();
  }
  if (eql(u8, name, "env")) return getEnv(vm);
  if (eql(u8, name, "prng")) {
    const has_arg = args.len == 1 and args[0] != .blank;
    if (!has_arg) return getPrngState(vm);
    return setPrngState(vm, args[0]);
  }
  if (eql(u8, name, "x")) {
    if (args.len == 1 and args[0] != .blank) return forkExec(vm, args[0], null);
    if (args.len == 2 and args[0] != .blank) return forkExec(vm, args[0], args[1]);
    return V{ .err = .rank };
  }
  return V{ .err = .@"type" };
}

fn getPrngState(vm: *VM) V {
  const s = vm.prng.s;
  var arr: [8]i32 = undefined;
  for (s, 0..) |u, i| {
    arr[i * 2]     = @bitCast(@as(u32, @truncate(u)));
    arr[i * 2 + 1] = @bitCast(@as(u32, @truncate(u >> 32)));
  }
  return V.Ints(vm.alloc, &arr) catch V{ .err = .memory };
}

fn setPrngState(vm: *VM, v: V) V {
  if (v.tag() != .I or v.I.ptr.len != 8) return V{ .err = .length };
  const src = v.I.slice();
  for (0..4) |i| {
    vm.prng.s[i] = @as(u64, @as(u32, @bitCast(src[i*2]))) | (@as(u64, @as(u32, @bitCast(src[i*2+1]))) << 32);
  }
  return .blank;
}

fn getEnv(vm: *VM) !V {
  // std.c.environ doesn't exist on Windows; return an empty environment there.
  if (builtin.os.tag != .windows) return getEnvPosix(vm);
  const vals = try N(V).init(vm.alloc, 0);
  errdefer (V{ .L = vals }).deinit(vm.alloc);
  const keys = try V.Symbols(vm.alloc, &[_]u32{});
  return .{ .m = try Dict.init(vm.alloc, keys, V{ .L = vals }) };
}

fn getEnvPosix(vm: *VM) !V {
  var n: usize = 0;
  while (std.c.environ[n]) |_| n += 1;

  const keys_raw = try vm.alloc.alloc(u32, n);
  defer vm.alloc.free(keys_raw);

  const vals_n = try N(V).init(vm.alloc, n);
  errdefer (V{ .L = vals_n }).deinit(vm.alloc);
  @memset(vals_n.slice(), .blank);

  var i: usize = 0;
  var j: usize = 0;
  while (std.c.environ[i]) |entry_ptr| : (i += 1) {
    const entry = std.mem.span(entry_ptr);
    const sep = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
    keys_raw[j] = try vm.intern(entry[0..sep]);
    vals_n.slice()[j] = try V.Chars(vm.alloc, entry[sep + 1..]);
    j += 1;
  }

  const keys_v = try V.Symbols(vm.alloc, keys_raw[0..j]);
  errdefer keys_v.deinit(vm.alloc);
  vals_n.ptr.len = @intCast(j);

  return .{ .m = try Dict.init(vm.alloc, keys_v, V{ .L = vals_n }) };
}

fn forkExec(vm: *VM, cmd: V, stdin_v: ?V) !V {
  return exec_mod.execFromV(vm, cmd, stdin_v);
}
