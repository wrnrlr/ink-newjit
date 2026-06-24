/// Thin builder over the host's k_* construction API.
///
/// The host hands us a KRegistry (a table of function pointers) in terse_init.
/// Table parsers never touch that table directly — they call the small set of
/// helpers here to turn parsed scalars/slices into K values (atoms, typed
/// vectors, lists, symbol-keyed dicts).
///
/// Ownership: vector/list/dict constructors return a value with refcount 1.
/// `dict()` releases the refs it was handed (k_make_dict retains internally),
/// so the idiom is: build child values, pass them to `dict`, done. For lists,
/// `listSet` takes ownership of the element, mirroring k_list_set.

const std = @import("std");

pub const K = *anyopaque;

// TODO maybe this should just ba part ok the k ABI.

/// Mirror of KRegistry in src/ffi.zig — field order MUST match exactly.
pub const Registry = extern struct {
  ki: *const fn (i32) callconv(.c) ?K,
  kf: *const fn (f32) callconv(.c) ?K,
  kc: *const fn (u8) callconv(.c) ?K,
  kb: *const fn (c_int) callconv(.c) ?K,
  ks: *const fn ([*:0]const u8) callconv(.c) ?K,
  kerr: *const fn () callconv(.c) ?K,
  KC: *const fn (i32) callconv(.c) ?K,
  KI: *const fn (i32) callconv(.c) ?K,
  KF: *const fn (i32) callconv(.c) ?K,
  KL: *const fn (i32) callconv(.c) ?K,
  kt: *const fn (?K) callconv(.c) i8,
  kn: *const fn (?K) callconv(.c) i32,
  ki_val: *const fn (?K) callconv(.c) i32,
  kf_val: *const fn (?K) callconv(.c) f32,
  kc_val: *const fn (?K) callconv(.c) u8,
  kb_val: *const fn (?K) callconv(.c) c_int,
  kip: *const fn (?K) callconv(.c) ?[*]i32,
  kfp: *const fn (?K) callconv(.c) ?[*]f32,
  kcp: *const fn (?K) callconv(.c) ?[*]u8,
  klp: *const fn (?K) callconv(.c) ?[*]?K,
  ku: *const fn (?K) callconv(.c) void,
  k_list_set: *const fn (?K, i32, ?K) callconv(.c) i32,
  k_call: *const fn (?K, ?K) callconv(.c) ?K,
  k_call2: *const fn (?K, ?K, ?K) callconv(.c) ?K,
  k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
  k_list_get: *const fn (?K, i32) callconv(.c) ?K,
};

pub var reg: ?*const Registry = null;

pub fn init(r: *const Registry) void {
  reg = r;
}

// ── Atoms ─────────────────────────────────────────────────────────────────────

pub fn ki(v: i32) ?K {
  return reg.?.ki(v);
}
pub fn kf(v: f32) ?K {
  return reg.?.kf(v);
}
pub fn kc(v: u8) ?K {
  return reg.?.kc(v);
}
pub fn kb(v: bool) ?K {
  return reg.?.kb(@intFromBool(v));
}

/// Intern a symbol atom. Requires the host VM context (set during an FFI call).
pub fn ks(name: [*:0]const u8) ?K {
  return reg.?.ks(name);
}

// ── Empty typed vectors (caller fills via the pointer helpers) ─────────────────

pub fn KI(n: usize) ?K {
  return reg.?.KI(@intCast(n));
}
pub fn KF(n: usize) ?K {
  return reg.?.KF(@intCast(n));
}
pub fn KC(n: usize) ?K {
  return reg.?.KC(@intCast(n));
}
pub fn KL(n: usize) ?K {
  return reg.?.KL(@intCast(n));
}

pub fn ip(x: ?K) ?[*]i32 {
  return reg.?.kip(x);
}
pub fn fp(x: ?K) ?[*]f32 {
  return reg.?.kfp(x);
}
pub fn cp(x: ?K) ?[*]u8 {
  return reg.?.kcp(x);
}

/// Element count of a vector/list (−1 for atoms).
pub fn kn(x: ?K) i32 {
  return reg.?.kn(x);
}

/// Element pointers of a general list (L).
pub fn lp(x: ?K) ?[*]?K {
  return reg.?.klp(x);
}

/// Element i of a general list as a fresh ref'd value (caller must `unref`).
pub fn listGet(x: ?K, i: i32) ?K {
  return reg.?.k_list_get(x, i);
}

/// Float value of an atom.
pub fn kfval(x: ?K) f32 {
  return reg.?.kf_val(x);
}

pub fn unref(x: ?K) void {
  reg.?.ku(x);
}

pub fn listSet(list: ?K, i: usize, v: ?K) void {
  _ = reg.?.k_list_set(list, @intCast(i), v);
}

// ── Typed vectors from slices ──────────────────────────────────────────────────

/// I-vector from any integer slice (values widened to i32).
pub fn ints(comptime T: type, slice: []const T) ?K {
  const v = KI(slice.len) orelse return null;
  if (ip(v)) |p| {
    for (slice, 0..) |x, i| p[i] = @intCast(x);
  }
  return v;
}

/// F-vector from any float slice.
pub fn floats(comptime T: type, slice: []const T) ?K {
  const v = KF(slice.len) orelse return null;
  if (fp(v)) |p| {
    for (slice, 0..) |x, i| p[i] = @floatCast(x);
  }
  return v;
}

/// C-vector (string) copied from bytes.
pub fn str(slice: []const u8) ?K {
  const v = KC(slice.len) orelse return null;
  if (cp(v)) |p| @memcpy(p[0..slice.len], slice);
  return v;
}

// ── Dicts ──────────────────────────────────────────────────────────────────────

/// Build a symbol-keyed dict. `keys` are null-terminated names (interned as
/// symbols by the host). Releases each value ref after the dict retains it,
/// so callers pass freshly-built values and forget them.
pub fn dict(keys: []const [*:0]const u8, vals: []const ?K) ?K {
  std.debug.assert(keys.len == vals.len);
  const d = reg.?.k_make_dict(@intCast(keys.len), keys.ptr, vals.ptr);
  for (vals) |v| unref(v);
  return d;
}
