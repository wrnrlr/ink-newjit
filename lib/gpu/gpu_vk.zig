//! Vulkan/MoltenVK GPU extension for ink — the compute backend (migration Phase 2).
//!
//! Same k-facing FFI as the Dawn backend (lib/gpu/gpu.zig): identical export
//! names + arities, so lib/gpu.k / lib/dye.k / test/*.k are unchanged. Selected
//! at build time with `-Dgpu-backend=vulkan`; produces the same libgpu.dylib.
//!
//! Phase 2 implements the window-less compute subset for real (via lib/gpu/vk.zig).
//! Render/window exports are stubs returning 0 until Phase 3.
const std = @import("std");
const vk = @import("vk.zig");
const zglfw = @import("zglfw");
const png = @import("png.zig");
const tri = @import("triangulate");
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const K = *anyopaque;

// ── Host K API (identical to gpu.zig; backend-independent) ────────────────────
const KApi = struct {
  k_call:      *const fn (K, K) callconv(.c) ?K,
  k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
  k_make_table:*const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
  kf:          *const fn (f32) callconv(.c) ?K,
  ki:          *const fn (i32) callconv(.c) ?K,
  kn:          *const fn (?K) callconv(.c) i32,
  kfp:         *const fn (?K) callconv(.c) ?[*]f32,
  kip:         *const fn (?K) callconv(.c) ?[*]i32,
  kcp:         *const fn (?K) callconv(.c) ?[*]u8,
  ki_val:      *const fn (?K) callconv(.c) i32,
  KI:          *const fn (i32) callconv(.c) ?K,
  KF:          *const fn (i32) callconv(.c) ?K,
  KS:          *const fn (i32) callconv(.c) ?K,
  ksp:         *const fn (?K) callconv(.c) ?[*]u32,
  kintern:     *const fn ([*:0]const u8) callconv(.c) u32,
  ku:          *const fn (?K) callconv(.c) void,
};
var g_api: ?KApi = null;

fn ki(v: i32) ?K       { return g_api.?.ki(v); }
fn kf(v: f32) ?K       { return g_api.?.kf(v); }
fn kn(x: ?K) i32       { return g_api.?.kn(x); }
fn kfp(x: ?K) ?[*]f32  { return g_api.?.kfp(x); }
fn kip(x: ?K) ?[*]i32  { return g_api.?.kip(x); }
fn ki_val(x: ?K) i32   { return g_api.?.ki_val(x); }
fn KI(n: i32) ?K       { return g_api.?.KI(n); }
fn KF(n: i32) ?K       { return g_api.?.KF(n); }
fn KS(n: i32) ?K       { return g_api.?.KS(n); }
fn ksp(x: ?K) ?[*]u32  { return g_api.?.ksp(x); }
fn kintern(s: [*:0]const u8) u32 { return g_api.?.kintern(s); }
fn ku(x: ?K) void      { g_api.?.ku(x); }
fn k_call(f: K, a: K) ?K { return g_api.?.k_call(f, a); }
fn k_make_dict(n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?K) ?K { return g_api.?.k_make_dict(n, keys, vals); }
fn k_make_table(n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?K) ?K { return g_api.?.k_make_table(n, keys, vals); }

// ── Window input → props`events table (mirrors the Dawn backend) ──────────────
const NI: i32 = -2147483648; // ink 0N
var g_kt: u32 = 0; var g_kk: u32 = 0; var g_km: u32 = 0; var g_ks: u32 = 0;
var g_kinds = false;
fn ensureKinds() void {
  if (g_kinds) return;
  g_kt = kintern("text"); g_kk = kintern("key"); g_km = kintern("mouse"); g_ks = kintern("scroll");
  g_kinds = true;
}
const Event = struct { kind: u32, code: i32, mods: i32, down: i32, x: f32, y: f32, amt: f32 };
const QCAP = 256;
var g_events: [QCAP]Event = undefined;
var g_nev: usize = 0;
var g_dpr_x: f64 = 1.0;
var g_dpr_y: f64 = 1.0;
fn cursorPx(win: *zglfw.Window) [2]f32 {
  var cx: f64 = 0; var cy: f64 = 0;
  zglfw.getCursorPos(win, &cx, &cy);
  return .{ @floatCast(cx * g_dpr_x), @floatCast(cy * g_dpr_y) };
}
fn pushEvent(e: Event) void { if (g_nev < QCAP) { g_events[g_nev] = e; g_nev += 1; } }
fn keyCb(win: *zglfw.Window, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
  const c = cursorPx(win);
  pushEvent(.{ .kind = blk: { ensureKinds(); break :blk g_kk; }, .code = key, .mods = mods, .down = if (action != zglfw.Release) 1 else 0, .x = c[0], .y = c[1], .amt = std.math.nan(f32) });
}
fn charCb(win: *zglfw.Window, cp: c_uint) callconv(.c) void {
  const c = cursorPx(win);
  pushEvent(.{ .kind = blk: { ensureKinds(); break :blk g_kt; }, .code = @intCast(cp), .mods = NI, .down = NI, .x = c[0], .y = c[1], .amt = std.math.nan(f32) });
}
fn mouseBtnCb(win: *zglfw.Window, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
  const c = cursorPx(win);
  pushEvent(.{ .kind = blk: { ensureKinds(); break :blk g_km; }, .code = button, .mods = mods, .down = if (action == zglfw.Press) 1 else 0, .x = c[0], .y = c[1], .amt = std.math.nan(f32) });
}
fn scrollCb(win: *zglfw.Window, _: f64, yoff: f64) callconv(.c) void {
  const c = cursorPx(win);
  pushEvent(.{ .kind = blk: { ensureKinds(); break :blk g_ks; }, .code = NI, .mods = NI, .down = NI, .x = c[0], .y = c[1], .amt = @floatCast(yoff) });
}
fn buildEvents() ?K {
  const n: i32 = @intCast(g_nev);
  const c_kind = KS(n); const c_code = KI(n); const c_mods = KI(n); const c_down = KI(n);
  const c_x = KF(n); const c_y = KF(n); const c_amt = KF(n);
  if (g_nev != 0) {
    const pk = ksp(c_kind).?; const pc = kip(c_code).?; const pm = kip(c_mods).?; const pd = kip(c_down).?;
    const px = kfp(c_x).?; const py = kfp(c_y).?; const pa = kfp(c_amt).?;
    for (g_events[0..g_nev], 0..) |e, i| { pk[i] = e.kind; pc[i] = e.code; pm[i] = e.mods; pd[i] = e.down; px[i] = e.x; py[i] = e.y; pa[i] = e.amt; }
  }
  const keys = [7][*:0]const u8{ "kind", "code", "mods", "down", "x", "y", "amt" };
  const vals = [7]?K{ c_kind, c_code, c_mods, c_down, c_x, c_y, c_amt };
  const table = k_make_table(7, &keys, &vals);
  ku(c_kind); ku(c_code); ku(c_mods); ku(c_down); ku(c_x); ku(c_y); ku(c_amt);
  return table;
}

// ── Device + resident registries (live only inside a gpuComputeRun call) ───────
var g_vk: ?*vk.Vk = null;
const alloc = std.heap.c_allocator;

var g_bufs: std.ArrayList(vk.Buffer) = .empty;      // 1-based handles
var g_bfree: std.ArrayList(usize) = .empty;         // reusable freed slot indices (0-based)
var g_pipes: std.ArrayList(vk.Pipeline) = .empty;

// A freed slot is tombstoned with size==0 (createBuffer clamps live buffers to >=4),
// so resetRegistries skips it and a double gpu.free is a no-op. Its index goes on
// g_bfree so the next gpuBufferNew reuses it — placement churn (kk.compile output
// buffers, nn residency) stays bounded instead of growing the registry unboundedly.
fn resetRegistries() void {
  const v = g_vk.?;
  v.sync(); // finish any in-flight dispatch before freeing its buffers
  for (g_bufs.items) |b| { if (b.size != 0) v.destroyBuffer(b); }
  for (g_pipes.items) |p| v.destroyPipeline(p);
  if (g_fbuf) |b| v.destroyBuffer(b);
  for (g_spirv_pipes.items) |fp| v.destroyFillShaderPipe(fp);
  for (g_textures.items) |t| v.destroyTexture(t);
  for (g_pull_pipes.items) |pp| v.destroyPullPipeline(pp);
  g_bufs.deinit(alloc); g_bfree.deinit(alloc); g_pipes.deinit(alloc);
  g_fill_verts.deinit(alloc); g_fill_calls.deinit(alloc); g_spirv_pipes.deinit(alloc);
  g_textures.deinit(alloc);
  g_pull_pipes.deinit(alloc); g_pull_calls.deinit(alloc);
  g_bufs = .empty; g_bfree = .empty; g_pipes = .empty;
  g_fill_verts = .empty; g_fill_calls = .empty; g_fbuf = null; g_fbuf_cap = 0; g_spirv_pipes = .empty;
  g_textures = .empty;
  g_pull_pipes = .empty; g_pull_calls = .empty;
}

fn wordsOf(k: ?K) ?[]const u32 {
  const ip = kip(k) orelse return null;
  const n = kn(k);
  if (n < 5) return null;
  const p: [*]const u32 = @ptrCast(@alignCast(ip));
  return p[0..@intCast(n)];
}

// ── gpuComputeRun[fn] : create a headless device, run fn once, tear down ───────
export fn gpuComputeRun(fn_k: ?K) callconv(.c) ?K {
  const cbk = fn_k orelse return ki(0);
  var v = vk.Vk.init() catch return ki(-1);
  g_vk = &v;
  g_bufs = .empty; g_pipes = .empty;
  defer { resetRegistries(); v.deinit(); g_vk = null; }

  // Mirror gpuRun/Dawn: callback returns a VM-allocated K we must ku; results
  // come back via k globals the callback assigns (out:: …).
  const arg = ki(0) orelse return ki(-1);
  const result = k_call(cbk, arg);
  ku(result);
  ku(arg);
  return ki(0);
}

// ── gpuCompute[words; input_F] -> output_F : one-shot element-wise map ─────────
export fn gpuCompute(words_k: ?K, input_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const words = wordsOf(words_k) orelse return ki(0);
  const fp = kfp(input_k) orelse return ki(0);
  const ni = kn(input_k);
  if (ni <= 0) return ki(0);
  const n: usize = @intCast(ni);
  const bytes: u64 = n * @sizeOf(f32);

  const bin = v.createBuffer(bytes, false) catch return ki(0);
  defer v.destroyBuffer(bin);
  const bout = v.createBuffer(bytes, false) catch return ki(0);
  defer v.destroyBuffer(bout);
  v.write(bin, std.mem.sliceAsBytes(fp[0..n]));

  const pipe = v.createComputePipeline(words, 2, -1, vk.localSizeX(words)) catch return ki(0);
  defer v.destroyPipeline(pipe);
  v.dispatch(pipe, &[_]vk.Buffer{ bin, bout }, @intCast(n));
  v.sync();

  return floatsOut(v.read(bout), n);
}

// ── gpuCompute2[words; in1_F; in2_F] -> output_F : two-input map ───────────────
// binding 0 = in1, binding 1 = out, binding 2 = in2 (matches compCompute2).
export fn gpuCompute2(words_k: ?K, in1_k: ?K, in2_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const words = wordsOf(words_k) orelse return ki(0);
  const fp1 = kfp(in1_k) orelse return ki(0);
  const fp2 = kfp(in2_k) orelse return ki(0);
  const n1 = kn(in1_k);
  if (n1 <= 0 or kn(in2_k) != n1) return ki(0);
  const n: usize = @intCast(n1);
  const bytes: u64 = n * @sizeOf(f32);

  const b_in1 = v.createBuffer(bytes, false) catch return ki(0);
  defer v.destroyBuffer(b_in1);
  const b_out = v.createBuffer(bytes, false) catch return ki(0);
  defer v.destroyBuffer(b_out);
  const b_in2 = v.createBuffer(bytes, false) catch return ki(0);
  defer v.destroyBuffer(b_in2);
  v.write(b_in1, std.mem.sliceAsBytes(fp1[0..n]));
  v.write(b_in2, std.mem.sliceAsBytes(fp2[0..n]));

  const pipe = v.createComputePipeline(words, 3, -1, vk.localSizeX(words)) catch return ki(0);
  defer v.destroyPipeline(pipe);
  v.dispatch(pipe, &[_]vk.Buffer{ b_in1, b_out, b_in2 }, @intCast(n));
  v.sync();

  return floatsOut(v.read(b_out), n);
}

// ── resident buffers ──────────────────────────────────────────────────────────
fn newBuffer(data_k: ?K, uniform: bool) ?K {
  const v = g_vk orelse return ki(0);
  const fp = kfp(data_k) orelse return ki(0);
  const n = kn(data_k);
  if (n <= 0) return ki(0);
  const nn: usize = @intCast(n);
  const raw: u64 = nn * @sizeOf(f32);
  const sz: u64 = if (uniform) (raw + 15) & ~@as(u64, 15) else raw; // UBOs need 16-byte size
  const b = v.createBuffer(sz, uniform) catch return ki(0);
  v.write(b, std.mem.sliceAsBytes(fp[0..nn]));
  if (g_bfree.pop()) |idx| { g_bufs.items[idx] = b; return ki(@intCast(idx + 1)); }
  g_bufs.append(alloc, b) catch { v.destroyBuffer(b); return ki(0); };
  return ki(@intCast(g_bufs.items.len));
}
export fn gpuBufferNew(data_k: ?K) callconv(.c) ?K { return newBuffer(data_k, false); }
export fn gpuUniformNew(data_k: ?K) callconv(.c) ?K { return newBuffer(data_k, true); }

// Uniform buffer of raw i32 words (exact i32 counts past the f32 2^24 cliff): the reduce/scan/compact kernels
// carry only integer COUNTS in their uniform, so shipping the exact i32 bit pattern
// (shader bitcasts f32-lane → i32) is exact to 2^31 instead of the f32 f2s 2^24 cliff.
fn newBufferI(data_k: ?K, uniform: bool) ?K {
  const v = g_vk orelse return ki(0);
  const ip = kip(data_k) orelse return ki(0);
  const n = kn(data_k);
  if (n <= 0) return ki(0);
  const nn: usize = @intCast(n);
  const raw: u64 = nn * @sizeOf(i32);
  const sz: u64 = if (uniform) (raw + 15) & ~@as(u64, 15) else raw;
  const b = v.createBuffer(sz, uniform) catch return ki(0);
  v.write(b, std.mem.sliceAsBytes(ip[0..nn]));
  if (g_bfree.pop()) |idx| { g_bufs.items[idx] = b; return ki(@intCast(idx + 1)); }
  g_bufs.append(alloc, b) catch { v.destroyBuffer(b); return ki(0); };
  return ki(@intCast(g_bufs.items.len));
}
export fn gpuUniformNewI(data_k: ?K) callconv(.c) ?K { return newBufferI(data_k, true); }

// gpu.free[h] — release a resident buffer eagerly (before device teardown). Tombstones
// the slot (size=0) and puts its index on the free-list for reuse. Freeing an invalid or
// already-freed handle is a no-op (0). Frees are host-synced so no in-flight dispatch can
// still be reading the buffer.
export fn gpuBufferFree(h_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const h = ki_val(h_k);
  if (h <= 0 or h > g_bufs.items.len) return ki(0);
  const idx: usize = @intCast(h - 1);
  const b = g_bufs.items[idx];
  if (b.size == 0) return ki(0); // already freed
  v.sync();
  v.destroyBuffer(b);
  g_bufs.items[idx].size = 0; // tombstone
  g_bfree.append(alloc, idx) catch {};
  return ki(0);
}

export fn gpuBufferWrite(h_k: ?K, data_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const h = ki_val(h_k);
  if (h <= 0 or h > g_bufs.items.len) return ki(0);
  const fp = kfp(data_k) orelse return ki(0);
  const n = kn(data_k);
  if (n <= 0) return ki(0);
  v.sync(); // finish recorded work touching this buffer before host overwrites it
  var nn: usize = @intCast(n);
  const b = g_bufs.items[@intCast(h - 1)];
  if (b.size == 0) return ki(0); // freed slot
  const cap: usize = @intCast(b.size / @sizeOf(f32));
  if (nn > cap) nn = cap;
  v.write(b, std.mem.sliceAsBytes(fp[0..nn]));
  return ki(0);
}

export fn gpuBufferRead(h_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const h = ki_val(h_k);
  if (h <= 0 or h > g_bufs.items.len) return ki(0);
  v.sync(); // ensure prior async dispatches completed before reading mapped memory
  const b = g_bufs.items[@intCast(h - 1)];
  if (b.size == 0) return ki(0); // freed slot
  const n: usize = @intCast(b.size / @sizeOf(f32));
  return floatsOut(b.mapped[0..b.size], n);
}

export fn gpuBufferReadI(h_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const h = ki_val(h_k);
  if (h <= 0 or h > g_bufs.items.len) return ki(0);
  v.sync();
  const b = g_bufs.items[@intCast(h - 1)];
  if (b.size == 0) return ki(0); // freed slot
  const n: usize = @intCast(b.size / @sizeOf(i32));
  const out = KI(@intCast(n)) orelse return ki(0);
  const op = g_api.?.kip(out) orelse { ku(out); return ki(0); };
  @memcpy(std.mem.sliceAsBytes(op[0..n]), b.mapped[0 .. n * 4]);
  return out;
}

// ── cached compute pipelines ──────────────────────────────────────────────────
export fn gpuComputeNew(words_k: ?K, nbind_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const words = wordsOf(words_k) orelse return ki(0);
  var nbind = ki_val(nbind_k);
  if (nbind < 1) nbind = 2;
  if (nbind > vk.MAX_BIND) nbind = vk.MAX_BIND;
  const p = v.createComputePipeline(words, @intCast(nbind), -1, vk.localSizeX(words)) catch return ki(0);
  g_pipes.append(alloc, p) catch { v.destroyPipeline(p); return ki(0); };
  return ki(@intCast(g_pipes.items.len));
}

export fn gpuComputeNewU(words_k: ?K, nstore_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const words = wordsOf(words_k) orelse return ki(0);
  var nstore = ki_val(nstore_k);
  if (nstore < 1) nstore = 2;
  if (nstore > vk.MAX_BIND - 1) nstore = vk.MAX_BIND - 1;
  const nb: u32 = @intCast(nstore + 1); // storage bindings + uniform at index nstore
  const p = v.createComputePipeline(words, nb, nstore, vk.localSizeX(words)) catch return ki(0);
  g_pipes.append(alloc, p) catch { v.destroyPipeline(p); return ki(0); };
  return ki(@intCast(g_pipes.items.len));
}

export fn gpuDispatch(pipe_k: ?K, bufs_k: ?K, nthreads_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const ph = ki_val(pipe_k);
  if (ph <= 0 or ph > g_pipes.items.len) return ki(0);
  const p = g_pipes.items[@intCast(ph - 1)];
  const bp = kip(bufs_k) orelse return ki(0);
  const ngiven: usize = @intCast(kn(bufs_k));
  if (ngiven < p.nbind) return ki(0);
  const nthreads = ki_val(nthreads_k);
  if (nthreads <= 0) return ki(0);

  var bufs: [vk.MAX_BIND]vk.Buffer = undefined;
  var i: usize = 0;
  while (i < p.nbind) : (i += 1) {
    const h = bp[i];
    if (h <= 0 or h > g_bufs.items.len) return ki(0);
    bufs[i] = g_bufs.items[@intCast(h - 1)];
  }
  v.dispatch(p, bufs[0..p.nbind], @intCast(nthreads));
  return ki(0);
}

export fn gpuDispatchLoop(pipe_k: ?K, bufsA_k: ?K, bufsB_k: ?K, nthreads_k: ?K, reps_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const ph = ki_val(pipe_k);
  if (ph <= 0 or ph > g_pipes.items.len) return ki(0);
  const p = g_pipes.items[@intCast(ph - 1)];
  const nbind = p.nbind;
  const pa = kip(bufsA_k) orelse return ki(0);
  const pb = kip(bufsB_k) orelse return ki(0);
  if (kn(bufsA_k) < @as(i32, @intCast(nbind)) or kn(bufsB_k) < @as(i32, @intCast(nbind))) return ki(0);
  const nthreads = ki_val(nthreads_k);
  if (nthreads <= 0) return ki(0);
  const reps = ki_val(reps_k);
  if (reps <= 0) return ki(0);

  var bufsA: [vk.MAX_BIND]vk.Buffer = undefined;
  var bufsB: [vk.MAX_BIND]vk.Buffer = undefined;
  var i: usize = 0;
  while (i < nbind) : (i += 1) {
    const ha = pa[i];
    const hb = pb[i];
    if (ha <= 0 or ha > g_bufs.items.len) return ki(0);
    if (hb <= 0 or hb > g_bufs.items.len) return ki(0);
    bufsA[i] = g_bufs.items[@intCast(ha - 1)];
    bufsB[i] = g_bufs.items[@intCast(hb - 1)];
  }
  v.dispatchLoop(p, bufsA[0..nbind], bufsB[0..nbind], @intCast(nthreads), @intCast(reps));
  return ki(0);
}

// float slice (bytes) -> new KF vector of n floats
fn floatsOut(bytes: []const u8, n: usize) ?K {
  const out = KF(@intCast(n)) orelse return ki(0);
  const of = kfp(out) orelse { ku(out); return ki(0); };
  @memcpy(std.mem.sliceAsBytes(of[0..n]), bytes[0 .. n * 4]);
  return out;
}

// Textures sampled at @group(1): count OpVariables in UniformConstant storage (0)
// in the fragment; n_tex = that count minus the one shared sampler.
fn texCount(words: []const u32) u32 {
  var uc: u32 = 0;
  var i: usize = 5;
  while (i < words.len) {
    const w0 = words[i];
    const wc: usize = w0 >> 16;
    if (wc == 0) break;
    if ((w0 & 0xffff) == 59 and i + 3 < words.len and words[i + 3] == 0) uc += 1;
    i += wc;
  }
  return if (uc > 0) uc - 1 else 0;
}

// Count OpVariables in the StorageBuffer storage class (12) — the vertex-pull
// shader's storage buffers (kk2 §5).
fn storageBufCount(words: []const u32) u32 {
  var sc: u32 = 0;
  var i: usize = 5;
  while (i < words.len) {
    const w0 = words[i];
    const wc: usize = w0 >> 16;
    if (wc == 0) break;
    if ((w0 & 0xffff) == 59 and i + 3 < words.len and words[i + 3] == 12) sc += 1;
    i += wc;
  }
  return sc;
}

// ── vertex-pulling pipelines + draws (kk2 §5) ─────────────────────────────────
var g_pull_pipes: std.ArrayList(vk.PullPipe) = .empty; // 1-based handles
const PullCall = struct { pipe: usize, bufs: [vk.MAX_BIND]i32, nbuf: usize, count: u32, tex: [MAX_TEX]i32 = [_]i32{0} ** MAX_TEX, ntex: usize = 0 };
var g_pull_calls: std.ArrayList(PullCall) = .empty; // this frame's pull draws

// gpuMeshPull[vtx_I; frg_I] -> handle : compile a vertex-pull pipeline (nbuf storage
// buffers in the vertex stage inferred from the shader).
export fn gpuMeshPull(vtx_k: ?K, frg_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const vwords = wordsOf(vtx_k) orelse return ki(0);
  const fwords = wordsOf(frg_k) orelse return ki(0);
  const nbuf = storageBufCount(vwords);
  if (nbuf == 0 or nbuf > vk.MAX_BIND) return ki(0);
  const n_tex = texCount(fwords); // textures @group(1) sampled by the fragment
  const pp = v.createPullPipeline(vwords, fwords, nbuf, n_tex) catch return ki(0);
  g_pull_pipes.append(alloc, pp) catch { v.destroyPullPipeline(pp); return ki(0); };
  return ki(@intCast(g_pull_pipes.items.len));
}

// gpuDrawPull[pipe; bufHandles_I; count] : record a pull draw — bind the resident
// storage buffers (by handle, in binding order) and draw `count` vertices.
export fn gpuDrawPull(pipe_k: ?K, bufs_k: ?K, count_k: ?K) callconv(.c) ?K {
  return recordPull(pipe_k, bufs_k, count_k, null);
}

// gpuDrawPullT[pipe; bufHandles_I; count; texHandles_I] : a pull draw that also binds
// textures at @group(1) — a vertex-pulled, textured draw (e.g. demo/earth.k).
export fn gpuDrawPullT(pipe_k: ?K, bufs_k: ?K, count_k: ?K, tex_k: ?K) callconv(.c) ?K {
  return recordPull(pipe_k, bufs_k, count_k, tex_k);
}

fn recordPull(pipe_k: ?K, bufs_k: ?K, count_k: ?K, tex_k: ?K) ?K {
  const ph = ki_val(pipe_k);
  if (ph <= 0 or ph > g_pull_pipes.items.len) return ki(0);
  const nbuf = g_pull_pipes.items[@intCast(ph - 1)].nbuf;
  const bp = kip(bufs_k) orelse return ki(0);
  const ngiven: usize = @intCast(@max(kn(bufs_k), 0));
  if (ngiven < nbuf) return ki(0);
  const count = ki_val(count_k);
  if (count <= 0) return ki(0);
  var pc: PullCall = .{ .pipe = @intCast(ph - 1), .bufs = [_]i32{0} ** vk.MAX_BIND, .nbuf = nbuf, .count = @intCast(count) };
  var i: usize = 0;
  while (i < nbuf) : (i += 1) pc.bufs[i] = bp[i];
  if (kip(tex_k)) |tp| {
    const nt: usize = @min(@as(usize, @intCast(@max(kn(tex_k), 0))), MAX_TEX);
    var j: usize = 0;
    while (j < nt) : (j += 1) pc.tex[j] = tp[j];
    pc.ntex = nt;
  }
  g_pull_calls.append(alloc, pc) catch return ki(0);
  return ki(0);
}

// Record all pull draws into cb (resolve handles → resident buffers per draw, plus
// an optional @group(1) texture set built the same way as the mesh path).
fn recordPulls(v: *vk.Vk, cb: anytype) void {
  var tbuf: [MAX_TEX]vk.Texture = undefined;
  for (g_pull_calls.items) |pc| {
    const pp = g_pull_pipes.items[pc.pipe];
    var bufs: [vk.MAX_BIND]vk.Buffer = undefined;
    var ok_all = true;
    var i: usize = 0;
    while (i < pc.nbuf) : (i += 1) {
      const h = pc.bufs[i];
      if (h <= 0 or h > g_bufs.items.len) { ok_all = false; break; }
      bufs[i] = g_bufs.items[@intCast(h - 1)];
    }
    if (!ok_all) continue;
    var tset = vk.Vk.nullSet();
    if (pp.n_tex > 0 and pc.ntex > 0) {
      var k: usize = 0;
      while (k < pc.ntex) : (k += 1) {
        const th = pc.tex[k];
        tbuf[k] = if (th > 0 and th <= g_textures.items.len) g_textures.items[@intCast(th - 1)] else g_textures.items[0];
      }
      tset = v.texSetL(pp.tex_dsl, pp.n_tex, tbuf[0..pc.ntex]);
    }
    v.drawPull(cb, pp, bufs[0..pc.nbuf], pc.count, tset);
  }
}

// ── textures (Phase 3, increment 2c); sampled by fragmentTexN on the pull path ──
var g_textures: std.ArrayList(vk.Texture) = .empty; // 1-based handles
const MAX_TEX = 8;

// gpuTexture[(w;h;comp)_I; data_I] -> handle : upload an image (expanded to RGBA).
export fn gpuTexture(whc_k: ?K, data_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const wp = kip(whc_k) orelse return ki(0);
  if (kn(whc_k) < 3) return ki(0);
  const w = wp[0]; const h = wp[1]; const comp = wp[2];
  if (w <= 0 or h <= 0 or comp <= 0) return ki(0);
  const dp = kip(data_k) orelse return ki(0);
  const wu: usize = @intCast(w); const hu: usize = @intCast(h); const cu: usize = @intCast(comp);
  const npix = wu * hu;
  if (kn(data_k) < @as(i32, @intCast(npix * cu))) return ki(0);
  const rgba = alloc.alloc(u8, npix * 4) catch return ki(0);
  defer alloc.free(rgba);
  const cl = struct { fn f(x: i32) u8 { return @intCast(@min(@as(i32, 255), @max(@as(i32, 0), x))); } }.f;
  var p: usize = 0;
  while (p < npix) : (p += 1) {
    const s = p * cu; const d = p * 4;
    if (cu >= 3) {
      rgba[d] = cl(dp[s]); rgba[d + 1] = cl(dp[s + 1]); rgba[d + 2] = cl(dp[s + 2]); rgba[d + 3] = if (cu >= 4) cl(dp[s + 3]) else 255;
    } else {
      const g = cl(dp[s]); rgba[d] = g; rgba[d + 1] = g; rgba[d + 2] = g; rgba[d + 3] = if (cu == 2) cl(dp[s + 1]) else 255;
    }
  }
  const t = v.createTexture(@intCast(w), @intCast(h), rgba) catch return ki(0);
  g_textures.append(alloc, t) catch { v.destroyTexture(t); return ki(0); };
  return ki(@intCast(g_textures.items.len));
}

// gpuTextureF[(w;h)_I; data_F] -> handle : upload w*h*4 f32 (RGBA/texel) as a
// NEAREST-sampled R32G32B32A32_SFLOAT data texture (exact per-texel reads).
export fn gpuTextureF(wh_k: ?K, data_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const wp = kip(wh_k) orelse return ki(0);
  if (kn(wh_k) < 2) return ki(0);
  const w = wp[0]; const h = wp[1];
  if (w <= 0 or h <= 0) return ki(0);
  const dp = kfp(data_k) orelse return ki(0);
  const wu: usize = @intCast(w); const hu: usize = @intCast(h);
  const need = wu * hu * 4;
  if (kn(data_k) < @as(i32, @intCast(need))) return ki(0);
  const t = v.createTextureF(@intCast(w), @intCast(h), dp[0..need]) catch return ki(0);
  g_textures.append(alloc, t) catch { v.destroyTexture(t); return ki(0); };
  return ki(@intCast(g_textures.items.len));
}

fn resetFrameMeshes() void {
  g_fill_verts.clearRetainingCapacity();
  g_fill_calls.clearRetainingCapacity();
  g_pull_calls.clearRetainingCapacity();
}

// ── 2-D fill pipeline (Phase 3, increment 3) ──────────────────────────────────
const FillCall = struct { byte_offset: u64, count: u32, frag: [44]f32, spirv: i32 }; // spirv=-1 → built-in fill
var g_fill_calls: std.ArrayList(FillCall) = .empty;
var g_fill_verts: std.ArrayList(f32) = .empty; // [x,y,u,v] per vertex
var g_fbuf: ?vk.Buffer = null;
var g_fbuf_cap: u64 = 0;
var g_spirv_pipes: std.ArrayList(vk.Vk.FillPipe) = .empty; // custom fill-shader pipelines

fn fillAccumulate(verts_k: ?K, frag: [44]f32, spirv: i32) void {
  const vf = kfp(verts_k) orelse return;
  const vn = kn(verts_k);
  if (vn < 4) return;
  const nfloats: usize = (@as(usize, @intCast(vn)) / 4) * 4;
  const byte_offset: u64 = g_fill_verts.items.len * @sizeOf(f32);
  g_fill_verts.appendSlice(alloc, vf[0..nfloats]) catch return;
  g_fill_calls.append(alloc, .{ .byte_offset = byte_offset, .count = @intCast(nfloats / 4), .frag = frag, .spirv = spirv }) catch return;
}

export fn gpuFill(verts_k: ?K, frag_k: ?K) callconv(.c) ?K {
  const ff = kfp(frag_k) orelse return ki(0);
  if (kn(frag_k) != 44) return ki(0);
  var frag: [44]f32 = undefined;
  var i: usize = 0;
  while (i < 44) : (i += 1) frag[i] = ff[i];
  fillAccumulate(verts_k, frag, -1);
  return ki(0);
}

// gpuSpirv[frag_words; _] -> negative handle : compile a custom fill-shader
// pipeline (dye.k fragment SPIR-V over the built-in fill vertex shader).
export fn gpuSpirv(words_k: ?K, _: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const words = wordsOf(words_k) orelse return ki(0);
  const fp = v.createFillShaderPipe(words) orelse return ki(0);
  g_spirv_pipes.append(alloc, fp) catch { v.destroyFillShaderPipe(fp); return ki(0); };
  return ki(-@as(i32, @intCast(g_spirv_pipes.items.len)));
}

// gpuFillShader[verts_F; handle] : draw 2-D triangles with a custom fill shader.
export fn gpuFillShader(verts_k: ?K, shader_k: ?K) callconv(.c) ?K {
  const sh = ki_val(shader_k);
  if (sh >= 0) return ki(0);
  const idx: usize = @intCast(-sh - 1);
  if (idx >= g_spirv_pipes.items.len) return ki(0);
  fillAccumulate(verts_k, [_]f32{0} ** 44, @intCast(idx));
  return ki(0);
}

// gpuTess[pts_F] -> [x,y,u,v,...] : CPU polygon triangulation (verbatim from the
// Dawn backend; no device). Multiple contours split on NaN x/y pairs.
export fn gpuTess(pts_k: ?K) callconv(.c) ?K {
  const pf = kfp(pts_k) orelse return ki(0);
  const pn = kn(pts_k);
  if (pn < 6) return ki(0);
  const npair: usize = @as(usize, @intCast(pn)) / 2;
  var da = std.heap.DebugAllocator(.{}).init;
  defer _ = da.deinit();
  const a = da.allocator();
  var contours = std.ArrayList(tri.Contour).initCapacity(a, 4) catch return ki(0);
  defer { for (contours.items) |c| a.free(c.pts); contours.deinit(a); }
  var cur = std.ArrayList(tri.Pt).initCapacity(a, 32) catch return ki(0);
  defer cur.deinit(a);
  for (0..npair) |i| {
    const x = pf[i * 2];
    const y = pf[i * 2 + 1];
    if (std.math.isNan(x) or std.math.isNan(y)) {
      if (cur.items.len >= 3) {
        const slice = a.dupe(tri.Pt, cur.items) catch return ki(0);
        contours.append(a, .{ .pts = slice }) catch return ki(0);
      }
      cur.clearRetainingCapacity();
    } else cur.append(a, .{ .x = x, .y = y }) catch return ki(0);
  }
  if (cur.items.len >= 3) {
    const slice = a.dupe(tri.Pt, cur.items) catch return ki(0);
    contours.append(a, .{ .pts = slice }) catch return ki(0);
  }
  var out = std.ArrayList(tri.Pt).initCapacity(a, 64) catch return ki(0);
  defer out.deinit(a);
  tri.triangulate(a, contours.items, &out) catch return ki(0);
  const n_out = out.items.len;
  const result_k = KF(@intCast(n_out * 4)) orelse return ki(0);
  const rf = kfp(result_k) orelse { ku(result_k); return ki(0); };
  for (out.items, 0..) |p, i| {
    rf[i * 4 + 0] = p.x; rf[i * 4 + 1] = p.y; rf[i * 4 + 2] = 0.5; rf[i * 4 + 3] = 1.0;
  }
  return result_k;
}

// Upload this frame's 2-D fill vertices and record all fill draws (base layer,
// before meshes). vw/vh = framebuffer size (the fill vertex shader's viewSize).
fn recordFills(v: *vk.Vk, cb: anytype, vw: f32, vh: f32) void {
  const nf = g_fill_verts.items.len;
  if (nf == 0) return;
  const need: u64 = nf * @sizeOf(f32);
  if (g_fbuf == null or need > g_fbuf_cap) {
    if (g_fbuf) |b| v.destroyBuffer(b);
    const cap = need * 2;
    g_fbuf = v.createVertexBuffer(cap) catch { g_fbuf = null; return; };
    g_fbuf_cap = cap;
  }
  const fb = g_fbuf.?;
  @memcpy(fb.mapped[0..need], std.mem.sliceAsBytes(g_fill_verts.items[0..nf]));
  for (g_fill_calls.items) |fc| {
    const set = v.fillSet(vw, vh, fc.frag[0..]);
    if (set == null) continue;
    const pipe = if (fc.spirv >= 0) g_spirv_pipes.items[@intCast(fc.spirv)].pipe else vk.Vk.nullPipe();
    v.drawFill(cb, fb, fc.byte_offset, fc.count, set, pipe);
  }
}

// Write a captured BGRA frame to <INK_SNAP_BASE|ink>-snap.png (png.zig swizzles).
fn writeSnapPng(bgra: []const u8, w: u32, h: u32) void {
  const base = if (getenv("INK_SNAP_BASE")) |b| std.mem.span(b) else "ink";
  const path = std.fmt.allocPrint(alloc, "{s}-snap.png", .{base}) catch return;
  defer alloc.free(path);
  png.writePng(alloc, path, w, h, bgra, w * 4) catch |e| {
    std.debug.print("[snap] write failed: {}\n", .{e});
    return;
  };
  std.debug.print("[snap] wrote {s} ({d}x{d})\n", .{ path, w, h });
}

// ── gpuRun[loop_fn; config] : windowed event loop (Phase 3, increment 1) ──────
// Opens a Vulkan-backed window, clears each frame, and calls loop_fn(props) with
// {width;height;mx;my;time;events}. Drawing pipelines land in increment 2; for now
// the frame is a clear + present, and compute inside the callback works as usual.
export fn gpuRun(loop_k: ?K, config_k: ?K) callconv(.c) ?K {
  const loop_fn = loop_k orelse return ki(0);
  var win_w: i32 = 800;
  var win_h: i32 = 600;
  if (config_k) |cfg| if (kfp(cfg)) |cf| if (kn(cfg) >= 2) {
    win_w = @intFromFloat(cf[0]);
    win_h = @intFromFloat(cf[1]);
  };
  if (getenv("INK_SIZE")) |sz| {
    const s = std.mem.span(sz);
    if (std.mem.indexOfScalar(u8, s, 'x')) |xi| {
      win_w = std.fmt.parseInt(i32, s[0..xi], 10) catch win_w;
      win_h = std.fmt.parseInt(i32, s[xi + 1 ..], 10) catch win_h;
    }
  }
  // INK_FRAMES=N exits after N frames (headless CI; window never needs a close click).
  var frame_limit: i64 = -1;
  if (getenv("INK_FRAMES")) |f| frame_limit = std.fmt.parseInt(i64, std.mem.span(f), 10) catch -1;
  // INK_SNAP present → capture one PNG of frame `snap_frame` then exit (headless).
  const snap = getenv("INK_SNAP") != null;
  const snap_frame: i64 = if (getenv("INK_SNAP")) |s| (std.fmt.parseInt(i64, std.mem.span(s), 10) catch 0) else 0;
  if (snap and frame_limit < 0) frame_limit = snap_frame + 2;

  vk.initGlfwLoader(); // before glfwInit: GLFW resolves Vulkan via MoltenVK
  zglfw.init() catch return ki(-1);
  defer zglfw.terminate();
  zglfw.windowHint(zglfw.ClientAPI, zglfw.NoAPI);
  zglfw.windowHint(zglfw.CocoaRetinaFramebuffer, 1);
  if (frame_limit >= 0 or snap) zglfw.windowHint(zglfw.Visible, 0); // headless
  const window = zglfw.createWindow(win_w, win_h, "ink", null, null) catch return ki(-1);
  defer zglfw.destroyWindow(window);
  _ = zglfw.setKeyCallback(window, keyCb);
  _ = zglfw.setCharCallback(window, charCb);
  _ = zglfw.setMouseButtonCallback(window, mouseBtnCb);
  _ = zglfw.setScrollCallback(window, scrollCb);

  var v = vk.Vk.initWindowed(@ptrCast(window), @intCast(win_w), @intCast(win_h)) catch return ki(-1);
  g_vk = &v;
  g_bufs = .empty;
  g_pipes = .empty;
  defer { resetRegistries(); v.deinit(); g_vk = null; }

  const start = zglfw.getTime();
  var frames: i64 = 0;
  var snap_buf: ?vk.Buffer = null;
  defer if (snap_buf) |b| v.destroyBuffer(b);
  while (!zglfw.windowShouldClose(window)) {
    zglfw.pollEvents();

    var fbw: i32 = 0;
    var fbh: i32 = 0;
    zglfw.getFramebufferSize(window, &fbw, &fbh);
    var ww: i32 = 0;
    var wh: i32 = 0;
    zglfw.getWindowSize(window, &ww, &wh);
    g_dpr_x = if (ww > 0) @as(f64, @floatFromInt(fbw)) / @as(f64, @floatFromInt(ww)) else 1.0;
    g_dpr_y = if (wh > 0) @as(f64, @floatFromInt(fbh)) / @as(f64, @floatFromInt(wh)) else 1.0;

    var mx: f64 = 0;
    var my: f64 = 0;
    zglfw.getCursorPos(window, &mx, &my);
    const t: f32 = @floatCast(zglfw.getTime() - start);

    resetFrameMeshes(); // callback accumulates this frame's mesh draws

    // Run the k callback (compute + draw commands), then clear + record + present.
    // width/height/mx/my are FRAMEBUFFER pixels (mx/my already scaled by the device pixel
    // ratio, so cursor and drawing share one space); dpr = that ratio (framebuffer/window),
    // so a UI can work in logical units and multiply by dpr for crisp, consistent sizing.
    const prop_keys = [7][*:0]const u8{ "width", "height", "mx", "my", "time", "dpr", "events" };
    const v_w = kf(@floatFromInt(fbw));
    const v_h = kf(@floatFromInt(fbh));
    const v_mx = kf(@floatCast(mx * g_dpr_x));
    const v_my = kf(@floatCast(my * g_dpr_y));
    const v_t = kf(t);
    const v_dpr = kf(@floatCast(g_dpr_x));
    const v_events = buildEvents();
    g_nev = 0;
    const prop_vals = [7]?K{ v_w, v_h, v_mx, v_my, v_t, v_dpr, v_events };
    if (k_make_dict(7, &prop_keys, &prop_vals)) |pk| {
      const result = k_call(loop_fn, pk);
      ku(result);
      ku(pk);
    }
    ku(v_w); ku(v_h); ku(v_mx); ku(v_my); ku(v_t); ku(v_dpr); ku(v_events);

    v.sync(); // finish any compute the callback queued before the frame

    const do_snap = snap and frames == snap_frame;
    if (do_snap and snap_buf == null) {
      const ext = v.extent();
      snap_buf = v.createBuffer(@as(u64, ext[0]) * ext[1] * 4, false) catch null;
    }
    if (v.beginFrame(@intCast(fbw), @intCast(fbh), .{ 0, 0, 0, 1 })) |cb| {
      recordFills(&v, cb, @floatFromInt(fbw), @floatFromInt(fbh)); // 2-D base layer
      recordPulls(&v, cb); // vertex-pulled geometry (kk2 §5): reads resident buffers
      v.endFrame(@intCast(fbw), @intCast(fbh), if (do_snap) snap_buf else null);
      if (do_snap) if (snap_buf) |sb| {
        v.waitIdle();
        const ext = v.extent();
        writeSnapPng(sb.mapped[0 .. @as(usize, ext[0]) * ext[1] * 4], ext[0], ext[1]);
        break;
      };
    }

    frames += 1;
    if (frame_limit >= 0 and frames >= frame_limit) break;
  }
  return ki(0);
}

// ── gpuCaps: device capability dict (doc/design/kk.md §4) ─────────────────────
// Feature-gated capabilities the kk compiler schedules around; query inside a
// gpu.computeRun / window.run (needs the live device). All values numeric:
// api = major + minor/10 (e.g. 1.2), subgroup = lane count, rest are 0/1 flags.
export fn gpuCaps(_: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const cp = v.queryCaps();
  const keys = [_][*:0]const u8{ "api", "subgroup", "sgArith", "sgBallot", "sgShuffle", "descIndex", "runtimeArray", "bda", "f16", "atomicFadd" };
  const vals = [_]?K{
    kf(@as(f32, @floatFromInt(cp.api_major)) + @as(f32, @floatFromInt(cp.api_minor)) / 10.0),
    ki(@intCast(cp.subgroup_size)),
    ki(@intFromBool(cp.sg_arith)),
    ki(@intFromBool(cp.sg_ballot)),
    ki(@intFromBool(cp.sg_shuffle)),
    ki(@intFromBool(cp.desc_index)),
    ki(@intFromBool(cp.runtime_array)),
    ki(@intFromBool(cp.bda)),
    ki(@intFromBool(cp.f16)),
    ki(@intFromBool(cp.atomic_fadd)),
  };
  return k_make_dict(10, &keys, &vals);
}

// gpuWgsl was dropped at the Dawn cutover — WGSL authoring contradicts the
// SPIR-V-native direction; use dye.k → gpu.compileSpirv instead.

// ── registry install ──────────────────────────────────────────────────────────
fn inkInit(reg: *anyopaque) void {
  const r: *const @import("kabi").KRegistry(K) = @ptrCast(@alignCast(reg));
  g_api = .{
    .k_call = r.k_call, .k_make_dict = r.k_make_dict, .k_make_table = r.k_make_table,
    .kf = r.kf, .ki = r.ki, .kn = r.kn, .kfp = r.kfp, .kip = r.kip, .kcp = r.kcp,
    .ki_val = r.ki_val, .KI = r.KI, .KF = r.KF, .KS = r.KS, .ksp = r.ksp,
    .kintern = r.kintern, .ku = r.ku,
  };
  r.k_register("gpuComputeRun", @ptrCast(&gpuComputeRun), 1);
  r.k_register("gpuCompute", @ptrCast(&gpuCompute), 2);
  r.k_register("gpuCompute2", @ptrCast(&gpuCompute2), 3);
  r.k_register("gpuBufferNew", @ptrCast(&gpuBufferNew), 1);
  r.k_register("gpuUniformNew", @ptrCast(&gpuUniformNew), 1);
  r.k_register("gpuUniformNewI", @ptrCast(&gpuUniformNewI), 1);
  r.k_register("gpuBufferWrite", @ptrCast(&gpuBufferWrite), 2);
  r.k_register("gpuBufferRead", @ptrCast(&gpuBufferRead), 1);
  r.k_register("gpuBufferReadI", @ptrCast(&gpuBufferReadI), 1);
  r.k_register("gpuBufferFree", @ptrCast(&gpuBufferFree), 1);
  r.k_register("gpuComputeNew", @ptrCast(&gpuComputeNew), 2);
  r.k_register("gpuComputeNewU", @ptrCast(&gpuComputeNewU), 2);
  r.k_register("gpuDispatch", @ptrCast(&gpuDispatch), 3);
  r.k_register("gpuDispatchLoop", @ptrCast(&gpuDispatchLoop), 5);
  r.k_register("gpuRun", @ptrCast(&gpuRun), 2);
  r.k_register("gpuFill", @ptrCast(&gpuFill), 2);
  r.k_register("gpuTess", @ptrCast(&gpuTess), 1);
  r.k_register("gpuSpirv", @ptrCast(&gpuSpirv), 2);
  r.k_register("gpuFillShader", @ptrCast(&gpuFillShader), 2);
  r.k_register("gpuMeshPull", @ptrCast(&gpuMeshPull), 2);
  r.k_register("gpuDrawPull", @ptrCast(&gpuDrawPull), 3);
  r.k_register("gpuDrawPullT", @ptrCast(&gpuDrawPullT), 4);
  r.k_register("gpuTexture", @ptrCast(&gpuTexture), 2);
  r.k_register("gpuTextureF", @ptrCast(&gpuTextureF), 2);
  r.k_register("gpuCaps", @ptrCast(&gpuCaps), 1);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
export fn ink_ext_init_gpu(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
