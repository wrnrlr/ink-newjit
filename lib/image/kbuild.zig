/// Thin builder over the host's k_* construction API, shared by every image
/// extension (libimage, libpng, libjpeg, …). Each extension compiles this in and
/// captures the host registry in its `terse_init`.
///
/// Ownership: vector/list/dict/table constructors return refcount-1 values.
/// `dict`/`table` release the value refs they are handed (the host retains
/// internally), so callers build children then forget them. `listSet` takes
/// ownership of the element, mirroring k_list_set.

const std = @import("std");

pub const K = *anyopaque;

/// The host's k-ABI table, from the canonical src/kabi.zig (wired as the
/// "kabi" module by build.zig). Instantiated with our opaque K handle.
pub const Registry = @import("kabi").KRegistry(K);

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
pub fn KS(n: usize) ?K {
  return reg.?.KS(@intCast(n));
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
pub fn sp(x: ?K) ?[*]u32 {
  return reg.?.ksp(x);
}

pub fn kn(x: ?K) i32 {
  return reg.?.kn(x);
}
pub fn kival(x: ?K) i32 {
  return reg.?.ki_val(x);
}
pub fn kfval(x: ?K) f32 {
  return reg.?.kf_val(x);
}

/// Element i of a general list as a fresh ref'd value (caller must `unref`).
pub fn listGet(x: ?K, i: i32) ?K {
  return reg.?.k_list_get(x, i);
}
pub fn listSet(list: ?K, i: usize, v: ?K) void {
  _ = reg.?.k_list_set(list, @intCast(i), v);
}

/// Intern a (null-terminated) name to a symbol id. Requires host VM context.
pub fn intern(name: [*:0]const u8) u32 {
  return reg.?.kintern(name);
}

pub fn unref(x: ?K) void {
  reg.?.ku(x);
}

// ── Typed vectors from slices ──────────────────────────────────────────────────

/// I-vector from any integer slice (values widened to i32).
pub fn ints(comptime T: type, slice: []const T) ?K {
  const v = KI(slice.len) orelse return null;
  if (ip(v)) |p| for (slice, 0..) |x, i| {
    p[i] = @intCast(x);
  };
  return v;
}

/// F-vector from any float slice.
pub fn floats(comptime T: type, slice: []const T) ?K {
  const v = KF(slice.len) orelse return null;
  if (fp(v)) |p| for (slice, 0..) |x, i| {
    p[i] = @floatCast(x);
  };
  return v;
}

/// C-vector (string) copied from bytes.
pub fn str(slice: []const u8) ?K {
  const v = KC(slice.len) orelse return null;
  if (cp(v)) |p| if (slice.len > 0) @memcpy(p[0..slice.len], slice);
  return v;
}

// ── Maps ────────────────────────────────────────────────────────────────────────

/// Build a symbol-keyed dict. `keys` are null-terminated names (interned as
/// symbols). Releases each value ref after the dict retains it.
pub fn dict(keys: []const [*:0]const u8, vals: []const ?K) ?K {
  std.debug.assert(keys.len == vals.len);
  const d = reg.?.k_make_dict(@intCast(keys.len), keys.ptr, vals.ptr);
  for (vals) |v| unref(v);
  return d;
}

/// Build a symbol-keyed table (columns must be equal-length vectors/lists).
pub fn table(keys: []const [*:0]const u8, vals: []const ?K) ?K {
  std.debug.assert(keys.len == vals.len);
  const t = reg.?.k_make_table(@intCast(keys.len), keys.ptr, vals.ptr);
  for (vals) |v| unref(v);
  return t;
}
