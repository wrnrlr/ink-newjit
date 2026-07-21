/// Safetensors extension for ink — loaded via lib/safetensors.k.
///
/// K API (after loading):
///   ReadSafetensors "path/to/model.safetensors"
///     → dict:  tensor-name → [dtype: `f32; shape: 2 3; data: <F|I vector>]
///       plus an optional `__metadata__` key → dict of string→string.
///
/// dtype → ink column mapping (data is always a flat vector; reshape with
/// `(t`w)`shape # (t`w)`data`):
///   BOOL U8 I8 I16 U16 I32 U32 I64 U64  → I  (i32; values out of i32 range → 0N)
///   F16 BF16 F32 F64                    → F  (f32; F64 narrowed, F16/BF16 widened)
/// The reported `dtype` symbol is the ORIGINAL dtype, so no type info is lost.

const std = @import("std");
const reader = @import("reader.zig");
const K = *anyopaque;

const KRegistry = @import("kabi").KRegistry(K);

const KApi = struct {
  ks: *const fn ([*:0]const u8) callconv(.c) ?K,
  KC: *const fn (i32) callconv(.c) ?K,
  KI: *const fn (i32) callconv(.c) ?K,
  KF: *const fn (i32) callconv(.c) ?K,
  kn: *const fn (?K) callconv(.c) i32,
  kcp: *const fn (?K) callconv(.c) ?[*]u8,
  kip: *const fn (?K) callconv(.c) ?[*]i32,
  kfp: *const fn (?K) callconv(.c) ?[*]f32,
  ku: *const fn (?K) callconv(.c) void,
  k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
};
var g_api: ?KApi = null;

fn ks(s: [*:0]const u8) ?K {
  return g_api.?.ks(s);
}
fn KC(n: i32) ?K {
  return g_api.?.KC(n);
}
fn KI(n: i32) ?K {
  return g_api.?.KI(n);
}
fn KF(n: i32) ?K {
  return g_api.?.KF(n);
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
fn mkdict(n: i32, keys: [*]const [*:0]const u8, vs: [*]const ?K) ?K {
  return g_api.?.k_make_dict(n, keys, vs);
}

const Alloc = std.mem.Allocator;
const OOM = error{OutOfMemory};
const NULL_I: i32 = std.math.minInt(i32); // ink 0N

export fn ReadSafetensors(path_k: ?K) callconv(.c) ?K {
  const alloc = std.heap.c_allocator;
  const p = kcp(path_k) orelse return null;
  const n = kn(path_k);
  if (n <= 0) return null;
  const path = p[0..@intCast(n)];

  const io = std.Io.Threaded.global_single_threaded.io();
  const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
    std.debug.print("safetensors: cannot open '{s}': {s}\n", .{ path, @errorName(e) });
    return null;
  };
  defer file.close(io);

  const st = file.stat(io) catch |e| {
    std.debug.print("safetensors: stat '{s}' failed: {s}\n", .{ path, @errorName(e) });
    return null;
  };
  if (st.size == 0) return null;

  // mmap the file instead of slurping it into one contiguous heap buffer: the
  // reader treats the tensor data as a plain []u8 indexed by data_offsets, so a
  // demand-paged mmap view is a drop-in replacement that avoids the single
  // ~2 GB malloc that used to fail (silently) for multi-gigabyte models.
  // Windows has no POSIX mmap, so fall back to reading the whole file there.
  if (@import("builtin").os.tag == .windows) {
    const bytes = alloc.alloc(u8, @intCast(st.size)) catch return null;
    defer alloc.free(bytes);
    _ = file.readPositionalAll(io, bytes, 0) catch |e| {
      std.debug.print("safetensors: read '{s}' failed: {s}\n", .{ path, @errorName(e) });
      return null;
    };
    return build(alloc, bytes) catch |e| {
      std.debug.print("safetensors: decode '{s}' failed: {s}\n", .{ path, @errorName(e) });
      return null;
    };
  }

  const mapped = std.posix.mmap(
    null,
    @intCast(st.size),
    .{ .READ = true },
    .{ .TYPE = .PRIVATE },
    file.handle,
    0,
  ) catch |e| {
    std.debug.print("safetensors: mmap '{s}' failed: {s}\n", .{ path, @errorName(e) });
    return null;
  };
  defer std.posix.munmap(mapped);

  return build(alloc, mapped) catch |e| {
    std.debug.print("safetensors: decode '{s}' failed: {s}\n", .{ path, @errorName(e) });
    return null;
  };
}

fn build(alloc: Alloc, bytes: []const u8) reader.Error!K {
  var arena = std.heap.ArenaAllocator.init(alloc);
  defer arena.deinit();
  const aa = arena.allocator();

  const file = try reader.read(aa, bytes);

  const has_meta = file.meta.len > 0;
  const nentries = file.tensors.len + @as(usize, if (has_meta) 1 else 0);

  const names = try aa.alloc([*:0]const u8, nentries);
  const vals = try alloc.alloc(?K, nentries);
  defer alloc.free(vals);

  var built: usize = 0;
  errdefer for (vals[0..built]) |v| ku(v);

  for (file.tensors, 0..) |t, i| {
    names[i] = (try aa.dupeZ(u8, t.name)).ptr;
    vals[i] = try buildTensor(file.data, t);
    built += 1;
  }
  if (has_meta) {
    names[file.tensors.len] = "__metadata__";
    vals[file.tensors.len] = try buildMeta(aa, file.meta);
    built += 1;
  }
  built = 0; // disarm; mkdict consumes the values

  const result = mkdict(@intCast(nentries), names.ptr, vals.ptr);
  for (vals) |v| ku(v);
  return result orelse error.OutOfMemory;
}

fn buildTensor(data: []const u8, t: reader.Tensor) OOM!K {
  const slice = data[t.begin..t.end];

  const shape = KI(@intCast(t.shape.len)) orelse return error.OutOfMemory;
  errdefer ku(shape);
  if (t.shape.len > 0) @memcpy(kip(shape).?[0..t.shape.len], t.shape);

  const dsym = ks(t.dtype.sym()) orelse return error.OutOfMemory;
  errdefer ku(dsym);

  const vec = if (t.dtype.isFloat())
    try decodeFloats(t.dtype, slice)
  else
    try decodeInts(t.dtype, slice);
  errdefer ku(vec);

  const keys = [_][*:0]const u8{ "dtype", "shape", "data" };
  const vs = [_]?K{ dsym, shape, vec };
  const d = mkdict(3, &keys, &vs) orelse return error.OutOfMemory;
  return d;
}

fn buildMeta(aa: Alloc, meta: []const reader.Meta) OOM!K {
  const names = try aa.alloc([*:0]const u8, meta.len);
  const vals = try aa.alloc(?K, meta.len);
  var built: usize = 0;
  errdefer for (vals[0..built]) |v| ku(v);
  for (meta, 0..) |m, i| {
    names[i] = (try aa.dupeZ(u8, m.key)).ptr;
    const s = KC(@intCast(m.val.len)) orelse return error.OutOfMemory;
    if (m.val.len > 0) @memcpy(kcp(s).?[0..m.val.len], m.val);
    vals[i] = s;
    built += 1;
  }
  return mkdict(@intCast(meta.len), names.ptr, vals.ptr) orelse error.OutOfMemory;
}

fn decodeInts(dt: reader.Dtype, slice: []const u8) OOM!K {
  const esz = dt.size();
  const len = slice.len / esz;
  const out = KI(@intCast(len)) orelse return error.OutOfMemory;
  const dst = kip(out).?[0..len];
  var i: usize = 0;
  while (i < len) : (i += 1) {
    const b = slice[i * esz ..][0..esz];
    dst[i] = switch (dt) {
      .BOOL, .U8 => b[0],
      .I8 => @as(i8, @bitCast(b[0])),
      .I16 => std.mem.readInt(i16, b[0..2], .little),
      .U16 => std.mem.readInt(u16, b[0..2], .little),
      .I32 => std.mem.readInt(i32, b[0..4], .little),
      .U32 => clampU(std.mem.readInt(u32, b[0..4], .little)),
      .I64 => clampI(std.mem.readInt(i64, b[0..8], .little)),
      .U64 => clampU(std.mem.readInt(u64, b[0..8], .little)),
      else => unreachable,
    };
  }
  return out;
}

fn decodeFloats(dt: reader.Dtype, slice: []const u8) OOM!K {
  const esz = dt.size();
  const len = slice.len / esz;
  const out = KF(@intCast(len)) orelse return error.OutOfMemory;
  const dst = kfp(out).?[0..len];
  var i: usize = 0;
  while (i < len) : (i += 1) {
    const b = slice[i * esz ..][0..esz];
    dst[i] = switch (dt) {
      .F16 => @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, b[0..2], .little)))),
      .BF16 => @bitCast(@as(u32, std.mem.readInt(u16, b[0..2], .little)) << 16),
      .F32 => @bitCast(std.mem.readInt(u32, b[0..4], .little)),
      .F64 => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little)))),
      else => unreachable,
    };
  }
  return out;
}

fn clampI(v: i64) i32 {
  if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return NULL_I;
  return @intCast(v);
}

fn clampU(v: u64) i32 {
  if (v > std.math.maxInt(i32)) return NULL_I;
  return @intCast(v);
}

fn inkInit(reg: *anyopaque) void {
  const r: *const KRegistry = @ptrCast(@alignCast(reg));
  g_api = .{
    .ks = r.ks,
    .KC = r.KC,
    .KI = r.KI,
    .KF = r.KF,
    .kn = r.kn,
    .kcp = r.kcp,
    .kip = r.kip,
    .kfp = r.kfp,
    .ku = r.ku,
    .k_make_dict = r.k_make_dict,
  };
  r.k_register("ReadSafetensors", @ptrCast(&ReadSafetensors), 1);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_safetensors(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
