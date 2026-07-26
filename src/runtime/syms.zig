const std = @import("std");
const builtin = @import("builtin");
const eql = std.mem.eql;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const Dict = @import("../noun/dict.zig").Dict;
const VM = @import("vm.zig").VM;
const exec_mod = @import("../primitive/verb/exec.zig");
const Op1 = @import("../noun/operator.zig").Op1;
const dispatch1 = @import("../primitive/dispatch.zig").dispatch1;

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
  if (eql(u8, name, "dir")) return listDir(vm, args);
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
  // Any monadic primitive is callable as a symbol: `` `sin x ``, `` `first x ``,
  // `` `parse x `` route to the SAME Op1 kernel the (now-removed) keyword verb used
  // (type-preserving — `` `sqr `` on ints stays int, unlike the f32-widening mapUnary
  // below). This is what lets the lib/prelude.k projections (`` sin:{`sin x} ``,
  // `` first:{`first x} ``, …) work. args are borrowed (as in call.zig applyCallable's
  // dispatch1 sites), so pass through without ref.
  if (args.len == 1 and args[0] != .blank) {
    if (Op1.fromString(name)) |op1| return dispatch1(vm, op1, args[0]);
  }
  // Inverse-trig helpers exposed as `sym@x rather than as new verb glyphs.
  // Monadic ones map element-wise over scalars, F/I/B vectors and general lists;
  // atan2 takes a 2-element list `atan2@(y;x) and broadcasts scalar⊕vector.
  if (eql(u8, name, "asin")) return mapUnary(vm, args, fAsin);
  if (eql(u8, name, "acos")) return mapUnary(vm, args, fAcos);
  if (eql(u8, name, "atan")) return mapUnary(vm, args, fAtan);
  if (eql(u8, name, "tan")) return mapUnary(vm, args, fTan);
  if (eql(u8, name, "atan2")) return atan2Apply(vm, args);
  // cube root: f32-widening (cbrt of an int isn't an int), signed like std.math.cbrt.
  if (eql(u8, name, "cbrt")) return mapUnary(vm, args, fCbrt);
  return V{ .err = .@"type" };
}

fn fAsin(x: f32) f32 { return std.math.asin(x); }
fn fAcos(x: f32) f32 { return std.math.acos(x); }
fn fAtan(x: f32) f32 { return std.math.atan(x); }
fn fTan(x: f32) f32 { return std.math.tan(x); }
fn fCbrt(x: f32) f32 { return std.math.cbrt(x); }

// A scalar V as f32, or null if it isn't a numeric atom.
fn toF(v: V) ?f32 {
  return switch (v) {
    .f => |x| x,
    .i => |x| @floatFromInt(x),
    .b => |x| if (x) @as(f32, 1.0) else 0.0,
    else => null,
  };
}

fn mapUnary(vm: *VM, args: []const V, comptime fun: fn (f32) f32) V {
  if (args.len != 1 or args[0] == .blank) return V{ .err = .rank };
  return mapUnaryV(vm, args[0], fun);
}

fn mapUnaryV(vm: *VM, v: V, comptime fun: fn (f32) f32) V {
  switch (v) {
    .f, .i, .b => return .{ .f = fun(toF(v).?) },
    inline .F, .I, .B => |n| {
      const out = N(f32).init(vm.alloc, n.ptr.len) catch return V{ .err = .memory };
      const o = out.slice();
      for (n.slice(), 0..) |x, i| o[i] = fun(switch (@TypeOf(x)) {
        f32 => x,
        bool => if (x) @as(f32, 1.0) else 0.0,
        else => @floatFromInt(x),
      });
      return .{ .F = out };
    },
    .L => |n| {
      const out = N(V).init(vm.alloc, n.ptr.len) catch return V{ .err = .memory };
      const o = out.slice();
      for (n.slice(), 0..) |x, i| o[i] = mapUnaryV(vm, x, fun);
      return .{ .L = out };
    },
    else => return V{ .err = .@"type" },
  }
}

// Length of a numeric vector operand, or null for a scalar atom.
fn vecLen(v: V) ?usize {
  return switch (v) {
    .F, .I, .B => v.len(),
    else => null,
  };
}

// i-th element of a scalar-or-vector operand as f32.
fn elemF(v: V, i: usize) ?f32 {
  return switch (v) {
    .F => |n| n.slice()[i],
    .I => |n| @floatFromInt(n.slice()[i]),
    .B => |n| if (n.slice()[i]) @as(f32, 1.0) else 0.0,
    else => toF(v),
  };
}

// atan2 over a 2-element list (y;x). Both may be scalars, both equal-length
// vectors, or one scalar + one vector (broadcast). Returns f32 / F vector.
fn atan2Apply(vm: *VM, args: []const V) V {
  if (args.len != 1 or args[0] == .blank) return V{ .err = .rank };
  const pair = args[0];
  if (pair.len() != 2) return V{ .err = .length };
  const yv = pair.at(0);
  defer yv.deinit(vm.alloc);
  const xv = pair.at(1);
  defer xv.deinit(vm.alloc);

  const yn = vecLen(yv);
  const xn = vecLen(xv);
  if (yn == null and xn == null) {
    const yf = toF(yv) orelse return V{ .err = .@"type" };
    const xf = toF(xv) orelse return V{ .err = .@"type" };
    return .{ .f = std.math.atan2(yf, xf) };
  }
  if (yn != null and xn != null and yn.? != xn.?) return V{ .err = .length };
  const n = yn orelse xn.?;
  const out = N(f32).init(vm.alloc, n) catch return V{ .err = .memory };
  const o = out.slice();
  for (0..n) |i| {
    const yf = elemF(yv, i) orelse return V{ .err = .@"type" };
    const xf = elemF(xv, i) orelse return V{ .err = .@"type" };
    o[i] = std.math.atan2(yf, xf);
  }
  return .{ .F = out };
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

// `dir@"path" — recursively list file paths under "path" (relative to CWD),
// returning a list of char-vector paths. Hidden entries (dot-prefixed) and the
// usual build/VCS dirs are skipped; depth is capped. Used by the k language
// server to discover workspace .k files.  Errors return an empty list rather
// than `!io so a missing workspace root is harmless.
fn skipWalkDir(nm: []const u8) bool {
  if (nm.len > 0 and nm[0] == '.') return true;
  const skip = [_][]const u8{ "zig-cache", "zig-out", "node_modules", "target" };
  for (skip) |s| if (eql(u8, nm, s)) return true;
  return false;
}

fn walkInto(vm: *VM, dir_path: []const u8, out: *std.ArrayList(V), depth: u8) void {
  if (depth > 8) return;
  const io = std.Io.Threaded.global_single_threaded.io();
  var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch return;
  defer dir.close(io);
  var it = dir.iterate();
  while (it.next(io) catch null) |entry| {
    const child = std.fmt.allocPrint(vm.alloc, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
    defer vm.alloc.free(child);
    if (entry.kind == .directory) {
      if (skipWalkDir(entry.name)) continue;
      walkInto(vm, child, out, depth + 1);
    } else if (entry.kind == .file) {
      const v = V.Chars(vm.alloc, child) catch continue;
      out.append(vm.alloc, v) catch v.deinit(vm.alloc);
    }
  }
}

fn listDir(vm: *VM, args: []const V) V {
  if (args.len != 1 or args[0] == .blank) return V{ .err = .rank };
  const path: []const u8 = switch (args[0]) {
    .C => |c| c.slice(),
    .s => |s| vm.getSymbol(s),
    else => return V{ .err = .@"type" },
  };
  var out = std.ArrayList(V).initCapacity(vm.alloc, 0) catch return V{ .err = .memory };
  defer out.deinit(vm.alloc);
  walkInto(vm, path, &out, 0);
  return V.Values(vm.alloc, out.items) catch V{ .err = .memory };
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
