/// Apache Parquet extension for ink — loaded via lib/parquet/parquet.k.
///
/// K API (after loading):
///   ReadParquet "path/to/file.parquet"  → table whose columns are named by the
///                                          Parquet schema
///
/// Physical-type → ink column mapping:
///   BOOLEAN / INT32 / INT64        → I  (INT64 clamped to i32; out of range → 0N)
///   FLOAT / DOUBLE                 → F  (DOUBLE narrowed to f32)
///   BYTE_ARRAY / FIXED_LEN_BYTE_ARRAY → L of C (list of char vectors)
///
/// Nulls become 0N (int), nan (float) or "" (string).
///
/// Supported: flat schemas; PLAIN, PLAIN_DICTIONARY, RLE_DICTIONARY encodings;
/// UNCOMPRESSED, SNAPPY, GZIP, ZSTD codecs; data pages v1 and v2. Nested /
/// repeated columns are rejected.

const std = @import("std");
const reader = @import("reader.zig");
const K = *anyopaque;

const KRegistry = extern struct {
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
  k_make_table: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
};

const KApi = struct {
  KC: *const fn (i32) callconv(.c) ?K,
  KI: *const fn (i32) callconv(.c) ?K,
  KF: *const fn (i32) callconv(.c) ?K,
  KL: *const fn (i32) callconv(.c) ?K,
  kn: *const fn (?K) callconv(.c) i32,
  kcp: *const fn (?K) callconv(.c) ?[*]u8,
  kip: *const fn (?K) callconv(.c) ?[*]i32,
  kfp: *const fn (?K) callconv(.c) ?[*]f32,
  ku: *const fn (?K) callconv(.c) void,
  k_list_set: *const fn (?K, i32, ?K) callconv(.c) i32,
  k_make_table: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
};
var g_api: ?KApi = null;

fn KC(n: i32) ?K {
  return g_api.?.KC(n);
}
fn KI(n: i32) ?K {
  return g_api.?.KI(n);
}
fn KF(n: i32) ?K {
  return g_api.?.KF(n);
}
fn KL(n: i32) ?K {
  return g_api.?.KL(n);
}
fn kn(x: ?K) i32 {
  return g_api.?.kn(x);
}
fn kcp(x: ?K) ?[*]u8 {
  return g_api.?.kcp(x);
}
fn kip(x: ?K) ?[*]i32 {
  return g_api.?.kip(x);
}
fn kfp(x: ?K) ?[*]f32 {
  return g_api.?.kfp(x);
}
fn ku(x: ?K) void {
  g_api.?.ku(x);
}
fn kls(l: ?K, i: i32, v: ?K) i32 {
  return g_api.?.k_list_set(l, i, v);
}
fn mktable(n: i32, ks: [*]const [*:0]const u8, vs: [*]const ?K) ?K {
  return g_api.?.k_make_table(n, ks, vs);
}

const Alloc = std.mem.Allocator;
const OOM = error{OutOfMemory};

export fn ReadParquet(path_k: ?K) callconv(.c) ?K {
  const alloc = std.heap.c_allocator;
  const p = kcp(path_k) orelse return null;
  const n = kn(path_k);
  if (n <= 0) return null;
  const io = std.Io.Threaded.global_single_threaded.io();
  const bytes = std.Io.Dir.cwd().readFileAlloc(io, p[0..@intCast(n)], alloc, std.Io.Limit.limited(1 << 30)) catch return null;
  defer alloc.free(bytes);
  return buildTable(alloc, bytes) catch null;
}

fn buildTable(alloc: Alloc, bytes: []const u8) OOM!K {
  var arena = std.heap.ArenaAllocator.init(alloc);
  defer arena.deinit();
  const aa = arena.allocator();

  const cols = reader.read(aa, alloc, bytes) catch return error.OutOfMemory;
  const ncols = cols.len;

  const names = try aa.alloc([*:0]const u8, ncols);
  for (cols, 0..) |c, i| names[i] = (try aa.dupeZ(u8, c.name)).ptr;

  const col_ks = try alloc.alloc(?K, ncols);
  defer alloc.free(col_ks);

  var built: usize = 0;
  errdefer for (col_ks[0..built]) |ck| ku(ck);

  for (cols, 0..) |c, i| {
    col_ks[i] = try buildColumn(c);
    built += 1;
  }
  built = 0; // disarm

  const result = mktable(@intCast(ncols), names.ptr, col_ks.ptr);
  for (col_ks[0..ncols]) |ck| ku(ck);
  return result orelse error.OutOfMemory;
}

fn buildColumn(c: reader.Column) OOM!K {
  switch (c.kind) {
    .ints => {
      const len = c.ints.items.len;
      const out = KI(@intCast(len)) orelse return error.OutOfMemory;
      if (len > 0) @memcpy(kip(out).?[0..len], c.ints.items);
      return out;
    },
    .floats => {
      const len = c.floats.items.len;
      const out = KF(@intCast(len)) orelse return error.OutOfMemory;
      if (len > 0) @memcpy(kfp(out).?[0..len], c.floats.items);
      return out;
    },
    .strings => {
      const len = c.strings.items.len;
      const out = KL(@intCast(len)) orelse return error.OutOfMemory;
      errdefer ku(out);
      for (c.strings.items, 0..) |s, i| {
        const sk = KC(@intCast(s.len)) orelse return error.OutOfMemory;
        if (s.len > 0) @memcpy(kcp(sk).?[0..s.len], s);
        _ = kls(out, @intCast(i), sk); // consumes sk
      }
      return out;
    },
  }
}

export fn terse_init(reg: *anyopaque) callconv(.c) void {
  const r: *const KRegistry = @ptrCast(@alignCast(reg));
  g_api = .{
    .KC = r.KC,
    .KI = r.KI,
    .KF = r.KF,
    .KL = r.KL,
    .kn = r.kn,
    .kcp = r.kcp,
    .kip = r.kip,
    .kfp = r.kfp,
    .ku = r.ku,
    .k_list_set = r.k_list_set,
    .k_make_table = r.k_make_table,
  };
}
