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
var g_pipes: std.ArrayList(vk.Pipeline) = .empty;

fn resetRegistries() void {
  const v = g_vk.?;
  v.sync(); // finish any in-flight dispatch before freeing its buffers
  for (g_bufs.items) |b| v.destroyBuffer(b);
  for (g_pipes.items) |p| v.destroyPipeline(p);
  for (g_mesh_pipes.items) |mp| v.destroyMeshPipeline(mp);
  if (g_vbuf) |b| v.destroyBuffer(b);
  g_bufs.deinit(alloc); g_pipes.deinit(alloc); g_mesh_pipes.deinit(alloc);
  g_mesh_verts.deinit(alloc); g_mesh_calls.deinit(alloc);
  g_bufs = .empty; g_pipes = .empty; g_mesh_pipes = .empty;
  g_mesh_verts = .empty; g_mesh_calls = .empty; g_vbuf = null; g_vbuf_cap = 0;
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
  g_bufs.append(alloc, b) catch { v.destroyBuffer(b); return ki(0); };
  return ki(@intCast(g_bufs.items.len));
}
export fn gpuBufferNew(data_k: ?K) callconv(.c) ?K { return newBuffer(data_k, false); }
export fn gpuUniformNew(data_k: ?K) callconv(.c) ?K { return newBuffer(data_k, true); }

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
  const n: usize = @intCast(b.size / @sizeOf(f32));
  return floatsOut(b.mapped[0..b.size], n);
}

export fn gpuBufferReadI(h_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const h = ki_val(h_k);
  if (h <= 0 or h > g_bufs.items.len) return ki(0);
  v.sync();
  const b = g_bufs.items[@intCast(h - 1)];
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

export fn gpuDispatchLoop(pipe_k: ?K, packed_k: ?K, reps_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const ph = ki_val(pipe_k);
  if (ph <= 0 or ph > g_pipes.items.len) return ki(0);
  const p = g_pipes.items[@intCast(ph - 1)];
  const nbind = p.nbind;
  const pp = kip(packed_k) orelse return ki(0);
  const plen: usize = @intCast(kn(packed_k));
  if (plen < 1 + 2 * nbind) return ki(0);
  const nthreads = pp[0];
  if (nthreads <= 0) return ki(0);
  const reps = ki_val(reps_k);
  if (reps <= 0) return ki(0);

  var bufsA: [vk.MAX_BIND]vk.Buffer = undefined;
  var bufsB: [vk.MAX_BIND]vk.Buffer = undefined;
  var i: usize = 0;
  while (i < nbind) : (i += 1) {
    const ha = pp[1 + i];
    const hb = pp[1 + nbind + i];
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

// ── Mesh pipelines + per-frame draw accumulation (Phase 3, increment 2) ───────
var g_mesh_pipes: std.ArrayList(vk.MeshPipe) = .empty; // 1-based handles
const MeshCall = struct { pipe: usize, byte_offset: u64, count: u32, has_uni: bool, uniform: [vk.MESH_UNI_FLOATS]f32 };
var g_mesh_calls: std.ArrayList(MeshCall) = .empty; // this frame's draws
var g_mesh_verts: std.ArrayList(f32) = .empty; // this frame's vertex data
var g_vbuf: ?vk.Buffer = null; // persistent mesh vertex buffer (grows)
var g_vbuf_cap: u64 = 0;

// Derive the vertex attribute layout from the vertex shader's Input variables +
// Location decorations (ported from gpu.zig meshVtxLayout). Component count comes
// from the fixed input pointer type ids in lib/gpu/spirv.k
// (PinF32=10→1, PinV2=14→2, PinV3=18→3, PinV4=12→4). Returns count + float stride.
fn meshVtxLayout(words: []const u32, out: *[16]vk.Vk.VtxAttr) struct { count: usize, stride_floats: u32 } {
  var dec_id: [16]u32 = undefined;
  var dec_loc: [16]u32 = undefined;
  var ndec: usize = 0;
  var in_id: [16]u32 = undefined;
  var in_comp: [16]u32 = undefined;
  var nin: usize = 0;
  var i: usize = 5;
  while (i < words.len) {
    const w0 = words[i];
    const wc: usize = w0 >> 16;
    const op: u32 = w0 & 0xffff;
    if (wc == 0) break;
    if (op == 71 and i + 3 < words.len and words[i + 2] == 30) { // OpDecorate Location
      if (ndec < 16) { dec_id[ndec] = words[i + 1]; dec_loc[ndec] = words[i + 3]; ndec += 1; }
    } else if (op == 59 and i + 3 < words.len and words[i + 3] == 1) { // OpVariable Input
      const comp: u32 = switch (words[i + 1]) { 10 => 1, 14 => 2, 18 => 3, 12 => 4, else => 0 };
      if (comp > 0 and nin < 16) { in_id[nin] = words[i + 2]; in_comp[nin] = comp; nin += 1; }
    }
    i += wc;
  }
  var offset: u32 = 0;
  var count: usize = 0;
  var loc: u32 = 0;
  while (loc < nin) : (loc += 1) {
    var idx: usize = nin;
    var k: usize = 0;
    while (k < nin) : (k += 1) {
      var d: usize = 0;
      while (d < ndec) : (d += 1) { if (dec_id[d] == in_id[k] and dec_loc[d] == loc) { idx = k; break; } }
      if (idx != nin) break;
    }
    if (idx == nin) break;
    const comp = in_comp[idx];
    out[count] = .{ .location = loc, .comps = comp, .offset = offset };
    offset += comp * @sizeOf(f32);
    count += 1;
  }
  return .{ .count = count, .stride_floats = offset / @sizeOf(f32) };
}

// Does the shader declare an OpVariable in the Uniform storage class (2)?
fn hasUniformVar(words: []const u32) bool {
  var i: usize = 5;
  while (i < words.len) {
    const w0 = words[i];
    const wc: usize = w0 >> 16;
    if (wc == 0) break;
    if ((w0 & 0xffff) == 59 and i + 3 < words.len and words[i + 3] == 2) return true;
    i += wc;
  }
  return false;
}

export fn gpuMesh(vtx_k: ?K, frg_k: ?K) callconv(.c) ?K {
  const v = g_vk orelse return ki(0);
  const vwords = wordsOf(vtx_k) orelse return ki(0);
  const fwords = wordsOf(frg_k) orelse return ki(0);
  var attrs: [16]vk.Vk.VtxAttr = undefined;
  const li = meshVtxLayout(vwords, &attrs);
  if (li.count == 0) return ki(0);
  const has_uni = hasUniformVar(vwords) or hasUniformVar(fwords);
  const mp = v.createMeshPipeline(vwords, fwords, attrs[0..li.count], li.stride_floats * 4, has_uni) catch return ki(0);
  g_mesh_pipes.append(alloc, mp) catch { v.destroyMeshPipeline(mp); return ki(0); };
  return ki(@intCast(g_mesh_pipes.items.len));
}

fn drawMeshCommon(verts_k: ?K, handle: i32, uni: [vk.MESH_UNI_FLOATS]f32, has_uni: bool) void {
  if (handle <= 0 or handle > g_mesh_pipes.items.len) return;
  const stride_floats: usize = g_mesh_pipes.items[@intCast(handle - 1)].stride / 4;
  if (stride_floats == 0) return;
  const vf = kfp(verts_k) orelse return;
  const vn = kn(verts_k);
  if (vn < @as(i32, @intCast(stride_floats))) return;
  const nfloats: usize = (@as(usize, @intCast(vn)) / stride_floats) * stride_floats;
  const byte_offset: u64 = g_mesh_verts.items.len * @sizeOf(f32);
  g_mesh_verts.appendSlice(alloc, vf[0..nfloats]) catch return;
  g_mesh_calls.append(alloc, .{ .pipe = @intCast(handle - 1), .byte_offset = byte_offset, .count = @intCast(nfloats / stride_floats), .has_uni = has_uni, .uniform = uni }) catch return;
}

export fn gpuDrawMesh(verts_k: ?K, handle_k: ?K) callconv(.c) ?K {
  drawMeshCommon(verts_k, ki_val(handle_k), [_]f32{0} ** vk.MESH_UNI_FLOATS, false);
  return ki(0);
}

export fn gpuDrawMeshU(verts_k: ?K, handle_k: ?K, uni_k: ?K) callconv(.c) ?K {
  var uni = [_]f32{0} ** vk.MESH_UNI_FLOATS;
  if (kfp(uni_k)) |up| {
    const m: usize = @min(@as(usize, @intCast(@max(kn(uni_k), 0))), vk.MESH_UNI_FLOATS);
    var j: usize = 0;
    while (j < m) : (j += 1) uni[j] = up[j];
  }
  drawMeshCommon(verts_k, ki_val(handle_k), uni, true);
  return ki(0);
}

// Upload the frame's accumulated mesh vertices and record all draws into cb.
fn recordMeshes(v: *vk.Vk, cb: anytype) void {
  const nf = g_mesh_verts.items.len;
  if (nf == 0) return;
  const need: u64 = nf * @sizeOf(f32);
  if (g_vbuf == null or need > g_vbuf_cap) {
    if (g_vbuf) |b| v.destroyBuffer(b);
    const cap = need * 2;
    g_vbuf = v.createVertexBuffer(cap) catch { g_vbuf = null; return; };
    g_vbuf_cap = cap;
  }
  const vb = g_vbuf.?;
  @memcpy(vb.mapped[0..need], std.mem.sliceAsBytes(g_mesh_verts.items[0..nf]));
  for (g_mesh_calls.items) |mc| {
    const set = if (mc.has_uni) v.meshUniformSet(mc.uniform[0..]) else null;
    v.drawMesh(cb, g_mesh_pipes.items[mc.pipe], vb, mc.byte_offset, mc.count, set);
  }
}

fn resetFrameMeshes() void {
  g_mesh_verts.clearRetainingCapacity();
  g_mesh_calls.clearRetainingCapacity();
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
    const prop_keys = [6][*:0]const u8{ "width", "height", "mx", "my", "time", "events" };
    const v_w = kf(@floatFromInt(fbw));
    const v_h = kf(@floatFromInt(fbh));
    const v_mx = kf(@floatCast(mx * g_dpr_x));
    const v_my = kf(@floatCast(my * g_dpr_y));
    const v_t = kf(t);
    const v_events = buildEvents();
    g_nev = 0;
    const prop_vals = [6]?K{ v_w, v_h, v_mx, v_my, v_t, v_events };
    if (k_make_dict(6, &prop_keys, &prop_vals)) |pk| {
      const result = k_call(loop_fn, pk);
      ku(result);
      ku(pk);
    }
    ku(v_w); ku(v_h); ku(v_mx); ku(v_my); ku(v_t); ku(v_events);

    v.sync(); // finish any compute the callback queued before the frame

    const do_snap = snap and frames == snap_frame;
    if (do_snap and snap_buf == null) {
      const ext = v.extent();
      snap_buf = v.createBuffer(@as(u64, ext[0]) * ext[1] * 4, false) catch null;
    }
    if (v.beginFrame(@intCast(fbw), @intCast(fbh), .{ 0, 0, 0, 1 })) |cb| {
      recordMeshes(&v, cb);
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

// ── Render/window exports — stubs until Phase 3 increment 2 ───────────────────
export fn gpuFill(_: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuTess(_: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuSpirv(_: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuFillShader(_: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuUploadMesh(_: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuDrawInstanced(_: ?K, _: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuDrawGeomResident(_: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuDrawInstancedT(_: ?K, _: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuDrawMeshT(_: ?K, _: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuDrawGeomT(_: ?K, _: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuTexture(_: ?K, _: ?K) callconv(.c) ?K { return ki(0); }
export fn gpuWgsl(_: ?K) callconv(.c) ?K { return ki(0); }

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
  r.k_register("gpuBufferWrite", @ptrCast(&gpuBufferWrite), 2);
  r.k_register("gpuBufferRead", @ptrCast(&gpuBufferRead), 1);
  r.k_register("gpuBufferReadI", @ptrCast(&gpuBufferReadI), 1);
  r.k_register("gpuComputeNew", @ptrCast(&gpuComputeNew), 2);
  r.k_register("gpuComputeNewU", @ptrCast(&gpuComputeNewU), 2);
  r.k_register("gpuDispatch", @ptrCast(&gpuDispatch), 3);
  r.k_register("gpuDispatchLoop", @ptrCast(&gpuDispatchLoop), 3);
  // render stubs (registered so lib/gpu.k loads; real impl in Phase 3)
  r.k_register("gpuRun", @ptrCast(&gpuRun), 2);
  r.k_register("gpuFill", @ptrCast(&gpuFill), 2);
  r.k_register("gpuTess", @ptrCast(&gpuTess), 1);
  r.k_register("gpuSpirv", @ptrCast(&gpuSpirv), 2);
  r.k_register("gpuFillShader", @ptrCast(&gpuFillShader), 2);
  r.k_register("gpuMesh", @ptrCast(&gpuMesh), 2);
  r.k_register("gpuUploadMesh", @ptrCast(&gpuUploadMesh), 2);
  r.k_register("gpuDrawInstanced", @ptrCast(&gpuDrawInstanced), 3);
  r.k_register("gpuDrawGeomResident", @ptrCast(&gpuDrawGeomResident), 2);
  r.k_register("gpuDrawInstancedT", @ptrCast(&gpuDrawInstancedT), 3);
  r.k_register("gpuDrawMesh", @ptrCast(&gpuDrawMesh), 2);
  r.k_register("gpuDrawMeshU", @ptrCast(&gpuDrawMeshU), 3);
  r.k_register("gpuDrawMeshT", @ptrCast(&gpuDrawMeshT), 3);
  r.k_register("gpuDrawGeomT", @ptrCast(&gpuDrawGeomT), 3);
  r.k_register("gpuTexture", @ptrCast(&gpuTexture), 2);
  r.k_register("gpuWgsl", @ptrCast(&gpuWgsl), 1);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
export fn ink_ext_init_gpu(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
