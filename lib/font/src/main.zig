/// Font extension for ink — K FFI wrapper.
///
/// Loaded via lib/font.k.  Exports:
///   ReadFont    "path"               → dict (or list of dicts for TTC)
///   FontShape   handle_i  text_C     → I glyph ID list   (dyadic)
///   FontOutline F[handle;glyph;size] → L of F contours

const std = @import("std");
const font = @import("font_ext");

const K = *anyopaque;

// Mirror of KRegistry in ffi.zig — field order must match exactly.
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
    KC:          *const fn (i32) callconv(.c) ?K,
    KI:          *const fn (i32) callconv(.c) ?K,
    KF:          *const fn (i32) callconv(.c) ?K,
    KL:          *const fn (i32) callconv(.c) ?K,
    kt:          *const fn (?K) callconv(.c) i8,
    kn:          *const fn (?K) callconv(.c) i32,
    ki_val:      *const fn (?K) callconv(.c) i32,
    kf_val:      *const fn (?K) callconv(.c) f32,
    kfp:         *const fn (?K) callconv(.c) ?[*]f32,
    kcp:         *const fn (?K) callconv(.c) ?[*]u8,
    kip:         *const fn (?K) callconv(.c) ?[*]i32,
    ku:          *const fn (?K) callconv(.c) void,
    k_list_set:  *const fn (?K, i32, ?K) callconv(.c) i32,
    k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
};
var g_api: ?KApi = null;

fn ki(v: i32) ?K                                   { return g_api.?.ki(v); }
fn kf(v: f32) ?K                                   { return g_api.?.kf(v); }
fn KC(n: i32) ?K                                   { return g_api.?.KC(n); }
fn KI(n: i32) ?K                                   { return g_api.?.KI(n); }
fn KF(n: i32) ?K                                   { return g_api.?.KF(n); }
fn KL(n: i32) ?K                                   { return g_api.?.KL(n); }
fn kt(x: ?K) i8                                    { return g_api.?.kt(x); }
fn kn(x: ?K) i32                                   { return g_api.?.kn(x); }
fn ki_val(x: ?K) i32                               { return g_api.?.ki_val(x); }
fn kf_val(x: ?K) f32                               { return g_api.?.kf_val(x); }
fn kfp(x: ?K) ?[*]f32                              { return g_api.?.kfp(x); }
fn kcp(x: ?K) ?[*]u8                               { return g_api.?.kcp(x); }
fn kip(x: ?K) ?[*]i32                              { return g_api.?.kip(x); }
fn ku(x: ?K) void                                  { g_api.?.ku(x); }
fn k_list_set(l: ?K, i: i32, v: ?K) i32           { return g_api.?.k_list_set(l, i, v); }
fn k_make_dict(n: i32, ks_: [*]const [*:0]const u8, vs: [*]const ?K) ?K {
  return g_api.?.k_make_dict(n, ks_, vs);
}

// ── Build font dict for one face ──────────────────────────────────────────────

fn buildFaceDict(handle: i32) ?K {
  var nameBuf: [512]u8 = undefined;
  var stylBuf: [512]u8 = undefined;
  const family = font.faceName(handle, .family,    .typographic_family,    nameBuf[0..]);
  const style  = font.faceName(handle, .subfamily, .typographic_subfamily, stylBuf[0..]);

  const upm  = font.faceUnitsPerEm(handle);
  const ng   = font.faceNumGlyphs(handle);
  const asc  = font.faceAscender(handle);
  const desc = font.faceDescender(handle);
  const lgap = font.faceLineGap(handle);
  const xht  = font.faceXHeight(handle);
  const caph = font.faceCapHeight(handle);
  const wgt  = font.faceWeight(handle);
  const wid  = font.faceWidth(handle);
  const flags = font.faceFlags(handle);

  // Allocate per-glyph arrays
  const adv_k = KI(ng) orelse return null;
  const lsb_k = KI(ng) orelse { ku(adv_k); return null; };
  if (kip(adv_k)) |ap| { for (0..@intCast(ng)) |i| ap[i] = font.glyphAdvance(handle, @intCast(i)); }
  if (kip(lsb_k)) |lp| { for (0..@intCast(ng)) |i| lp[i] = font.glyphLsb(handle, @intCast(i)); }

  // Allocate name/style char arrays
  const nm_k  = KC(@intCast(family.len)) orelse { ku(adv_k); ku(lsb_k); return null; };
  const sty_k = KC(@intCast(style.len))  orelse { ku(adv_k); ku(lsb_k); ku(nm_k); return null; };
  if (kcp(nm_k))  |p| @memcpy(p[0..family.len], family);
  if (kcp(sty_k)) |p| @memcpy(p[0..style.len],  style);

  // BMP codepoint→glyph map: cmap[cp] = glyphID (0 = unmapped), I vector of 65536
  const CMAP_SIZE: i32 = 65536;
  const cmap_k = KI(CMAP_SIZE) orelse { ku(adv_k); ku(lsb_k); ku(nm_k); ku(sty_k); return null; };
  if (kip(cmap_k)) |p| _ = font.buildCmapBmp(handle, p[0..@intCast(CMAP_SIZE)]);

  const knames = [_][*:0]const u8{
    "h",       "name",  "style",  "upm",    "nGlyphs",
    "ascent",  "descent", "lineGap", "xHeight", "capHeight",
    "weight",  "width",   "bold",   "italic", "mono",   "variable",
    "adv",     "lsb",    "cmap",
  };
  const kvals = [_]?K{
    ki(handle),          nm_k,             sty_k,            ki(upm),         ki(ng),
    ki(asc),             ki(desc),         ki(lgap),         ki(xht),         ki(caph),
    ki(wgt),             ki(wid),          ki(flags & 1),    ki((flags>>1)&1), ki((flags>>2)&1), ki((flags>>3)&1),
    adv_k,               lsb_k,           cmap_k,
  };

  const result = k_make_dict(knames.len, &knames, &kvals);
  // k_make_dict ref-counts values internally; we must release our refs.
  for (kvals) |v| ku(v);
  return result;
}

// ── ReadFont ──────────────────────────────────────────────────────────────────
//
// x = C (file path)  →  dict (TTF/OTF) or L of dicts (TTC)

export fn ReadFont(path_k: ?K) callconv(.c) ?K {
  const cp = kcp(path_k) orelse return null;
  const n: usize = @intCast(@max(0, kn(path_k)));
  var buf: [1024]u8 = undefined;
  if (n >= buf.len) return null;
  @memcpy(buf[0..n], cp[0..n]);
  buf[n] = 0;
  const path: [*:0]const u8 = @ptrCast(&buf);

  // Load all faces in one file-read pass.
  var handles: [64]i32 = undefined;
  const nfaces = font.font_load_all_faces(path, &handles, 64);
  if (nfaces <= 0) return null;

  if (nfaces == 1) return buildFaceDict(handles[0]);

  // TTC: return L of dicts
  const result = KL(nfaces) orelse return null;
  for (0..@intCast(nfaces)) |fi| {
    _ = k_list_set(result, @intCast(fi), buildFaceDict(handles[fi]));
  }
  return result;
}

// ── FontShape ─────────────────────────────────────────────────────────────────
//
// Dyadic: x = handle_i,  y = text_C  →  I glyph ID list

export fn FontShape(handle_k: ?K, text_k: ?K) callconv(.c) ?K {
  const handle: i32 = if (kt(handle_k) == 'i') ki_val(handle_k)
                      else @intFromFloat(kf_val(handle_k));

  const cp = kcp(text_k) orelse return KI(0);
  const n  = kn(text_k);
  if (n <= 0) return KI(0);

  const dalloc = std.heap.c_allocator;
  const ids_buf = dalloc.alloc(u16, @intCast(n)) catch return null;
  defer dalloc.free(ids_buf);

  const count = font.font_shape(handle, cp, @intCast(n), ids_buf.ptr, @intCast(n));
  if (count < 0) return KI(0);

  const result = KI(count) orelse return null;
  const rp = kip(result) orelse { ku(result); return null; };
  for (0..@intCast(count)) |i| rp[i] = ids_buf[i];
  return result;
}

// ── FontOutline ───────────────────────────────────────────────────────────────
//
// x = F[3] = [handle_f; glyph_id_f; size_px_f]  →  L of F contours

export fn FontOutline(args_k: ?K) callconv(.c) ?K {
  const ff = kfp(args_k) orelse return null;
  if (kn(args_k) < 3) return null;

  const handle:   i32  = @intFromFloat(ff[0]);
  const glyph_id: u16  = @intCast(@as(i32, @intFromFloat(ff[1])));
  const size:     f32  = ff[2];

  var n_contours: u32 = 0;
  const total = font.font_glyph_outline(handle, glyph_id, size, null, null, &n_contours, 0);
  if (total < 0) return null;
  if (total == 0 or n_contours == 0) return KL(0);

  const dalloc = std.heap.c_allocator;
  const n_pts: usize = @intCast(total);
  const pts_buf = dalloc.alloc(f32, n_pts * 2) catch return null;
  defer dalloc.free(pts_buf);
  const cnt_buf = dalloc.alloc(u32, n_contours) catch return null;
  defer dalloc.free(cnt_buf);

  _ = font.font_glyph_outline(handle, glyph_id, size, pts_buf.ptr, cnt_buf.ptr, &n_contours, n_pts);

  const result_k = KL(@intCast(n_contours)) orelse return null;

  var pt_off: usize = 0;
  for (0..n_contours) |ci| {
    const cnt = cnt_buf[ci];
    const arr_k = KF(@intCast(cnt * 2)) orelse continue;
    if (kfp(arr_k)) |af| @memcpy(af[0..cnt*2], pts_buf[pt_off*2..(pt_off+cnt)*2]);
    _ = k_list_set(result_k, @intCast(ci), arr_k);
    pt_off += cnt;
  }
  return result_k;
}

// ── terse_init ────────────────────────────────────────────────────────────────

export fn terse_init(reg: *anyopaque) callconv(.c) void {
  const r: *const KRegistry = @ptrCast(@alignCast(reg));
  g_api = .{
    .ki         = r.ki,
    .kf         = r.kf,
    .KC         = r.KC,
    .KI         = r.KI,
    .KF         = r.KF,
    .KL         = r.KL,
    .kt         = r.kt,
    .kn         = r.kn,
    .ki_val     = r.ki_val,
    .kf_val     = r.kf_val,
    .kfp        = r.kfp,
    .kcp        = r.kcp,
    .kip        = r.kip,
    .ku         = r.ku,
    .k_list_set = r.k_list_set,
    .k_make_dict = r.k_make_dict,
  };
}
