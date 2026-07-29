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
const serve = @import("serve.zig");
const Conns = @import("registry.zig").Conns;

// Microsecond clock.  std.time has no timestamp fns and posix clock_gettime
// doesn't compile for Windows, so branch at comptime per platform.
extern "kernel32" fn GetSystemTimeAsFileTime(*std.os.windows.FILETIME) callconv(.winapi) void;

pub fn microsNow() i64 {
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
  // ── IPC / event loop ──────────────────────────────────────────────────────
  // Verbs move data (`> < 2:`); these symbols configure the runtime around it.
  // See doc/reference.md "IPC".
  if (eql(u8, name, "sleep")) return sleepMs(args);
  if (eql(u8, name, "poll"))  { serve.pollOnce(vm, .blank); return .blank; }
  if (eql(u8, name, "serve")) { serve.runLoop(vm); return .blank; }
  if (eql(u8, name, "conns")) return listConns(vm);
  if (eql(u8, name, "peer"))  return peerName(vm, args);
  if (eql(u8, name, "on"))    return setHandler(vm, args);
  if (eql(u8, name, "timer")) return timerCtl(vm, args);
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

// ── IPC helpers ─────────────────────────────────────────────────────────────

/// `` `sleep[ms] `` — block for `ms` milliseconds.  Fractional values are fine
/// (`` `sleep[0.5] ``); a negative or null delay is a no-op rather than an error,
/// so a computed backoff that goes negative just doesn't sleep.
fn sleepMs(args: []const V) V {
  if (args.len != 1 or args[0] == .blank) return V{ .err = .rank };
  const ms: f64 = switch (args[0]) {
    .i => |x| if (x == V.@"0N") return .blank else @floatFromInt(x),
    .n => |x| @floatFromInt(x),
    .b => |x| if (x) 1.0 else 0.0,
    .f => |x| if (std.math.isNan(x)) return .blank else @floatCast(x),
    .d => |x| if (std.math.isNan(x)) return .blank else x,
    .h => |x| if (std.math.isNan(x)) return .blank else @floatCast(x),
    else => return V{ .err = .@"type" },
  };
  if (ms <= 0) return .blank;
  const ns_total = ms * std.time.ns_per_ms;
  // Cap at ~1 year so a runaway computation can't wedge the process forever.
  const capped = @min(ns_total, @as(f64, 365 * 24 * 3600) * std.time.ns_per_s);
  const secs: i64 = @intFromFloat(@divFloor(capped, std.time.ns_per_s));
  const nsec: i64 = @intFromFloat(@mod(capped, std.time.ns_per_s));
  sleepFor(secs, nsec);
  return .blank;
}

fn sleepFor(secs: i64, nsec: i64) void {
  if (builtin.os.tag == .windows) {
    const ms: u32 = @intCast(@min(@as(i64, std.math.maxInt(u32)), secs * 1000 + @divTrunc(nsec, std.time.ns_per_ms)));
    std.os.windows.kernel32.Sleep(ms);
  } else {
    // nanosleep returns early on a signal; loop on the remaining time so a
    // stray SIGCHLD (from `` `x ``) doesn't shorten the sleep.
    var req: std.posix.timespec = .{ .sec = secs, .nsec = nsec };
    var rem: std.posix.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) == -1) {
      if (std.posix.errno(@as(c_int, -1)) != .INTR) break;
      req = rem;
    }
  }
}

/// `` `conns[] `` — the open connection handles, ascending.  A listening handle
/// is included; that is what `` `peer `` distinguishes.
fn listConns(vm: *VM) V {
  const n = vm.conns.map.count();
  const vec = N(i32).init(vm.alloc, @intCast(n)) catch return V{ .err = .memory };
  var i: usize = 0;
  var it = vm.conns.map.keyIterator();
  while (it.next()) |k| : (i += 1) vec.slice()[i] = @intCast(k.*);
  std.mem.sort(i32, vec.slice(), {}, std.sort.asc(i32));
  return .{ .I = vec };
}

/// `` `peer[h] `` — "ip:port" of the remote end of `h`, or "" for a handle that
/// is still only listening.  Handy for logging and for a registry keyed by
/// address; a protocol should still send its own address, since a peer's
/// source port is not the port it listens on.
fn peerName(vm: *VM, args: []const V) V {
  if (args.len != 1 or args[0].tag() != .i) return V{ .err = .@"type" };
  const id: u32 = @intCast(args[0].i);
  const conn = vm.conns.get(id) orelse return V{ .err = .io };
  const stream = conn.stream orelse return V.Chars(vm.alloc, "") catch V{ .err = .memory };
  if (builtin.os.tag == .windows) return V.Chars(vm.alloc, "") catch V{ .err = .memory };
  var addr: std.posix.sockaddr.storage = undefined;
  var len: std.posix.socklen_t = @sizeOf(@TypeOf(addr));
  std.posix.getpeername(stream.socket.handle, @ptrCast(&addr), &len) catch
    return V.Chars(vm.alloc, "") catch V{ .err = .memory };
  var buf: [64]u8 = undefined;
  const text = switch (addr.family) {
    std.posix.AF.INET => blk: {
      const a: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&addr));
      const o: [4]u8 = @bitCast(a.addr);
      break :blk std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}:{d}", .{
        o[0], o[1], o[2], o[3], std.mem.bigToNative(u16, a.port),
      }) catch return V{ .err = .io };
    },
    else => "",
  };
  return V.Chars(vm.alloc, text) catch V{ .err = .memory };
}

/// `` `on[h;f] `` — attach handler `f` to handle `h`; `` `on[h;] `` detaches.
/// `` `on[h] `` reads the handler back.  This is deliberately NOT `h 2: f`:
/// `2:` means "send" for every type, functions included.
fn setHandler(vm: *VM, args: []const V) V {
  if (args.len == 0 or args[0].tag() != .i) return V{ .err = .@"type" };
  const id: u32 = @intCast(args[0].i);
  if (!Conns.isConn(id) or vm.conns.get(id) == null) return V{ .err = .io };
  if (args.len == 1 or args[1] == .blank) {
    if (args.len == 1) return vm.conns.getCallback(id).ref();
    vm.conns.clearCallback(id);
    return .blank;
  }
  if (args.len != 2) return V{ .err = .rank };
  vm.conns.setCallback(id, args[1].ref()) catch return V{ .err = .memory };
  return .blank;
}

/// `` `timer[ms] `` — call the global `ts` every `ms` milliseconds while the
/// event loop runs.  `` `timer[0] `` stops it, `` `timer[] `` reads the interval.
fn timerCtl(vm: *VM, args: []const V) V {
  const has_arg = args.len == 1 and args[0] != .blank;
  if (!has_arg) return .{ .i = @intCast(vm.timer_ms) };
  const ms: i64 = switch (args[0]) {
    .i => |x| if (x == V.@"0N") 0 else x,
    .n => |x| @intCast(x),
    .b => |x| if (x) 1 else 0,
    .f => |x| if (std.math.isNan(x)) 0 else @intFromFloat(x),
    else => return V{ .err = .@"type" },
  };
  if (ms < 0) return V{ .err = .domain };
  vm.timer_ms = @intCast(@min(ms, std.math.maxInt(u32)));
  vm.timer_next = microsNow() + @as(i64, vm.timer_ms) * 1000;
  return .blank;
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
