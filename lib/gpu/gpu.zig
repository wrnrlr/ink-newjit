/// GPU extension for ink — loaded via `"./zig-out/lib/libgpu.dylib" 2: (`gpu_run; 2)`.
///
/// K API (after loading via lib/gpu/gpu.k):
///   gpu_run[loop_fn; config]   blocking event loop; calls loop_fn(props) each frame
///   gpu_fill[verts_F; frag_F]  draw triangles (call inside frame callback)
///   gpu_tess[pts_F]            tessellate polygon → flat F vertex array
///
/// props dict passed to loop_fn each frame:
///   {width: f; height: f; mx: f; my: f; time: f}
///
/// Host K API imported via dynamic linker (exported by the ink binary):
///   k_call, k_make_dict, ki, kf, kn, kfp, ku, KF

const std = @import("std");
// Zig 0.16's std no longer exposes getenv; call libc directly.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
// std.time no longer exposes a wall-clock timestamp; call libc gettimeofday.
const timeval = extern struct { sec: i64, usec: i32 };
extern fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;
fn epochMillis() i64 {
  var tv: timeval = undefined;
  _ = gettimeofday(&tv, null);
  return tv.sec * 1000 + @divTrunc(tv.usec, 1000);
}
fn envStr(name: [*:0]const u8) ?[]const u8 {
  return std.mem.span(getenv(name) orelse return null);
}
fn envInt(name: [*:0]const u8) ?i64 {
  return std.fmt.parseInt(i64, envStr(name) orelse return null, 10) catch null;
}
const zglfw = @import("zglfw");
const zgpu  = @import("zgpu");
const wgpu  = zgpu.wgpu;
const render = @import("render");
const tri    = @import("triangulate");
const png    = @import("png.zig");
const Renderer = render.Renderer;

// ── Host K API — captured from the registry passed to terse_init ─────────────

const K = *anyopaque;

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

// Thin wrappers so the rest of the file can call ki/kf/etc. without changing.
fn ki(v: i32) ?K         { return g_api.?.ki(v); }
fn kf(v: f32) ?K         { return g_api.?.kf(v); }
fn kn(x: ?K) i32         { return g_api.?.kn(x); }
fn kfp(x: ?K) ?[*]f32   { return g_api.?.kfp(x); }
fn kip(x: ?K) ?[*]i32   { return g_api.?.kip(x); }
fn kcp(x: ?K) ?[*]u8    { return g_api.?.kcp(x); }
fn ki_val(x: ?K) i32    { return g_api.?.ki_val(x); }
fn KI(n: i32) ?K         { return g_api.?.KI(n); }
fn KF(n: i32) ?K         { return g_api.?.KF(n); }
fn KS(n: i32) ?K         { return g_api.?.KS(n); }
fn ksp(x: ?K) ?[*]u32   { return g_api.?.ksp(x); }
fn kintern(s: [*:0]const u8) u32 { return g_api.?.kintern(s); }
fn ku(x: ?K) void        { g_api.?.ku(x); }
fn k_call(f: K, a: K) ?K { return g_api.?.k_call(f, a); }
fn k_make_dict(n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?K) ?K {
  return g_api.?.k_make_dict(n, keys, vals);
}
fn k_make_table(n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?K) ?K {
  return g_api.?.k_make_table(n, keys, vals);
}

// ── Frame-local renderer (set while the frame callback executes) ───────────────

var g_renderer: ?*Renderer = null;

// ── Event queue → props`events table ──────────────────────────────────────────
//
// Every input transition since the last frame is recorded as one Event and
// handed to the loop_fn as a flat table (one row per event). A `kind` symbol
// column discriminates the row; unused payload columns hold 0N/0n nulls the
// consumer filters.
//
//   kind    code            mods    down     x,y            amt
//   `text   codepoint       0N      0N       cursor px      0n
//   `key    GLFW keycode    modbits 1/0      cursor px      0n
//   `mouse  button index    modbits 1/0      cursor px      0n
//   `scroll 0N              0N      0N       cursor px      wheel dy
//
const NI: i32 = -2147483648;                 // ink null int (0N)

// The kind discriminant is a symbol, interned once on first use. `Event.kind`
// stores the interned id directly, so the `kind` column is filled with no mapping.
var g_kind_text: u32 = 0;
var g_kind_key: u32 = 0;
var g_kind_mouse: u32 = 0;
var g_kind_scroll: u32 = 0;
var g_kind_ready: bool = false;
fn ensureKinds() void {
  if (g_kind_ready) return;
  g_kind_text = kintern("text");
  g_kind_key = kintern("key");
  g_kind_mouse = kintern("mouse");
  g_kind_scroll = kintern("scroll");
  g_kind_ready = true;
}
fn KIND_TEXT() u32 { ensureKinds(); return g_kind_text; }
fn KIND_KEY() u32 { ensureKinds(); return g_kind_key; }
fn KIND_MOUSE() u32 { ensureKinds(); return g_kind_mouse; }
fn KIND_SCROLL() u32 { ensureKinds(); return g_kind_scroll; }

const Event = struct { kind: u32, code: i32, mods: i32, down: i32, x: f32, y: f32, amt: f32 };
const QCAP = 256;
var g_events: [QCAP]Event = undefined;
var g_nev: usize = 0;

// Device-pixel ratio from the previous frame, so callback-time cursor positions
// match the framebuffer-space mx/my the frame reports. Stable across frames.
var g_dpr_x: f64 = 1.0;
var g_dpr_y: f64 = 1.0;

fn cursorPx(win: *zglfw.Window) [2]f32 {
  var cx: f64 = 0;
  var cy: f64 = 0;
  zglfw.getCursorPos(win, &cx, &cy);
  return .{ @floatCast(cx * g_dpr_x), @floatCast(cy * g_dpr_y) };
}

fn pushEvent(e: Event) void {
  if (g_nev < QCAP) {
    g_events[g_nev] = e;
    g_nev += 1;
  }
}

fn keyCb(win: *zglfw.Window, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
  const down = (action != zglfw.Release);
  const c = cursorPx(win);
  pushEvent(.{ .kind = KIND_KEY(), .code = key, .mods = mods, .down = if (down) 1 else 0, .x = c[0], .y = c[1], .amt = std.math.nan(f32) });
}

fn charCb(win: *zglfw.Window, codepoint: c_uint) callconv(.c) void {
  const c = cursorPx(win);
  pushEvent(.{ .kind = KIND_TEXT(), .code = @intCast(codepoint), .mods = NI, .down = NI, .x = c[0], .y = c[1], .amt = std.math.nan(f32) });
}

fn mouseBtnCb(win: *zglfw.Window, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
  const c = cursorPx(win);
  pushEvent(.{ .kind = KIND_MOUSE(), .code = button, .mods = mods, .down = if (action == zglfw.Press) 1 else 0, .x = c[0], .y = c[1], .amt = std.math.nan(f32) });
}

fn scrollCb(win: *zglfw.Window, _: f64, yoffset: f64) callconv(.c) void {
  const c = cursorPx(win);
  pushEvent(.{ .kind = KIND_SCROLL(), .code = NI, .mods = NI, .down = NI, .x = c[0], .y = c[1], .amt = @floatCast(yoffset) });
}

// Build the `events` TABLE directly (k_make_table, so the consumer needs no `+`
// flip). Returns an empty-row table when no events occurred. Columns are released
// by the caller after they are folded into the table.
fn buildEvents() ?K {
  const n: i32 = @intCast(g_nev);
  const c_kind = KS(n);   // symbol column: `text `key `mouse `scroll
  const c_code = KI(n);
  const c_mods = KI(n);
  const c_down = KI(n);
  const c_x = KF(n);
  const c_y = KF(n);
  const c_amt = KF(n);
  if (g_nev != 0) {
    const pk = ksp(c_kind).?;
    const pc = kip(c_code).?;
    const pm = kip(c_mods).?;
    const pd = kip(c_down).?;
    const px = kfp(c_x).?;
    const py = kfp(c_y).?;
    const pa = kfp(c_amt).?;
    for (g_events[0..g_nev], 0..) |e, i| {
      pk[i] = e.kind;   // already the interned kind symbol id
      pc[i] = e.code;
      pm[i] = e.mods;
      pd[i] = e.down;
      px[i] = e.x;
      py[i] = e.y;
      pa[i] = e.amt;
    }
  }
  const keys = [7][*:0]const u8{ "kind", "code", "mods", "down", "x", "y", "amt" };
  const vals = [7]?K{ c_kind, c_code, c_mods, c_down, c_x, c_y, c_amt };
  const table = k_make_table(7, &keys, &vals);
  ku(c_kind); ku(c_code); ku(c_mods); ku(c_down); ku(c_x); ku(c_y); ku(c_amt);
  return table;
}

// ── gpu_fill ──────────────────────────────────────────────────────────────────
//
// verts_F: flat f32 array, stride 4 [x, y, u, v] — must be multiple of 4
// frag_F:  44 floats matching FragUniforms layout in fill.wgsl

export fn gpuFill(verts_k: ?K, frag_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vf = kfp(verts_k) orelse return ki(0);
  const vn = kn(verts_k);
  const ff = kfp(frag_k) orelse return ki(0);
  if (kn(frag_k) != 44) return ki(0);

  var fu: render.FragUniforms = undefined;
  for (0..11) |i| fu.frag[i] = .{ ff[i*4], ff[i*4+1], ff[i*4+2], ff[i*4+3] };

  const n_verts: usize = @intCast(@divTrunc(vn, 4));
  const verts_slice = @as([*]const render.Vertex, @ptrCast(@alignCast(vf)))[0..n_verts];
  r.draw(verts_slice, fu) catch {};
  return ki(0);
}

// ── gpu_tess ──────────────────────────────────────────────────────────────────
//
// pts_F: flat f32 [x0,y0,x1,y1,...] polygon. Multiple contours (e.g. a glyph
// outline with counters) may be packed into one array separated by a NaN x/y
// pair; holes are then resolved by signed area. A single contour with no NaN
// behaves exactly as before, so existing callers are unaffected.
// Returns flat f32 [x,y,u,v,...] triangle vertices (u=0.5, v=1.0)

export fn gpuTess(pts_k: ?K) callconv(.c) ?K {
  const pf = kfp(pts_k) orelse return ki(0);
  const pn = kn(pts_k);
  if (pn < 6) return ki(0);

  const npair: usize = @as(usize, @intCast(pn)) / 2;
  var da = std.heap.DebugAllocator(.{}).init;
  defer _ = da.deinit();
  const alloc = da.allocator();

  // Split the flat point stream into contours on NaN-pair separators.
  var contours = std.ArrayList(tri.Contour).initCapacity(alloc, 4) catch return ki(0);
  defer {
    for (contours.items) |c| alloc.free(c.pts);
    contours.deinit(alloc);
  }
  var cur = std.ArrayList(tri.Pt).initCapacity(alloc, 32) catch return ki(0);
  defer cur.deinit(alloc);
  for (0..npair) |i| {
    const x = pf[i * 2];
    const y = pf[i * 2 + 1];
    if (std.math.isNan(x) or std.math.isNan(y)) {
      if (cur.items.len >= 3) {
        const slice = alloc.dupe(tri.Pt, cur.items) catch return ki(0);
        contours.append(alloc, .{ .pts = slice }) catch return ki(0);
      }
      cur.clearRetainingCapacity();
    } else {
      cur.append(alloc, .{ .x = x, .y = y }) catch return ki(0);
    }
  }
  if (cur.items.len >= 3) {
    const slice = alloc.dupe(tri.Pt, cur.items) catch return ki(0);
    contours.append(alloc, .{ .pts = slice }) catch return ki(0);
  }

  var out = std.ArrayList(tri.Pt).initCapacity(alloc, 64) catch return ki(0);
  defer out.deinit(alloc);

  tri.triangulate(alloc, contours.items, &out) catch return ki(0);

  const n_out = out.items.len;
  const result_k = KF(@intCast(n_out * 4)) orelse return ki(0);
  const rf = kfp(result_k) orelse { ku(result_k); return ki(0); };
  for (out.items, 0..) |p, i| {
  rf[i * 4 + 0] = p.x;
  rf[i * 4 + 1] = p.y;
  rf[i * 4 + 2] = 0.5;
  rf[i * 4 + 3] = 1.0;
  }
  return result_k;
}

// ── Window helpers ────────────────────────────────────────────────────────────

fn getFramebufferSize(window: *const anyopaque) [2]u32 {
  var w: i32 = 0;
  var h: i32 = 0;
  zglfw.getFramebufferSize(@constCast(@ptrCast(@alignCast(window))), &w, &h);
  return .{ @intCast(w), @intCast(h) };
}

fn getWindowSize(window: *const anyopaque) [2]u32 {
  var w: i32 = 0;
  var h: i32 = 0;
  zglfw.getWindowSize(@constCast(@ptrCast(@alignCast(window))), &w, &h);
  return .{ @intCast(w), @intCast(h) };
}

fn getTime() f64 { return zglfw.getTime(); }

extern fn glfwGetCocoaWindow(window: *anyopaque) ?*anyopaque;
fn getCocoaWindow(window: *const anyopaque) callconv(.c) ?*anyopaque {
  return glfwGetCocoaWindow(@constCast(window));
}

fn createPipeline(device: wgpu.Device, bgl: wgpu.BindGroupLayout) !wgpu.RenderPipeline {
  const fill_wgsl = @embedFile("fill.wgsl");
  var buf: [fill_wgsl.len + 1]u8 = undefined;
  @memcpy(buf[0..fill_wgsl.len], fill_wgsl);
  buf[fill_wgsl.len] = 0;
  const shader_module = zgpu.createWgslShaderModule(device, buf[0..fill_wgsl.len :0], "fill");
  defer shader_module.release();

  const pipeline_layout = device.createPipelineLayout(.{
  .bind_group_layout_count = 1,
  .bind_group_layouts = &[_]wgpu.BindGroupLayout{bgl},
  });
  defer pipeline_layout.release();

  const vtx_attrs = [_]wgpu.VertexAttribute{
  .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
  .{ .format = .float32x2, .offset = 8, .shader_location = 1 },
  };
  const vtx_bufs = [_]wgpu.VertexBufferLayout{.{
  .array_stride    = 16,
  .attribute_count = vtx_attrs.len,
  .attributes      = &vtx_attrs,
  }};
  const color_targets = [_]wgpu.ColorTargetState{.{
  .format     = zgpu.GraphicsContext.swapchain_format,
  .write_mask = wgpu.ColorWriteMask.all,
  .blend      = &wgpu.BlendState{
    .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
    .alpha = .{ .operation = .add, .src_factor = .one,       .dst_factor = .one_minus_src_alpha },
  },
  }};
  return device.createRenderPipeline(.{
  .layout   = pipeline_layout,
  .vertex   = .{
    .module = shader_module, .entry_point = "vs_main",
    .buffer_count = vtx_bufs.len, .buffers = &vtx_bufs,
  },
  .primitive = .{ .topology = .triangle_list },
  .fragment  = &wgpu.FragmentState{
    .module = shader_module, .entry_point = "fs_main",
    .target_count = color_targets.len, .targets = &color_targets,
  },
  });
}

// Fullscreen-quad pipeline that samples the offscreen target into the swapchain.
// Only built in snapshot mode (see gpuRun).
fn createBlitPipeline(device: wgpu.Device, bgl: wgpu.BindGroupLayout) !wgpu.RenderPipeline {
  const src = @embedFile("blit.wgsl");
  var buf: [src.len + 1]u8 = undefined;
  @memcpy(buf[0..src.len], src);
  buf[src.len] = 0;
  const sm = zgpu.createWgslShaderModule(device, buf[0..src.len :0], "blit");
  defer sm.release();

  const pl = device.createPipelineLayout(.{
  .bind_group_layout_count = 1,
  .bind_group_layouts = &[_]wgpu.BindGroupLayout{bgl},
  });
  defer pl.release();

  const targets = [_]wgpu.ColorTargetState{.{
  .format = zgpu.GraphicsContext.swapchain_format,
  .write_mask = wgpu.ColorWriteMask.all,
  }};
  return device.createRenderPipeline(.{
  .layout = pl,
  .vertex = .{ .module = sm, .entry_point = "vs_main" },
  .primitive = .{ .topology = .triangle_list },
  .fragment = &wgpu.FragmentState{
    .module = sm, .entry_point = "fs_main",
    .target_count = targets.len, .targets = &targets,
  },
  });
}

// ── gpu_run ───────────────────────────────────────────────────────────────────
//
// loop_fn: K lambda called each frame with a props dict
// config:  optional float list [width; height] (default 800×600)
// Returns 0 on clean exit, -1 on error.

export fn gpuRun(loop_k: ?K, config_k: ?K) callconv(.c) ?K {
  const loop_fn = loop_k orelse return ki(0);

  var win_w: i32 = 800;
  var win_h: i32 = 600;
  if (config_k) |cfg| {
  if (kfp(cfg)) |cf| {
    if (kn(cfg) >= 2) { win_w = @intFromFloat(cf[0]); win_h = @intFromFloat(cf[1]); }
  }
  }
  // `ink -size WxH` overrides the script-supplied window size.
  if (envStr("INK_SIZE")) |s| {
    if (std.mem.indexOfScalar(u8, s, 'x')) |xi| {
      win_w = std.fmt.parseInt(i32, s[0..xi], 10) catch win_w;
      win_h = std.fmt.parseInt(i32, s[xi + 1 ..], 10) catch win_h;
    }
  }

  // `ink -snap [t0,t1,...]` requests PNG screenshots at the given sim-times
  // (seconds); INK_SNAP="0" (bare -snap) shoots once on the first frame. In snap
  // mode we render to an offscreen target so the framebuffer can be read back,
  // then blit it to the swapchain; the normal path renders straight to the
  // swapchain with no offscreen target or blit.
  var snap_times: [32]f32 = undefined;
  var snap_count: usize = 0;
  var snap_next: usize = 0;
  const snap_enabled = envStr("INK_SNAP") != null;
  if (envStr("INK_SNAP")) |spec| {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |tok| {
      const t = std.fmt.parseFloat(f32, std.mem.trim(u8, tok, " ")) catch continue;
      if (snap_count < snap_times.len) { snap_times[snap_count] = t; snap_count += 1; }
    }
    if (snap_count == 0) { snap_times[0] = 0; snap_count = 1; }
  }

  var da = std.heap.DebugAllocator(.{}).init;
  defer _ = da.deinit();
  const alloc = da.allocator();

  zglfw.init() catch return ki(-1);
  defer zglfw.terminate();
  zglfw.windowHint(zglfw.ClientAPI, zglfw.NoAPI);
  zglfw.windowHint(zglfw.CocoaRetinaFramebuffer, 1);
  // `ink -unfocus` sets INK_UNFOCUS=1 so the window opens without stealing
  // keyboard focus — handy for watch loops that recreate the window on save.
  if (getenv("INK_UNFOCUS") != null) {
    zglfw.windowHint(zglfw.Focused, 0);      // don't steal focus on creation
    zglfw.windowHint(zglfw.FocusOnShow, 0);  // don't steal focus when shown
  }
  // `ink -top` keeps the window above all others (always-on-top).
  if (getenv("INK_TOP") != null) zglfw.windowHint(zglfw.Floating, 1);
  // Snapshot mode runs headless: create the window hidden (never shown).
  if (snap_enabled) zglfw.windowHint(zglfw.Visible, 0);
  // `ink -monitor N` places the window on monitor N (0-based). Create it hidden
  // so we can position it before it appears — no flash on the wrong screen.
  const mon = envInt("INK_MONITOR");
  if (mon != null) zglfw.windowHint(zglfw.Visible, 0);

  const window = zglfw.createWindow(win_w, win_h, "ink", null, null) catch return ki(-1);
  defer zglfw.destroyWindow(window);

  if (mon) |mi| {
    var count: c_int = 0;
    if (zglfw.getMonitors(&count)) |ms| {
      const idx: usize = if (mi < 0) 0 else @intCast(mi);
      if (idx < @as(usize, @intCast(count))) {
        var mx: c_int = 0;
        var my: c_int = 0;
        zglfw.getMonitorPos(ms[idx], &mx, &my);
        var px = mx;
        var py = my;
        if (zglfw.getVideoMode(ms[idx])) |vmode| { // center on the monitor
          px = mx + @divTrunc(@as(c_int, @intCast(vmode.width)) - @as(c_int, @intCast(win_w)), 2);
          py = my + @divTrunc(@as(c_int, @intCast(vmode.height)) - @as(c_int, @intCast(win_h)), 2);
        }
        zglfw.setWindowPos(window, px, py);
      }
    }
    if (!snap_enabled) zglfw.showWindow(window); // FocusOnShow=0 (with -unfocus) keeps focus put
  }

  _ = zglfw.setKeyCallback(window, keyCb);
  _ = zglfw.setCharCallback(window, charCb);
  _ = zglfw.setMouseButtonCallback(window, mouseBtnCb);
  _ = zglfw.setScrollCallback(window, scrollCb);

  const gctx = zgpu.GraphicsContext.create(alloc, .{
  .window              = window,
  .fn_getTime          = getTime,
  .fn_getFramebufferSize = getFramebufferSize,
  .fn_getCocoaWindow   = getCocoaWindow,
  }, .{}) catch return ki(-1);
  defer gctx.destroy(alloc);

  gctx.device.setUncapturedErrorCallback(struct {
  fn cb(typ: wgpu.ErrorType, msg: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("[Dawn error] type={} msg={s}\n", .{ typ, msg orelse "(null)" });
  }
  }.cb, null);
  gctx.device.setDeviceLostCallback(struct {
  fn cb(reason: wgpu.DeviceLostReason, msg: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("[Dawn device lost] reason={} msg={s}\n", .{ reason, msg orelse "(null)" });
  }
  }.cb, null);

  const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
  zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, false, 0),
  zgpu.bufferEntry(1, .{ .fragment = true }, .uniform, false, 0),
  .{ .binding = 2, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float } },
  zgpu.samplerEntry(3, .{ .fragment = true }, .filtering),
  .{ .binding = 4, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float } },
  zgpu.samplerEntry(5, .{ .fragment = true }, .filtering),
  };
  const bgl = gctx.device.createBindGroupLayout(.{
  .label = "gpu_ext bgl", .entry_count = bgl_entries.len, .entries = &bgl_entries,
  });
  defer bgl.release();

  const pipeline = createPipeline(gctx.device, bgl) catch return ki(-1);
  defer pipeline.release();

  const renderer = Renderer.init(alloc, gctx.device, gctx.queue, pipeline, bgl, 2_000_000) catch return ki(-1);
  defer renderer.deinit();

  // Depth texture: created/resized lazily each time the framebuffer size changes.
  var depth_tex_opt: ?wgpu.Texture = null;
  var depth_view_opt: ?wgpu.TextureView = null;
  var depth_fb: [2]u32 = .{ 0, 0 };
  defer {
  if (depth_view_opt) |dv| dv.release();
  if (depth_tex_opt) |dt| dt.release();
  }

  // Snapshot mode: offscreen colour target (resized with the framebuffer) plus a
  // blit pipeline/sampler to present it.  All null/unused on the normal path.
  var off_tex_opt: ?wgpu.Texture = null;
  var off_view_opt: ?wgpu.TextureView = null;
  defer {
  if (off_view_opt) |ov| ov.release();
  if (off_tex_opt) |ot| ot.release();
  }
  var blit_bgl_opt: ?wgpu.BindGroupLayout = null;
  var blit_sampler_opt: ?wgpu.Sampler = null;
  var blit_pipeline_opt: ?wgpu.RenderPipeline = null;
  defer {
  if (blit_pipeline_opt) |bp| bp.release();
  if (blit_sampler_opt) |bs| bs.release();
  if (blit_bgl_opt) |bb| bb.release();
  }
  if (snap_enabled) {
  const blit_entries = [_]wgpu.BindGroupLayoutEntry{
    .{ .binding = 0, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float } },
    zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
  };
  const blit_bgl = gctx.device.createBindGroupLayout(.{
    .label = "blit bgl", .entry_count = blit_entries.len, .entries = &blit_entries,
  });
  blit_bgl_opt = blit_bgl;
  blit_sampler_opt = gctx.device.createSampler(.{ .label = "blit sampler" });
  blit_pipeline_opt = createBlitPipeline(gctx.device, blit_bgl) catch return ki(-1);
  }

  const start_time = zglfw.getTime();

  while (!zglfw.windowShouldClose(window)) {
  zglfw.pollEvents();

  const fb = getFramebufferSize(window);
  if (fb[0] == 0 or fb[1] == 0) { zgpu.wgpuDeviceTick(); continue; }

  // Recreate depth texture whenever framebuffer size changes.
  if (fb[0] != depth_fb[0] or fb[1] != depth_fb[1]) {
    if (depth_view_opt) |dv| dv.release();
    if (depth_tex_opt) |dt| dt.release();
    const dt = gctx.device.createTexture(.{
    .label = "depth",
    .usage = .{ .render_attachment = true },
    .size  = .{ .width = fb[0], .height = fb[1], .depth_or_array_layers = 1 },
    .format = .depth24_plus,
    });
    depth_tex_opt = dt;
    depth_view_opt = dt.createView(.{});
    depth_fb = fb;

    if (snap_enabled) {
    if (off_view_opt) |ov| ov.release();
    if (off_tex_opt) |ot| ot.release();
    const ot = gctx.device.createTexture(.{
      .label = "offscreen",
      .usage = .{ .render_attachment = true, .texture_binding = true, .copy_src = true },
      .size  = .{ .width = fb[0], .height = fb[1], .depth_or_array_layers = 1 },
      .format = zgpu.GraphicsContext.swapchain_format,
    });
    off_tex_opt = ot;
    off_view_opt = ot.createView(.{});
    }
  }

  const fw: f32 = @floatFromInt(fb[0]);
  const fh: f32 = @floatFromInt(fb[1]);

  const ws = getWindowSize(window);
  const dpr_x: f64 = if (ws[0] > 0) @as(f64, @floatFromInt(fb[0])) / @as(f64, @floatFromInt(ws[0])) else 1.0;
  const dpr_y: f64 = if (ws[1] > 0) @as(f64, @floatFromInt(fb[1])) / @as(f64, @floatFromInt(ws[1])) else 1.0;
  g_dpr_x = dpr_x; // so callback-time cursor positions match mx/my
  g_dpr_y = dpr_y;

  const swapchain_view = gctx.swapchain.getCurrentTextureView();
  defer swapchain_view.release();
  // Snapshot mode draws into the offscreen target (read back below); otherwise
  // straight into the swapchain.
  const target_view = if (snap_enabled) off_view_opt.? else swapchain_view;
  const encoder = gctx.device.createCommandEncoder(.{ .label = "frame" });
  defer encoder.release();

  const pass = encoder.beginRenderPass(.{
    .color_attachment_count = 1,
    .color_attachments = &[_]wgpu.RenderPassColorAttachment{.{
    .view        = target_view,
    .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    .load_op     = .clear,
    .store_op    = .store,
    }},
  });

  g_renderer = renderer;
  defer g_renderer = null;

  var mx: f64 = 0;
  var my: f64 = 0;
  zglfw.getCursorPos(window, &mx, &my);
  const t: f32 = @floatCast(zglfw.getTime() - start_time);

  // Build props dict and call loop_fn. Continuous state is width/height/mx/my/time;
  // all discrete input (keys, text, mouse buttons, scroll) arrives via `events`.
  const prop_keys = [6][*:0]const u8{ "width", "height", "mx", "my", "time", "events" };
  const v_w = kf(fw); const v_h = kf(fh);
  const v_mx = kf(@floatCast(mx * dpr_x)); const v_my = kf(@floatCast(my * dpr_y));
  const v_t = kf(t);
  const v_events = buildEvents();
  g_nev = 0;
  const prop_vals = [6]?K{ v_w, v_h, v_mx, v_my, v_t, v_events };

  if (k_make_dict(6, &prop_keys, &prop_vals)) |pk| {
    const result = k_call(loop_fn, pk);
    ku(result);
    ku(pk);
  }
  ku(v_w); ku(v_h); ku(v_mx); ku(v_my); ku(v_t);
  ku(v_events);

  renderer.flush(pass, fw, fh, t) catch {};
  pass.release();

  // 3-D mesh pass — runs after the 2-D layer, loads colour, adds depth.
  if (depth_view_opt) |depth_view| {
    renderer.flushMeshes(encoder, target_view, depth_view) catch {};
  }

  // Snapshot mode: blit the offscreen target to the swapchain, and — when a
  // scheduled time has been reached — copy it into a CPU-readable buffer.
  var snap_due = false;
  var snap_stage_opt: ?wgpu.Buffer = null;
  var snap_bpr: u32 = 0;
  if (snap_enabled) {
    const blit_pass = encoder.beginRenderPass(.{
    .color_attachment_count = 1,
    .color_attachments = &[_]wgpu.RenderPassColorAttachment{.{
      .view        = swapchain_view,
      .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
      .load_op     = .clear,
      .store_op    = .store,
    }},
    });
    blit_pass.setPipeline(blit_pipeline_opt.?);
    const be = [_]wgpu.BindGroupEntry{
    .{ .binding = 0, .texture_view = off_view_opt.?, .size = 0 },
    .{ .binding = 1, .sampler = blit_sampler_opt.?, .size = 0 },
    };
    const bg = gctx.device.createBindGroup(.{
    .layout = blit_bgl_opt.?, .entry_count = be.len, .entries = &be,
    });
    defer bg.release();
    blit_pass.setBindGroup(0, bg, null);
    blit_pass.draw(3, 1, 0, 0);
    blit_pass.end();
    blit_pass.release();

    snap_due = snap_next < snap_count and t >= snap_times[snap_next];
    if (snap_due) {
    snap_bpr = (fb[0] * 4 + 255) & ~@as(u32, 255); // 256-byte row alignment
    const stage = gctx.device.createBuffer(.{
      .label = "snap stage",
      .usage = .{ .map_read = true, .copy_dst = true },
      .size = @as(u64, snap_bpr) * fb[1],
      .mapped_at_creation = .false,
    });
    snap_stage_opt = stage;
    encoder.copyTextureToBuffer(
      .{ .texture = off_tex_opt.?, .mip_level = 0, .origin = .{}, .aspect = .all },
      .{ .layout = .{ .offset = 0, .bytes_per_row = snap_bpr, .rows_per_image = fb[1] }, .buffer = stage },
      .{ .width = fb[0], .height = fb[1], .depth_or_array_layers = 1 },
    );
    }
  }

  const cmd = encoder.finish(.{});
  defer cmd.release();
  gctx.queue.submit(&[_]wgpu.CommandBuffer{cmd});
  _ = gctx.present();
  gctx.device.tick();

  // Read back the captured frame and write it as a PNG.
  if (snap_due) if (snap_stage_opt) |stage| {
    const size: usize = @as(usize, snap_bpr) * fb[1];
    var done = false;
    stage.mapAsync(.{ .read = true }, 0, size, computeMapCallback, &done);
    while (!done) gctx.device.tick();
    if (stage.getConstMappedRange(u8, 0, size)) |data| {
    const base = envStr("INK_SNAP_BASE") orelse "ink";
    const ms = epochMillis();
    if (std.fmt.allocPrint(alloc, "{s}-snap-{d}.png", .{ base, ms })) |path| {
      if (png.writePng(alloc, path, fb[0], fb[1], data, snap_bpr))
      std.debug.print("[snap] wrote {s}\n", .{path})
      else |e| std.debug.print("[snap] write failed: {}\n", .{e});
      alloc.free(path);
    } else |_| {}
    }
    stage.unmap();
    stage.release();
    snap_next += 1;
  };

  // Exit once every scheduled snapshot has been taken.
  if (snap_enabled and snap_next >= snap_count) break;
  }

  return ki(0);
}

// WebGPU SPIRV descriptor (not in zgpu bindings — defined manually from Dawn C API).
const ShaderModuleSPIRVDescriptor = extern struct {
  chain: wgpu.ChainedStruct,
  code_size: u32,
  code: [*]const u32,
};

// ── gpuSpirv ──────────────────────────────────────────────────────────────────
//
// words_k: int list — SPIR-V binary (output of compShader in spirv.k)
// _:       unused (ink 2: requires 2-arg functions)
// Returns a negative shader handle (< 0) for use with gpuFillShader.
// Must be called inside the gpuRun frame callback (needs active renderer).

export fn gpuSpirv(words_k: ?K, _: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const ip = kip(words_k) orelse return ki(0);
  const n = kn(words_k);
  if (n < 5) return ki(0);

  const words: [*]const u32 = @ptrCast(@alignCast(ip));

  // Vertex stage: use fill.wgsl vs_main (outputs ftcoord at @location(0)).
  const fill_wgsl = @embedFile("fill.wgsl");
  const vert_z = r.allocator.dupeZ(u8, fill_wgsl) catch return ki(0);
  defer r.allocator.free(vert_z);
  const vert_module = zgpu.createWgslShaderModule(r.device, vert_z, "vert");
  defer vert_module.release();

  // Fragment stage: caller-supplied SPIR-V binary.
  const spirv_desc = ShaderModuleSPIRVDescriptor{
    .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
    .code_size = @intCast(n),
    .code = words,
  };
  const frag_module = r.device.createShaderModule(.{
    .next_in_chain = @ptrCast(&spirv_desc),
  });
  defer frag_module.release();

  const color_targets = [_]wgpu.ColorTargetState{.{
    .format     = zgpu.GraphicsContext.swapchain_format,
    .write_mask = wgpu.ColorWriteMask.all,
    .blend      = &wgpu.BlendState{
      .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
      .alpha = .{ .operation = .add, .src_factor = .one,       .dst_factor = .one_minus_src_alpha },
    },
  }};
  const vtx_attrs = [_]wgpu.VertexAttribute{
    .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
    .{ .format = .float32x2, .offset = 8, .shader_location = 1 },
  };
  const vtx_bufs = [_]wgpu.VertexBufferLayout{.{
    .array_stride = 16, .attribute_count = vtx_attrs.len, .attributes = &vtx_attrs,
  }};
  // Reuse the renderer's bind_group_layout: vs_main reads group 0 binding 0 (view);
  // the SPIR-V fragment shader declares no resources but extra bindings are allowed.
  const layout = r.device.createPipelineLayout(.{
    .bind_group_layout_count = 1,
    .bind_group_layouts = &[_]wgpu.BindGroupLayout{r.bind_group_layout},
  });
  defer layout.release();
  const pipeline = r.device.createRenderPipeline(.{
    .layout  = layout,
    .vertex  = .{ .module = vert_module, .entry_point = "vs_main",
            .buffer_count = vtx_bufs.len, .buffers = &vtx_bufs },
    .primitive = .{ .topology = .triangle_list },
    .fragment = &wgpu.FragmentState{
      .module = frag_module, .entry_point = "main",
      .target_count = color_targets.len, .targets = &color_targets,
    },
  });
  // Negative handle signals "spirv pipeline, no bind group" to flush()
  r.spirv_pipelines.append(r.allocator, pipeline) catch return ki(0);
  return ki(-@as(i32, @intCast(r.spirv_pipelines.items.len)));
}

// ── gpuFillShader ─────────────────────────────────────────────────────────────
//
// verts_k: flat f32 array [x,y,u,v,...] — same layout as gpuFill
// shader_k: int scalar — handle returned by gpuSpirv

export fn gpuFillShader(verts_k: ?K, shader_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vf = kfp(verts_k) orelse return ki(0);
  const vn = kn(verts_k);
  const shader: i32 = ki_val(shader_k);
  if (shader == 0) return ki(0);

  const n_verts: usize = @intCast(@divTrunc(vn, 4));
  const verts_slice = @as([*]const render.Vertex, @ptrCast(@alignCast(vf)))[0..n_verts];
  r.drawShader(verts_slice, shader) catch {};
  return ki(0);
}

// ── gpuCompute ────────────────────────────────────────────────────────────────
//
// words_k:  int list — SPIR-V compute binary (output of compCompute in spirv.k)
// input_k:  float list — input data for the shader (binding 0)
// Returns a new float list with the per-element results (binding 1).
// Must be called inside a gpuRun frame callback (needs active renderer for device/queue).
//
// The compute shader is expected to:
//   - read from binding 0 (StorageBuffer, f32 array)
//   - write to binding 1 (StorageBuffer, f32 array)
//   - use workgroup size 64 (as generated by compCompute)

fn computeMapCallback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.c) void {
  const done: *bool = @ptrCast(@alignCast(userdata.?));
  done.* = (status == .success);
}

export fn gpuCompute(words_k: ?K, input_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const ip = kip(words_k) orelse return ki(0);
  const n_words = kn(words_k);
  if (n_words < 5) return ki(0);
  const fp = kfp(input_k) orelse return ki(0);
  const n_input = kn(input_k);
  if (n_input <= 0) return ki(0);
  const n: usize = @intCast(n_input);

  const words: [*]const u32 = @ptrCast(@alignCast(ip));
  const byte_size: u64 = @intCast(n * @sizeOf(f32));

  // SPIR-V compute shader module
  const spirv_desc = ShaderModuleSPIRVDescriptor{
    .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
    .code_size = @intCast(n_words),
    .code = words,
  };
  const cs_module = r.device.createShaderModule(.{
    .next_in_chain = @ptrCast(&spirv_desc),
  });
  defer cs_module.release();

  // Bind group layout: binding 0 = input (read-write storage), binding 1 = output
  const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
    .{ .binding = 0, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
    .{ .binding = 1, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
  };
  const bgl = r.device.createBindGroupLayout(.{
    .entry_count = bgl_entries.len,
    .entries = &bgl_entries,
  });
  defer bgl.release();

  const pl_layout = r.device.createPipelineLayout(.{
    .bind_group_layout_count = 1,
    .bind_group_layouts = &[_]wgpu.BindGroupLayout{bgl},
  });
  defer pl_layout.release();

  const pipeline = r.device.createComputePipeline(.{
    .layout = pl_layout,
    .compute = .{ .module = cs_module, .entry_point = "main" },
  });
  defer pipeline.release();

  // Input buffer: upload caller data
  const input_buf = r.device.createBuffer(.{
    .label = "compute_in",
    .usage = .{ .storage = true, .copy_dst = true },
    .size = byte_size,
    .mapped_at_creation = .false,
  });
  defer input_buf.release();

  // Output buffer: shader writes here, then we copy to staging
  const output_buf = r.device.createBuffer(.{
    .label = "compute_out",
    .usage = .{ .storage = true, .copy_src = true },
    .size = byte_size,
    .mapped_at_creation = .false,
  });
  defer output_buf.release();

  // Staging buffer: CPU-readable copy of the output
  const staging_buf = r.device.createBuffer(.{
    .label = "compute_stage",
    .usage = .{ .map_read = true, .copy_dst = true },
    .size = byte_size,
    .mapped_at_creation = .false,
  });
  defer staging_buf.release();

  r.queue.writeBuffer(input_buf, 0, f32, fp[0..n]);

  const bg_entries = [_]wgpu.BindGroupEntry{
    .{ .binding = 0, .buffer = input_buf,  .size = byte_size },
    .{ .binding = 1, .buffer = output_buf, .size = byte_size },
  };
  const bg = r.device.createBindGroup(.{
    .layout = bgl,
    .entry_count = bg_entries.len,
    .entries = &bg_entries,
  });
  defer bg.release();

  const encoder = r.device.createCommandEncoder(.{ .label = "compute" });
  defer encoder.release();

  {
    const pass = encoder.beginComputePass(null);
    defer pass.release();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bg, null);
    const workgroups: u32 = @intCast((n + 63) / 64);
    pass.dispatchWorkgroups(workgroups, 1, 1);
    pass.end();
  }
  encoder.copyBufferToBuffer(output_buf, 0, staging_buf, 0, byte_size);

  const cmd = encoder.finish(.{});
  defer cmd.release();
  r.queue.submit(&[_]wgpu.CommandBuffer{cmd});

  // Synchronous readback: spin until mapped
  var done: bool = false;
  staging_buf.mapAsync(.{ .read = true }, 0, byte_size, computeMapCallback, &done);
  while (!done) r.device.tick();

  const result_k = KF(@intCast(n)) orelse { staging_buf.unmap(); return ki(0); };
  const rf = kfp(result_k) orelse { ku(result_k); staging_buf.unmap(); return ki(0); };
  if (staging_buf.getConstMappedRange(f32, 0, n)) |data| @memcpy(rf[0..n], data);
  staging_buf.unmap();

  return result_k;
}

// ── gpuCompute2 ─────────────────────────────────────────────────────────────────
//
// Two-input element-wise compute (output of compCompute2 in spirv.k):
//   binding 0 = input1 (StorageBuffer), binding 2 = input2, binding 1 = output.
// in1_k, in2_k: equal-length float lists. Returns a float list of per-element results.
export fn gpuCompute2(words_k: ?K, in1_k: ?K, in2_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const ip = kip(words_k) orelse return ki(0);
  const n_words = kn(words_k);
  if (n_words < 5) return ki(0);
  const fp1 = kfp(in1_k) orelse return ki(0);
  const fp2 = kfp(in2_k) orelse return ki(0);
  const n_input = kn(in1_k);
  if (n_input <= 0) return ki(0);
  if (kn(in2_k) != n_input) return ki(0); // both inputs must be the same length
  const n: usize = @intCast(n_input);
  const words: [*]const u32 = @ptrCast(@alignCast(ip));
  const byte_size: u64 = @intCast(n * @sizeOf(f32));

  const spirv_desc = ShaderModuleSPIRVDescriptor{
    .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
    .code_size = @intCast(n_words),
    .code = words,
  };
  const cs_module = r.device.createShaderModule(.{ .next_in_chain = @ptrCast(&spirv_desc) });
  defer cs_module.release();

  // binding 0 = input1, binding 1 = output, binding 2 = input2
  const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
    .{ .binding = 0, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
    .{ .binding = 1, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
    .{ .binding = 2, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
  };
  const bgl = r.device.createBindGroupLayout(.{ .entry_count = bgl_entries.len, .entries = &bgl_entries });
  defer bgl.release();
  const pl_layout = r.device.createPipelineLayout(.{ .bind_group_layout_count = 1, .bind_group_layouts = &[_]wgpu.BindGroupLayout{bgl} });
  defer pl_layout.release();
  const pipeline = r.device.createComputePipeline(.{ .layout = pl_layout, .compute = .{ .module = cs_module, .entry_point = "main" } });
  defer pipeline.release();

  const in1_buf = r.device.createBuffer(.{ .label = "compute2_in1", .usage = .{ .storage = true, .copy_dst = true }, .size = byte_size, .mapped_at_creation = .false });
  defer in1_buf.release();
  const in2_buf = r.device.createBuffer(.{ .label = "compute2_in2", .usage = .{ .storage = true, .copy_dst = true }, .size = byte_size, .mapped_at_creation = .false });
  defer in2_buf.release();
  const output_buf = r.device.createBuffer(.{ .label = "compute2_out", .usage = .{ .storage = true, .copy_src = true }, .size = byte_size, .mapped_at_creation = .false });
  defer output_buf.release();
  const staging_buf = r.device.createBuffer(.{ .label = "compute2_stage", .usage = .{ .map_read = true, .copy_dst = true }, .size = byte_size, .mapped_at_creation = .false });
  defer staging_buf.release();

  r.queue.writeBuffer(in1_buf, 0, f32, fp1[0..n]);
  r.queue.writeBuffer(in2_buf, 0, f32, fp2[0..n]);

  const bg_entries = [_]wgpu.BindGroupEntry{
    .{ .binding = 0, .buffer = in1_buf, .size = byte_size },
    .{ .binding = 1, .buffer = output_buf, .size = byte_size },
    .{ .binding = 2, .buffer = in2_buf, .size = byte_size },
  };
  const bg = r.device.createBindGroup(.{ .layout = bgl, .entry_count = bg_entries.len, .entries = &bg_entries });
  defer bg.release();

  const encoder = r.device.createCommandEncoder(.{ .label = "compute2" });
  defer encoder.release();
  {
    const pass = encoder.beginComputePass(null);
    defer pass.release();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bg, null);
    const workgroups: u32 = @intCast((n + 63) / 64);
    pass.dispatchWorkgroups(workgroups, 1, 1);
    pass.end();
  }
  encoder.copyBufferToBuffer(output_buf, 0, staging_buf, 0, byte_size);
  const cmd = encoder.finish(.{});
  defer cmd.release();
  r.queue.submit(&[_]wgpu.CommandBuffer{cmd});

  var done: bool = false;
  staging_buf.mapAsync(.{ .read = true }, 0, byte_size, computeMapCallback, &done);
  while (!done) r.device.tick();

  const result_k = KF(@intCast(n)) orelse { staging_buf.unmap(); return ki(0); };
  const rf = kfp(result_k) orelse { ku(result_k); staging_buf.unmap(); return ki(0); };
  if (staging_buf.getConstMappedRange(f32, 0, n)) |data| @memcpy(rf[0..n], data);
  staging_buf.unmap();
  return result_k;
}

// Derive a mesh vertex-buffer layout from a SPIR-V vertex shader by scanning its
// Input variables. Relies on the fixed input-pointer type IDs assigned in
// lib/gpu/spirv.k (PinF32=10, PinV2=14, PinV4=12, PinV3=18) and on input
// Locations being contiguous from 0. Fills `out` and returns count + stride.
const MeshLayout = struct { count: usize, stride_floats: usize };
fn meshVtxLayout(words: []const u32, out: *[16]wgpu.VertexAttribute) MeshLayout {
  var dec_id: [16]u32 = undefined;
  var dec_loc: [16]u32 = undefined;
  var ndec: usize = 0;
  var in_id: [16]u32 = undefined;
  var in_comp: [16]u32 = undefined;
  var nin: usize = 0;

  var i: usize = 5; // skip 5-word header
  while (i < words.len) {
    const w0 = words[i];
    const wc: usize = w0 >> 16;
    const op: u32 = w0 & 0xffff;
    if (wc == 0) break;
    if (op == 71 and i + 3 < words.len and words[i + 2] == 30) { // OpDecorate Location
      if (ndec < 16) { dec_id[ndec] = words[i + 1]; dec_loc[ndec] = words[i + 3]; ndec += 1; }
    } else if (op == 59 and i + 3 < words.len and words[i + 3] == 1) { // OpVariable, storage Input
      const comp: u32 = switch (words[i + 1]) { 10 => 1, 14 => 2, 18 => 3, 12 => 4, else => 0 };
      if (comp > 0 and nin < 16) { in_id[nin] = words[i + 2]; in_comp[nin] = comp; nin += 1; }
    }
    i += wc;
  }

  // Order inputs by their Location, then assign packed offsets.
  var offset: u32 = 0;
  var count: usize = 0;
  var loc: u32 = 0;
  while (loc < nin) : (loc += 1) {
    // find the input variable decorated with this location
    var idx: usize = nin;
    var k: usize = 0;
    while (k < nin) : (k += 1) {
      var d: usize = 0;
      while (d < ndec) : (d += 1) {
        if (dec_id[d] == in_id[k] and dec_loc[d] == loc) { idx = k; break; }
      }
      if (idx != nin) break;
    }
    if (idx == nin) break;
    const comp = in_comp[idx];
    out[count] = .{
      .format = switch (comp) { 1 => .float32, 2 => .float32x2, 3 => .float32x3, else => .float32x4 },
      .offset = offset,
      .shader_location = loc,
    };
    offset += comp * @sizeOf(f32);
    count += 1;
  }
  return .{ .count = count, .stride_floats = offset / @sizeOf(f32) };
}

// ── gpuMesh ───────────────────────────────────────────────────────────────────
//
// vtx_k: int list — SPIR-V vertex shader binary (output of VertexShader in spirv.k)
// frg_k: int list — SPIR-V fragment shader binary (output of FragmentShader in spirv.k)
// Returns a non-negative handle for use with gpuDrawMesh.
// Must be called inside the gpuRun frame callback.

export fn gpuMesh(vtx_k: ?K, frg_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vp = kip(vtx_k) orelse return ki(0);
  const vn = kn(vtx_k);
  if (vn < 5) return ki(0);
  const fp = kip(frg_k) orelse return ki(0);
  const fn_ = kn(frg_k);
  if (fn_ < 5) return ki(0);

  const vtx_words: [*]const u32 = @ptrCast(@alignCast(vp));
  const frg_words: [*]const u32 = @ptrCast(@alignCast(fp));

  const spirv_v = ShaderModuleSPIRVDescriptor{
    .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
    .code_size = @intCast(vn), .code = vtx_words,
  };
  const vtx_mod = r.device.createShaderModule(.{ .next_in_chain = @ptrCast(&spirv_v) });
  defer vtx_mod.release();

  const spirv_f = ShaderModuleSPIRVDescriptor{
    .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
    .code_size = @intCast(fn_), .code = frg_words,
  };
  const frg_mod = r.device.createShaderModule(.{ .next_in_chain = @ptrCast(&spirv_f) });
  defer frg_mod.release();

  // Derive the vertex attribute layout from the shader's declared inputs, so a
  // mesh can use any vertex format (stride-6 [x y z nx ny nz], the PBR
  // stride-11, …) without a fixed vertex struct.
  var attr_buf: [16]wgpu.VertexAttribute = undefined;
  const layout_info = meshVtxLayout(vtx_words[0..@intCast(vn)], &attr_buf);
  if (layout_info.count == 0) return ki(0);
  const vtx_bufs = [_]wgpu.VertexBufferLayout{.{
    .array_stride = layout_info.stride_floats * @sizeOf(f32),
    .attribute_count = layout_info.count, .attributes = &attr_buf,
  }};
  const color_targets = [_]wgpu.ColorTargetState{.{
    .format     = zgpu.GraphicsContext.swapchain_format,
    .write_mask = wgpu.ColorWriteMask.all,
    .blend = &wgpu.BlendState{
      .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
      .alpha = .{ .operation = .add, .src_factor = .one,       .dst_factor = .one_minus_src_alpha },
    },
  }};
  const depth_state = wgpu.DepthStencilState{
    .format              = .depth24_plus,
    .depth_write_enabled = true,
    .depth_compare       = .less,
  };
  // A shader opts into the per-draw uniform block (OpVariable in Uniform storage,
  // class 2) or instancing (OpVariable in StorageBuffer storage, class 12), and
  // gets the matching bind-group layout at @group(0).  Shaders with neither keep
  // the empty layout (and the no-bind-group draw path) so existing meshes are
  // unaffected.  Instancing and the uniform block are mutually exclusive here.
  var has_uniform = false;
  var has_instance = false;
  {
    const ws = vtx_words[0..@intCast(vn)];
    var j: usize = 5;
    while (j < ws.len) {
      const w0 = ws[j];
      const wc: usize = w0 >> 16;
      if (wc == 0) break;
      if ((w0 & 0xffff) == 59 and j + 3 < ws.len) {
        if (ws[j + 3] == 2) has_uniform = true;
        if (ws[j + 3] == 12) has_instance = true;
      }
      j += wc;
    }
  }
  // A fragment shader samples textures when it declares OpVariables in the
  // UniformConstant storage class (0) — the sampled images + one shared sampler
  // (see FragmentShaderTexN in spirv.k), so n_tex = (#class-0 vars) - 1.  Such a
  // mesh gets an n-texture bind group at @group(1); it also implies the uniform
  // group at @group(0) (except when instanced, which owns group 0).
  var uc_vars: usize = 0;
  {
    const ws = frg_words[0..@intCast(fn_)];
    var j: usize = 5;
    while (j < ws.len) {
      const w0 = ws[j];
      const wc: usize = w0 >> 16;
      if (wc == 0) break;
      if ((w0 & 0xffff) == 59 and j + 3 < ws.len and ws[j + 3] == 0) uc_vars += 1;
      j += wc;
    }
  }
  const n_tex: usize = if (uc_vars > 0) uc_vars - 1 else 0;
  const has_texture = n_tex > 0;
  if (has_texture and !has_instance) has_uniform = true;

  // Build this pipeline's @group(1) layout: n_tex texture entries (bindings
  // 0..n-1) + one shared sampler (binding n_tex).  Kept (not released with the
  // pipeline layout) so per-frame bind groups can be created against it.
  var tex_bgl: ?wgpu.BindGroupLayout = null;
  if (has_texture) {
    var tex_entries: [render.MAX_TEX + 1]wgpu.BindGroupLayoutEntry = undefined;
    var k: usize = 0;
    while (k < n_tex) : (k += 1)
      tex_entries[k] = .{ .binding = @intCast(k), .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float } };
    tex_entries[n_tex] = zgpu.samplerEntry(@intCast(n_tex), .{ .fragment = true }, .filtering);
    tex_bgl = r.device.createBindGroupLayout(.{
      .label = "mesh texture bgl",
      .entry_count = @intCast(n_tex + 1),
      .entries = &tex_entries,
    });
  }

  const layout = if (has_instance and has_texture)
    r.device.createPipelineLayout(.{
      .bind_group_layout_count = 2,
      .bind_group_layouts = &[_]wgpu.BindGroupLayout{ r.mesh_inst_bgl, tex_bgl.? },
    })
  else if (has_instance)
    r.device.createPipelineLayout(.{
      .bind_group_layout_count = 1,
      .bind_group_layouts = &[_]wgpu.BindGroupLayout{r.mesh_inst_bgl},
    })
  else if (has_texture)
    r.device.createPipelineLayout(.{
      .bind_group_layout_count = 2,
      .bind_group_layouts = &[_]wgpu.BindGroupLayout{ r.mesh_bgl, tex_bgl.? },
    })
  else if (has_uniform)
    r.device.createPipelineLayout(.{
      .bind_group_layout_count = 1,
      .bind_group_layouts = &[_]wgpu.BindGroupLayout{r.mesh_bgl},
    })
  else
    r.device.createPipelineLayout(.{
      .bind_group_layout_count = 0,
      .bind_group_layouts = &[_]wgpu.BindGroupLayout{},
    });
  defer layout.release();

  const pipeline = r.device.createRenderPipeline(.{
    .layout  = layout,
    .vertex  = .{ .module = vtx_mod, .entry_point = "main",
            .buffer_count = vtx_bufs.len, .buffers = &vtx_bufs },
    .primitive    = .{ .topology = .triangle_list, .cull_mode = .none },
    .depth_stencil = &depth_state,
    .fragment = &wgpu.FragmentState{
      .module = frg_mod, .entry_point = "main",
      .target_count = color_targets.len, .targets = &color_targets,
    },
  });
  if (@intFromPtr(pipeline) == 0) return ki(0);
  r.mesh_pipelines.append(r.allocator, pipeline) catch return ki(0);
  r.mesh_strides.append(r.allocator, layout_info.stride_floats) catch return ki(0);
  r.mesh_has_uniform.append(r.allocator, has_uniform) catch return ki(0);
  r.mesh_is_instanced.append(r.allocator, has_instance) catch return ki(0);
  r.mesh_has_texture.append(r.allocator, has_texture) catch return ki(0);
  r.mesh_tex_n.append(r.allocator, n_tex) catch return ki(0);
  r.mesh_tex_bgls.append(r.allocator, tex_bgl) catch return ki(0);
  return ki(@intCast(r.mesh_pipelines.items.len));
}

// ── gpuUploadMesh ───────────────────────────────────────────────────────────────
//
// verts_k:  flat f32 vertex data (layout per the pipeline's vertex shader).
// handle_k: a mesh pipeline handle from gpuMesh.
// Uploads the geometry to a PERSISTENT vertex buffer (retained — once, not per
// frame) and returns a geometry handle (>0) for gpuDrawInstanced.
export fn gpuUploadMesh(verts_k: ?K, handle_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vf = kfp(verts_k) orelse return ki(0);
  const vn = kn(verts_k);
  const handle = ki_val(handle_k);
  if (handle <= 0 or handle > r.mesh_strides.items.len) return ki(0);
  const stride = r.mesh_strides.items[@intCast(handle - 1)];
  if (stride == 0 or vn < @as(i32, @intCast(stride))) return ki(0);
  const n_floats: usize = @intCast(@divTrunc(vn, @as(i32, @intCast(stride))) * @as(i32, @intCast(stride)));
  const gid = r.uploadGeom(vf[0..n_floats], stride, @intCast(handle - 1)) catch return ki(0);
  return ki(@intCast(gid + 1));
}

// Convert raw 1-based texture handles into a 0-based tex-index slice (into buf);
// handles ≤0 → -1 (invalid → unbound). Used by the textured draw fns.
fn texIdxFrom(handles: []const i32, buf: *[render.MAX_TEX]i32) []const i32 {
  const n = @min(handles.len, render.MAX_TEX);
  var k: usize = 0;
  while (k < n) : (k += 1) buf[k] = if (handles[k] > 0) handles[k] - 1 else -1;
  return buf[0..n];
}

// ── gpuDrawInstanced ────────────────────────────────────────────────────────────
//
// geom_k:  geometry handle from gpuUploadMesh.
// count_k: instance count (int).
// data_k:  flat f32 instance data — count × K vec4s, read in-shader via
//   gl_InstanceIndex (see InstancedVertexShader).  Draws the geometry once with
//   `count` instances.
export fn gpuDrawInstanced(geom_k: ?K, count_k: ?K, data_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const geom = ki_val(geom_k);
  if (geom <= 0 or geom > r.geom_buffers.items.len) return ki(0);
  const count = ki_val(count_k);
  if (count <= 0) return ki(0);
  const df = kfp(data_k) orelse return ki(0);
  const dn = kn(data_k);
  if (dn <= 0) return ki(0);
  r.queueInstanced(@intCast(geom - 1), @intCast(count), df[0..@intCast(dn)], &.{}) catch {};
  return ki(0);
}

// ── gpuDrawInstancedT ───────────────────────────────────────────────────────────
//
// Like gpuDrawInstanced, plus one shared texture (@group(1)) for every instance.
// ct_k packs (count; texHandle) as a 2-int vector (the FFI tops out at arity 3).
// The pipeline must be an InstancedVertexShader + FragmentShaderTex mesh; all
// instances sample the same texture (e.g. a shared atlas). See lib/instancing.k.

export fn gpuDrawInstancedT(geom_k: ?K, ct_k: ?K, data_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const geom = ki_val(geom_k);
  if (geom <= 0 or geom > r.geom_buffers.items.len) return ki(0);
  const cp = kip(ct_k) orelse return ki(0);
  const cn = kn(ct_k);
  if (cn < 1) return ki(0);
  const count = cp[0]; // ct_k = (count; texHandle0; texHandle1; …)
  if (count <= 0) return ki(0);
  const df = kfp(data_k) orelse return ki(0);
  const dn = kn(data_k);
  if (dn <= 0) return ki(0);
  var tbuf: [render.MAX_TEX]i32 = undefined;
  const tex = texIdxFrom(cp[1..@intCast(cn)], &tbuf);
  r.queueInstanced(@intCast(geom - 1), @intCast(count), df[0..@intCast(dn)], tex) catch {};
  return ki(0);
}

// ── gpuDrawGeomT ────────────────────────────────────────────────────────────────
//
// Draw a RETAINED geometry (uploaded once via gpuUploadMesh) with a per-draw
// uniform block (@group0) and an optional texture (@group1) — the non-instanced,
// upload-once counterpart of gpuDrawMeshT.  The pipeline must be a normal
// VertexShaderU + FragmentShaderTex mesh (see lib/gpu.k DrawGeomT).
//   geom_k: geometry handle from gpuUploadMesh
//   uni_k:  flat f32 uniform vector (≤32 floats)
//   tex_k:  int vector of texture handles from gpuTexture (image k = binding k)

export fn gpuDrawGeomT(geom_k: ?K, uni_k: ?K, tex_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const geom = ki_val(geom_k);
  if (geom <= 0 or geom > r.geom_buffers.items.len) return ki(0);

  var uni = [_]f32{0} ** render.MESH_UNI_FLOATS;
  if (kfp(uni_k)) |up| {
    const un = kn(uni_k);
    const m: usize = @min(@as(usize, @intCast(@max(un, 0))), render.MESH_UNI_FLOATS);
    var j: usize = 0;
    while (j < m) : (j += 1) uni[j] = up[j];
  }

  var tbuf: [render.MAX_TEX]i32 = undefined;
  var tex: []const i32 = &.{};
  if (kip(tex_k)) |hp| tex = texIdxFrom(hp[0..@intCast(@max(kn(tex_k), 0))], &tbuf);
  r.queueGeom(@intCast(geom - 1), uni, tex) catch {};
  return ki(0);
}

// ── gpuDrawMesh ───────────────────────────────────────────────────────────────
//
// verts_k: flat f32 array matching the pipeline's vertex layout (the per-vertex
//   stride is whatever the mesh's vertex shader declares; see gpuMesh).
// handle_k: int scalar — handle returned by gpuMesh

export fn gpuDrawMesh(verts_k: ?K, handle_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vf = kfp(verts_k) orelse return ki(0);
  const vn = kn(verts_k);
  const handle = ki_val(handle_k);
  if (handle <= 0 or handle > r.mesh_strides.items.len) return ki(0);
  const stride = r.mesh_strides.items[@intCast(handle - 1)];
  if (stride == 0 or vn < @as(i32, @intCast(stride))) return ki(0);

  const n_floats: usize = @intCast(@divTrunc(vn, @as(i32, @intCast(stride))) * @as(i32, @intCast(stride)));
  const floats = vf[0..n_floats];
  r.drawMesh(floats, stride, @intCast(handle - 1), [_]f32{0} ** render.MESH_UNI_FLOATS, &.{}) catch {};
  return ki(0);
}

// ── gpuDrawMeshU ────────────────────────────────────────────────────────────────
//
// Like gpuDrawMesh, plus a per-draw uniform block.  uni_k is a flat f32 vector
// (up to 32 floats = 8 vec4s) copied into @group(0) @binding(0); a vertex/fragment
// shader built with VertexShaderU reads slot i as its i-th declared vec4 uniform.
export fn gpuDrawMeshU(verts_k: ?K, handle_k: ?K, uni_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vf = kfp(verts_k) orelse return ki(0);
  const vn = kn(verts_k);
  const handle = ki_val(handle_k);
  if (handle <= 0 or handle > r.mesh_strides.items.len) return ki(0);
  const stride = r.mesh_strides.items[@intCast(handle - 1)];
  if (stride == 0 or vn < @as(i32, @intCast(stride))) return ki(0);

  var uni = [_]f32{0} ** render.MESH_UNI_FLOATS;
  if (kfp(uni_k)) |up| {
    const un = kn(uni_k);
    const m: usize = @min(@as(usize, @intCast(@max(un, 0))), render.MESH_UNI_FLOATS);
    var j: usize = 0;
    while (j < m) : (j += 1) uni[j] = up[j];
  }

  const n_floats: usize = @intCast(@divTrunc(vn, @as(i32, @intCast(stride))) * @as(i32, @intCast(stride)));
  const floats = vf[0..n_floats];
  r.drawMesh(floats, stride, @intCast(handle - 1), uni, &.{}) catch {};
  return ki(0);
}

// ── gpuDrawMeshT ────────────────────────────────────────────────────────────────
//
// Like gpuDrawMeshU, plus textures (from gpuTexture) bound at @group(1); image k
// is at binding k (the fragment's sample[k;uv]).  ht_k packs the mesh handle then
// the texture handles: (meshHandle; texHandle0; texHandle1; …) — the FFI bridge
// tops out at arity 3, so they ride together (see lib/gpu.k DrawMeshT).
export fn gpuDrawMeshT(verts_k: ?K, ht_k: ?K, uni_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vf = kfp(verts_k) orelse return ki(0);
  const vn = kn(verts_k);
  const hp = kip(ht_k) orelse return ki(0);
  const hn = kn(ht_k);
  if (hn < 1) return ki(0);
  const handle = hp[0];
  if (handle <= 0 or handle > r.mesh_strides.items.len) return ki(0);
  const stride = r.mesh_strides.items[@intCast(handle - 1)];
  if (stride == 0 or vn < @as(i32, @intCast(stride))) return ki(0);

  var uni = [_]f32{0} ** render.MESH_UNI_FLOATS;
  if (kfp(uni_k)) |up| {
    const un = kn(uni_k);
    const m: usize = @min(@as(usize, @intCast(@max(un, 0))), render.MESH_UNI_FLOATS);
    var j: usize = 0;
    while (j < m) : (j += 1) uni[j] = up[j];
  }

  var tbuf: [render.MAX_TEX]i32 = undefined;
  const tex = texIdxFrom(hp[1..@intCast(hn)], &tbuf); // texture handles after the mesh handle

  const n_floats: usize = @intCast(@divTrunc(vn, @as(i32, @intCast(stride))) * @as(i32, @intCast(stride)));
  const floats = vf[0..n_floats];
  r.drawMesh(floats, stride, @intCast(handle - 1), uni, tex) catch {};
  return ki(0);
}

// ── gpuTexture ──────────────────────────────────────────────────────────────────
//
// Upload an image to a GPU texture for sampling in a mesh fragment shader.
// whc_k: 3-int vector (width; height; comp).  data_k: int vector of
// w*h*comp interleaved samples 0..255 (top-left first) — i.e. an image dict's
// `width`height`comp`data.  Returns a 1-based texture handle for gpuDrawMeshT.
// Source channels are expanded to RGBA (gray → replicated, no-alpha → opaque).
export fn gpuTexture(whc_k: ?K, data_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const wp = kip(whc_k) orelse return ki(0);
  if (kn(whc_k) < 3) return ki(0);
  const w = wp[0];
  const h = wp[1];
  const comp = wp[2];
  if (w <= 0 or h <= 0 or comp <= 0) return ki(0);
  const dp = kip(data_k) orelse return ki(0);
  const dn = kn(data_k);
  const wu: usize = @intCast(w);
  const hu: usize = @intCast(h);
  const cu: usize = @intCast(comp);
  const npix = wu * hu;
  if (dn < @as(i32, @intCast(npix * cu))) return ki(0);

  const rgba = r.allocator.alloc(u8, npix * 4) catch return ki(0);
  defer r.allocator.free(rgba);
  const clamp = struct {
    fn f(v: i32) u8 { return @intCast(@min(@as(i32, 255), @max(@as(i32, 0), v))); }
  }.f;
  var p: usize = 0;
  while (p < npix) : (p += 1) {
    const s = p * cu;
    const d = p * 4;
    if (cu >= 3) {
      rgba[d + 0] = clamp(dp[s + 0]);
      rgba[d + 1] = clamp(dp[s + 1]);
      rgba[d + 2] = clamp(dp[s + 2]);
      rgba[d + 3] = if (cu >= 4) clamp(dp[s + 3]) else 255;
    } else {
      const g = clamp(dp[s + 0]); // grayscale (+ optional alpha)
      rgba[d + 0] = g; rgba[d + 1] = g; rgba[d + 2] = g;
      rgba[d + 3] = if (cu == 2) clamp(dp[s + 1]) else 255;
    }
  }
  const idx = r.uploadTexture(@intCast(w), @intCast(h), rgba) catch return ki(0);
  return ki(@intCast(idx + 1));
}

// ── gpuWgsl ───────────────────────────────────────────────────────────────────
//
// source_k: K char array (ink string) containing a complete WGSL module.
//   Must define vs_main and fs_main using the same bind group layout as fill.wgsl.
//   Binding 0 (@group(0) @binding(0)) is ViewUniforms {viewSize, time, _pad}.
// Returns a positive shader handle for use with gpuFillShader.
// Must be called inside the gpuRun frame callback.

export fn gpuWgsl(source_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const cp = kcp(source_k) orelse return ki(0);
  const n = kn(source_k);
  if (n <= 0) return ki(0);
  const source = cp[0..@intCast(n)];
  const handle = r.createShader(source) catch return ki(0);
  return ki(handle);
}

fn inkInit(reg: *anyopaque) void {
  const r: *const @import("kabi").KRegistry(K) = @ptrCast(@alignCast(reg));
  g_api = .{
    .k_call      = r.k_call,
    .k_make_dict = r.k_make_dict,
    .k_make_table = r.k_make_table,
    .kf          = r.kf,
    .ki          = r.ki,
    .kn          = r.kn,
    .kfp         = r.kfp,
    .kip         = r.kip,
    .kcp         = r.kcp,
    .ki_val      = r.ki_val,
    .KI          = r.KI,
    .KF          = r.KF,
    .KS          = r.KS,
    .ksp         = r.ksp,
    .kintern     = r.kintern,
    .ku          = r.ku,
  };
  // Register callable functions by name (works dlopen'd or statically linked).
  r.k_register("gpuRun", @ptrCast(&gpuRun), 2);
  r.k_register("gpuFill", @ptrCast(&gpuFill), 2);
  r.k_register("gpuTess", @ptrCast(&gpuTess), 1);
  r.k_register("gpuSpirv", @ptrCast(&gpuSpirv), 2);
  r.k_register("gpuFillShader", @ptrCast(&gpuFillShader), 2);
  r.k_register("gpuCompute", @ptrCast(&gpuCompute), 2);
  r.k_register("gpuCompute2", @ptrCast(&gpuCompute2), 3);
  r.k_register("gpuMesh", @ptrCast(&gpuMesh), 2);
  r.k_register("gpuUploadMesh", @ptrCast(&gpuUploadMesh), 2);
  r.k_register("gpuDrawInstanced", @ptrCast(&gpuDrawInstanced), 3);
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
