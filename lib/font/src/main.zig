/// Font extension for ink — loaded via lib/font/font.k.
///
/// K API (after loading):
///   font_load "path/font.ttf"       → handle (integer)
///   font_metrics (h; size)          → F[3] = [ascent, descent, line_gap]
///   font_shape (h; "text")          → I glyph ID list
///   font_outline (h; glyph_id; sz)  → L of F contours [x0,y0,x1,y1,...]
///
/// Host K API imported via the KRegistry passed to terse_init:
///   ki, kf, kn, kfp, kcp, kip, KF, KI, KL, ku, k_list_set

const std = @import("std");
const font = @import("font_ext");

const K = *anyopaque;

// Mirror of KRegistry in ffi.zig / include/k.h — field order must match exactly.
const KRegistry = extern struct {
    ki:          *const fn (i32)                         callconv(.c) ?K,
    kf:          *const fn (f32)                         callconv(.c) ?K,
    kc:          *const fn (u8)                          callconv(.c) ?K,
    kb:          *const fn (c_int)                       callconv(.c) ?K,
    ks:          *const fn ([*:0]const u8)               callconv(.c) ?K,
    kerr:        *const fn ()                            callconv(.c) ?K,
    KC:          *const fn (i32)                         callconv(.c) ?K,
    KI:          *const fn (i32)                         callconv(.c) ?K,
    KF:          *const fn (i32)                         callconv(.c) ?K,
    KL:          *const fn (i32)                         callconv(.c) ?K,
    kt:          *const fn (?K)                          callconv(.c) i8,
    kn:          *const fn (?K)                          callconv(.c) i32,
    ki_val:      *const fn (?K)                          callconv(.c) i32,
    kf_val:      *const fn (?K)                          callconv(.c) f32,
    kc_val:      *const fn (?K)                          callconv(.c) u8,
    kb_val:      *const fn (?K)                          callconv(.c) c_int,
    kip:         *const fn (?K)                          callconv(.c) ?[*]i32,
    kfp:         *const fn (?K)                          callconv(.c) ?[*]f32,
    kcp:         *const fn (?K)                          callconv(.c) ?[*]u8,
    klp:         *const fn (?K)                          callconv(.c) ?[*]?K,
    ku:          *const fn (?K)                          callconv(.c) void,
    k_list_set:  *const fn (?K, i32, ?K)                callconv(.c) i32,
    k_call:      *const fn (?K, ?K)                     callconv(.c) ?K,
    k_call2:     *const fn (?K, ?K, ?K)                 callconv(.c) ?K,
    k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
};

const KApi = struct {
    ki:          *const fn (i32) callconv(.c) ?K,
    kf:          *const fn (f32) callconv(.c) ?K,
    kn:          *const fn (?K) callconv(.c) i32,
    kfp:         *const fn (?K) callconv(.c) ?[*]f32,
    kcp:         *const fn (?K) callconv(.c) ?[*]u8,
    kip:         *const fn (?K) callconv(.c) ?[*]i32,
    KF:          *const fn (i32) callconv(.c) ?K,
    KI:          *const fn (i32) callconv(.c) ?K,
    KL:          *const fn (i32) callconv(.c) ?K,
    ku:          *const fn (?K) callconv(.c) void,
    k_list_set:  *const fn (?K, i32, ?K) callconv(.c) i32,
};
var g_api: ?KApi = null;

fn ki(v: i32) ?K                              { return g_api.?.ki(v); }
fn kf(v: f32) ?K                              { return g_api.?.kf(v); }
fn kn(x: ?K) i32                              { return g_api.?.kn(x); }
fn kfp(x: ?K) ?[*]f32                        { return g_api.?.kfp(x); }
fn kcp(x: ?K) ?[*]u8                         { return g_api.?.kcp(x); }
fn kip(x: ?K) ?[*]i32                        { return g_api.?.kip(x); }
fn KF(n: i32) ?K                              { return g_api.?.KF(n); }
fn KI(n: i32) ?K                              { return g_api.?.KI(n); }
fn KL(n: i32) ?K                              { return g_api.?.KL(n); }
fn ku(x: ?K) void                             { g_api.?.ku(x); }
fn k_list_set(l: ?K, i: i32, v: ?K) i32      { return g_api.?.k_list_set(l, i, v); }

// ── font_k_load ───────────────────────────────────────────────────────────────
//
// x = char array (file path)  →  i (handle), -1 on failure

export fn fontLoad(path_k: ?K) callconv(.c) ?K {
  const p = kcp(path_k) orelse return ki(-1);
  const n: usize = @intCast(kn(path_k));
  var buf: [512]u8 = undefined;
  if (n >= buf.len) return ki(-1);
  @memcpy(buf[0..n], p[0..n]);
  buf[n] = 0;
  return ki(font.font_load(@ptrCast(&buf)));
}

// ── font_k_metrics ────────────────────────────────────────────────────────────
//
// x = F[2] = [handle_as_float; size_px]  →  F[3] = [ascent; descent; line_gap]

export fn fontMetrics(args_k: ?K) callconv(.c) ?K {
  const ff = kfp(args_k) orelse return ki(-1);
  if (kn(args_k) < 2) return ki(-1);
  const handle: i32 = @intFromFloat(ff[0]);
  const size: f32   = ff[1];
  var m: [3]f32 = .{ 0, 0, 0 };
  if (font.font_metrics(handle, size, &m) != 0) return ki(-1);
  const result = KF(3) orelse return ki(-1);
  const rp = kfp(result) orelse { ku(result); return ki(-1); };
  @memcpy(rp[0..3], &m);
  return result;
}

// ── font_k_shape ──────────────────────────────────────────────────────────────
//
// x = C (char array, UTF-8 text)  →  I glyph ID list

export fn fontShape(args_k: ?K) callconv(.c) ?K {
  // Args is a float array [handle; ...] — the simplest calling conv.
  // For a text string, the caller should pass the char array directly as x
  // after loading the handle separately. Since our FFI takes 1 arg, we pass
  // a list where index 0 is the handle (float) and the rest encodes the text.
  // Simplest working form: args_k IS the char array; handle is separate.
  //
  // Actual supported form: args_k = C (char vector) → shape with handle 0.
  // To specify handle: user wraps in a list (handled by font_outline pattern).
  const cp = kcp(args_k);
  const n = kn(args_k);
  if (cp == null or n <= 0) return KI(0);

  var da = std.heap.DebugAllocator(.{}).init;
  defer _ = da.deinit();
  const alloc = da.allocator();

  const ids_buf = alloc.alloc(u16, @intCast(n)) catch return ki(-1);
  defer alloc.free(ids_buf);

  const count = font.font_shape(0, cp.?, @intCast(n), ids_buf.ptr, @intCast(n));
  if (count < 0) return KI(0);

  const result = KI(count) orelse return ki(-1);
  const rp = kip(result) orelse { ku(result); return ki(-1); };
  for (0..@intCast(count)) |i| rp[i] = ids_buf[i];
  return result;
}

// ── font_k_outline ────────────────────────────────────────────────────────────
//
// x = F[3] = [handle; glyph_id; size_px]  →  L of F contours

export fn fontOutline(args_k: ?K) callconv(.c) ?K {
  const ff = kfp(args_k) orelse return ki(-1);
  if (kn(args_k) < 3) return ki(-1);

  const handle:   i32  = @intFromFloat(ff[0]);
  const glyph_id: u16  = @intCast(@as(i32, @intFromFloat(ff[1])));
  const size:     f32  = ff[2];

  var n_contours: u32 = 0;
  const total = font.font_glyph_outline(handle, glyph_id, size, null, null, &n_contours, 0);
  if (total < 0) return ki(-1);
  if (total == 0 or n_contours == 0) return KL(0);

  var da = std.heap.DebugAllocator(.{}).init;
  defer _ = da.deinit();
  const alloc = da.allocator();

  const n_pts: usize = @intCast(total);
  const pts_buf = alloc.alloc(f32, n_pts * 2) catch return ki(-1);
  defer alloc.free(pts_buf);
  const cnt_buf = alloc.alloc(u32, n_contours) catch return ki(-1);
  defer alloc.free(cnt_buf);

  _ = font.font_glyph_outline(handle, glyph_id, size, pts_buf.ptr, cnt_buf.ptr, &n_contours, n_pts);

  const result_k = KL(@intCast(n_contours)) orelse return ki(-1);

  var pt_off: usize = 0;
  for (0..n_contours) |ci| {
    const cnt = cnt_buf[ci];
    const arr_k = KF(@intCast(cnt * 2)) orelse continue;
    if (kfp(arr_k)) |af| @memcpy(af[0..cnt*2], pts_buf[pt_off*2..(pt_off+cnt)*2]);
    _ = k_list_set(result_k, @intCast(ci), arr_k); // k_list_set consumes arr_k
    pt_off += cnt;
  }
  return result_k;
}

export fn terse_init(reg: *anyopaque) callconv(.c) void {
    const r: *const KRegistry = @ptrCast(@alignCast(reg));
    g_api = .{
        .ki         = r.ki,
        .kf         = r.kf,
        .kn         = r.kn,
        .kfp        = r.kfp,
        .kcp        = r.kcp,
        .kip        = r.kip,
        .KF         = r.KF,
        .KI         = r.KI,
        .KL         = r.KL,
        .ku         = r.ku,
        .k_list_set = r.k_list_set,
    };
}
