//! Audio extension for ink — a thin k-ABI bridge over shim.c (miniaudio).
//! Loaded from k via lib/audio.k; every entry point is registered by name in
//! `terse_init` so the host resolves `2:(`Name;arity)` without dlsym.
//!
//! See shim.c for the threading model.  In short: playback runs on miniaudio's
//! own audio thread (fire-and-forget commands from k, no loop needed), while
//! recording drains a lock-free ring buffer via AudioRecRead — a non-blocking
//! poll you call from your game/UI loop, never from the audio thread.
//!
//! K API (namespaced wrappers live in lib/audio.k):
//!   AudioInit    x         → 1b       init the engine (also lazy on first use)
//!   AudioPlay    "path"    → 1b       fire-and-forget one-shot (UI/SFX)
//!   AudioLoad    "path"    → h        load a controllable sound (in memory)
//!   AudioStream  "path"    → h        load streaming (music/long clips)
//!   AudioStart   h         → 1b       (re)start a sound
//!   AudioStop    h         → 1b       pause a sound
//!   AudioUnload  h         → 1b       free a sound handle
//!   AudioState   h         → (playing;atEnd;cursor;length)_I
//!   AudioVolume  (h;v)     → 1b       linear gain (1.0 = unity)
//!   AudioPitch   (h;p)     → 1b       playback rate multiplier
//!   AudioPan     (h;p)     → 1b       -1..1 stereo pan
//!   AudioLoop    (h;on)    → 1b       loop toggle
//!   AudioSeek    (h;frame) → 1b       jump to a PCM frame
//!   AudioMaster  v         → 1b       master engine volume
//!   AudioPos     (h;xyz_F) → 1b       3D world position
//!   AudioVel     (h;xyz_F) → 1b       velocity (doppler)
//!   AudioDir     (h;xyz_F) → 1b       facing direction (cones)
//!   AudioSpatial (h;on)    → 1b       enable/disable 3D spatialisation
//!   AudioRange   (h;mnmx_F)→ 1b       (minDist;maxDist) attenuation range
//!   AudioListener   xyz_F  → 1b       listener position
//!   AudioListenerDir xyz_F → 1b       listener facing
//!   AudioListenerVel xyz_F → 1b       listener velocity
//!   AudioListenerUp  xyz_F → 1b       listener world-up
//!   AudioRecStart  cr_I    → 1b       start capture (channels;rate)
//!   AudioRecStop   x       → 1b       stop capture
//!   AudioRecInfo   x       → (channels;rate;available)_I
//!   AudioRecRead   maxfr_i → F        drain captured frames (interleaved)
//!   AudioDecode  "path"    → `channels`rate`frames`data dict
//!   AudioEncode  (path;channels;rate;data) → 1b   write a WAV

const std = @import("std");
const K = *anyopaque;
const KRegistry = @import("kabi").KRegistry(K);

// ── C shim (miniaudio) ─────────────────────────────────────────────────────────

extern fn ia_init() c_int;
extern fn ia_master_volume(v: f32) c_int;
extern fn ia_play(path: [*:0]const u8) c_int;
extern fn ia_load(path: [*:0]const u8, stream: c_int) c_int;
extern fn ia_start(h: c_int) c_int;
extern fn ia_stop(h: c_int) c_int;
extern fn ia_unload(h: c_int) c_int;
extern fn ia_playing(h: c_int) c_int;
extern fn ia_at_end(h: c_int) c_int;
extern fn ia_set_volume(h: c_int, v: f32) c_int;
extern fn ia_set_pitch(h: c_int, p: f32) c_int;
extern fn ia_set_pan(h: c_int, p: f32) c_int;
extern fn ia_set_looping(h: c_int, on: c_int) c_int;
extern fn ia_seek(h: c_int, frame: u64) c_int;
extern fn ia_cursor(h: c_int) i64;
extern fn ia_length(h: c_int) i64;
extern fn ia_set_position(h: c_int, x: f32, y: f32, z: f32) c_int;
extern fn ia_set_velocity(h: c_int, x: f32, y: f32, z: f32) c_int;
extern fn ia_set_direction(h: c_int, x: f32, y: f32, z: f32) c_int;
extern fn ia_set_spatial(h: c_int, on: c_int) c_int;
extern fn ia_set_range(h: c_int, mn: f32, mx: f32) c_int;
extern fn ia_listener_position(x: f32, y: f32, z: f32) c_int;
extern fn ia_listener_direction(x: f32, y: f32, z: f32) c_int;
extern fn ia_listener_velocity(x: f32, y: f32, z: f32) c_int;
extern fn ia_listener_up(x: f32, y: f32, z: f32) c_int;
extern fn ia_record_start(channels: c_int, rate: c_int) c_int;
extern fn ia_record_stop() c_int;
extern fn ia_record_channels() c_int;
extern fn ia_record_rate() c_int;
extern fn ia_record_available() c_int;
extern fn ia_record_read(out: [*]f32, maxframes: c_int) c_int;
extern fn ia_decode(path: [*:0]const u8, out: *?[*]f32, channels: *c_int, rate: *c_int) i64;
extern fn ia_free(p: ?*anyopaque) void;
extern fn ia_encode(path: [*:0]const u8, data: [*]const f32, frames: i64, channels: c_int, rate: c_int) c_int;

// ── k-ABI helpers (subset of the host registry) ────────────────────────────────

const KApi = struct {
  ki:          *const fn (i32) callconv(.c) ?K,
  kb:          *const fn (c_int) callconv(.c) ?K,
  KI:          *const fn (i32) callconv(.c) ?K,
  KF:          *const fn (i32) callconv(.c) ?K,
  kn:          *const fn (?K) callconv(.c) i32,
  ki_val:      *const fn (?K) callconv(.c) i32,
  kf_val:      *const fn (?K) callconv(.c) f32,
  kip:         *const fn (?K) callconv(.c) ?[*]i32,
  kfp:         *const fn (?K) callconv(.c) ?[*]f32,
  kcp:         *const fn (?K) callconv(.c) ?[*]u8,
  ku:          *const fn (?K) callconv(.c) void,
  k_list_get:  *const fn (?K, i32) callconv(.c) ?K,
  k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
};
var g: ?KApi = null;

fn ki(v: i32) ?K { return g.?.ki(v); }
fn kb(v: bool) ?K { return g.?.kb(@intFromBool(v)); }
fn KI(n: i32) ?K { return g.?.KI(n); }
fn KF(n: i32) ?K { return g.?.KF(n); }
fn kn(x: ?K) i32 { return g.?.kn(x); }
fn kival(x: ?K) i32 { return g.?.ki_val(x); }
fn kfval(x: ?K) f32 { return g.?.kf_val(x); }
fn kip(x: ?K) ?[*]i32 { return g.?.kip(x); }
fn kfp(x: ?K) ?[*]f32 { return g.?.kfp(x); }
fn kcp(x: ?K) ?[*]u8 { return g.?.kcp(x); }
fn ku(x: ?K) void { g.?.ku(x); }
fn listGet(x: ?K, i: i32) ?K { return g.?.k_list_get(x, i); }

// Copy a k char-vector path into a NUL-terminated stack buffer.
var path_buf: [4096]u8 = undefined;
fn cpath(x: ?K) ?[:0]const u8 {
  const p = kcp(x) orelse return null;
  const n: usize = @intCast(@max(0, kn(x)));
  if (n == 0 or n >= path_buf.len) return null;
  @memcpy(path_buf[0..n], p[0..n]);
  path_buf[n] = 0;
  return path_buf[0..n :0];
}

// Read a 3-component vector (F or I) into an [x,y,z] array; missing lanes → 0.
fn xyz(x: ?K) [3]f32 {
  var v = [3]f32{ 0, 0, 0 };
  const n: usize = @intCast(@max(0, kn(x)));
  if (kfp(x)) |p| {
    for (0..@min(3, n)) |i| v[i] = p[i];
  } else if (kip(x)) |p| {
    for (0..@min(3, n)) |i| v[i] = @floatFromInt(p[i]);
  }
  return v;
}

// ── One-argument entry points ──────────────────────────────────────────────────

export fn AudioInit(_: ?K) callconv(.c) ?K { return kb(ia_init() != 0); }

export fn AudioMaster(x: ?K) callconv(.c) ?K { return kb(ia_master_volume(kfval(x)) != 0); }

export fn AudioPlay(x: ?K) callconv(.c) ?K {
  const p = cpath(x) orelse return kb(false);
  return kb(ia_play(p.ptr) != 0);
}

export fn AudioLoad(x: ?K) callconv(.c) ?K {
  const p = cpath(x) orelse return ki(-1);
  return ki(ia_load(p.ptr, 0));
}

export fn AudioStream(x: ?K) callconv(.c) ?K {
  const p = cpath(x) orelse return ki(-1);
  return ki(ia_load(p.ptr, 1));
}

export fn AudioStart(x: ?K) callconv(.c) ?K { return kb(ia_start(kival(x)) != 0); }
export fn AudioStop(x: ?K) callconv(.c) ?K { return kb(ia_stop(kival(x)) != 0); }
export fn AudioUnload(x: ?K) callconv(.c) ?K { return kb(ia_unload(kival(x)) != 0); }

// (playing; atEnd; cursorFrames; lengthFrames) as an I vector.
export fn AudioState(x: ?K) callconv(.c) ?K {
  const h = kival(x);
  const out = KI(4) orelse return null;
  if (kip(out)) |p| {
    p[0] = ia_playing(h);
    p[1] = ia_at_end(h);
    p[2] = @truncate(ia_cursor(h));
    p[3] = @truncate(ia_length(h));
  }
  return out;
}

export fn AudioListener(x: ?K) callconv(.c) ?K { const v = xyz(x); return kb(ia_listener_position(v[0], v[1], v[2]) != 0); }
export fn AudioListenerDir(x: ?K) callconv(.c) ?K { const v = xyz(x); return kb(ia_listener_direction(v[0], v[1], v[2]) != 0); }
export fn AudioListenerVel(x: ?K) callconv(.c) ?K { const v = xyz(x); return kb(ia_listener_velocity(v[0], v[1], v[2]) != 0); }
export fn AudioListenerUp(x: ?K) callconv(.c) ?K { const v = xyz(x); return kb(ia_listener_up(v[0], v[1], v[2]) != 0); }

export fn AudioRecStart(x: ?K) callconv(.c) ?K {
  var ch: c_int = 1;
  var rate: c_int = 48000;
  const n = kn(x);
  if (kip(x)) |p| {
    if (n >= 1) ch = p[0];
    if (n >= 2) rate = p[1];
  } else if (n >= 1) {
    ch = kival(x);
  }
  return kb(ia_record_start(ch, rate) != 0);
}

export fn AudioRecStop(_: ?K) callconv(.c) ?K { return kb(ia_record_stop() != 0); }

export fn AudioRecInfo(_: ?K) callconv(.c) ?K {
  const out = KI(3) orelse return null;
  if (kip(out)) |p| {
    p[0] = ia_record_channels();
    p[1] = ia_record_rate();
    p[2] = ia_record_available();
  }
  return out;
}

// Drain up to `maxframes` captured frames → interleaved F vector (length =
// frames*channels).  Returns an empty F when nothing is buffered.
export fn AudioRecRead(x: ?K) callconv(.c) ?K {
  const maxframes = kival(x);
  const ch = ia_record_channels();
  const avail = ia_record_available();
  var want = maxframes;
  if (want <= 0 or want > avail) want = avail;
  if (want <= 0) return KF(0);
  const out = KF(want * ch) orelse return null;
  const p = kfp(out) orelse return out;
  const got = ia_record_read(p, want);
  if (got == want) return out;
  // Short read: rebuild a right-sized vector (rare — the poll raced the writer).
  const trimmed = KF(got * ch) orelse return out;
  if (kfp(trimmed)) |tp| @memcpy(tp[0..@intCast(got * ch)], p[0..@intCast(got * ch)]);
  ku(out);
  return trimmed;
}

// Decode a whole file → `channels`rate`frames`data dict (data is interleaved F).
export fn AudioDecode(x: ?K) callconv(.c) ?K {
  const p = cpath(x) orelse return null;
  var pcm: ?[*]f32 = null;
  var ch: c_int = 0;
  var rate: c_int = 0;
  const frames = ia_decode(p.ptr, &pcm, &ch, &rate);
  if (frames < 0 or pcm == null) return null;
  defer ia_free(pcm);

  const total: usize = @intCast(frames * ch);
  const data = KF(@intCast(total)) orelse return null;
  if (kfp(data)) |dp| if (total > 0) @memcpy(dp[0..total], pcm.?[0..total]);

  const keys = [_][*:0]const u8{ "channels", "rate", "frames", "data" };
  const vals = [_]?K{ ki(ch), ki(rate), ki(@truncate(frames)), data };
  const d = g.?.k_make_dict(4, &keys, &vals);
  for (vals) |v| ku(v);
  return d;
}

// ── Two-argument entry points ──────────────────────────────────────────────────

export fn AudioVolume(h: ?K, v: ?K) callconv(.c) ?K { return kb(ia_set_volume(kival(h), kfval(v)) != 0); }
export fn AudioPitch(h: ?K, v: ?K) callconv(.c) ?K { return kb(ia_set_pitch(kival(h), kfval(v)) != 0); }
export fn AudioPan(h: ?K, v: ?K) callconv(.c) ?K { return kb(ia_set_pan(kival(h), kfval(v)) != 0); }
export fn AudioLoop(h: ?K, v: ?K) callconv(.c) ?K { return kb(ia_set_looping(kival(h), kival(v)) != 0); }
export fn AudioSeek(h: ?K, v: ?K) callconv(.c) ?K { return kb(ia_seek(kival(h), @intCast(@max(0, kival(v)))) != 0); }
export fn AudioSpatial(h: ?K, v: ?K) callconv(.c) ?K { return kb(ia_set_spatial(kival(h), kival(v)) != 0); }

export fn AudioPos(h: ?K, v: ?K) callconv(.c) ?K { const p = xyz(v); return kb(ia_set_position(kival(h), p[0], p[1], p[2]) != 0); }
export fn AudioVel(h: ?K, v: ?K) callconv(.c) ?K { const p = xyz(v); return kb(ia_set_velocity(kival(h), p[0], p[1], p[2]) != 0); }
export fn AudioDir(h: ?K, v: ?K) callconv(.c) ?K { const p = xyz(v); return kb(ia_set_direction(kival(h), p[0], p[1], p[2]) != 0); }

export fn AudioRange(h: ?K, v: ?K) callconv(.c) ?K {
  const mn = if (kfp(v)) |p| (if (kn(v) >= 1) p[0] else 0) else 0;
  const mx = if (kfp(v)) |p| (if (kn(v) >= 2) p[1] else 0) else 0;
  return kb(ia_set_range(kival(h), mn, mx) != 0);
}

// ── One-argument packed-list entry point ───────────────────────────────────────

// AudioEncode (path; channels; rate; data_F) → 1b.  Packed into one list because
// the host FFI caps direct arity at 3.
export fn AudioEncode(arg: ?K) callconv(.c) ?K {
  if (kn(arg) < 4) return kb(false);
  const path_k = listGet(arg, 0);
  defer ku(path_k);
  const ch_k = listGet(arg, 1);
  defer ku(ch_k);
  const rate_k = listGet(arg, 2);
  defer ku(rate_k);
  const data_k = listGet(arg, 3);
  defer ku(data_k);

  const p = cpath(path_k) orelse return kb(false);
  const ch = kival(ch_k);
  const rate = kival(rate_k);
  const total: usize = @intCast(@max(0, kn(data_k)));
  if (ch <= 0 or total == 0) return kb(false);
  const dp = kfp(data_k) orelse return kb(false);
  const frames = @divTrunc(@as(i64, @intCast(total)), ch);
  return kb(ia_encode(p.ptr, dp, frames, ch, rate) != 0);
}

// ── Registration ───────────────────────────────────────────────────────────────

fn initApi(reg: *anyopaque) void {
  const r: *const KRegistry = @ptrCast(@alignCast(reg));
  g = .{
    .ki = r.ki, .kb = r.kb, .KI = r.KI, .KF = r.KF, .kn = r.kn,
    .ki_val = r.ki_val, .kf_val = r.kf_val, .kip = r.kip, .kfp = r.kfp,
    .kcp = r.kcp, .ku = r.ku, .k_list_get = r.k_list_get, .k_make_dict = r.k_make_dict,
  };
  const reg_fn = struct {
    fn go(rr: *const KRegistry, name: [*:0]const u8, ptr: *const anyopaque, arity: u8) void {
      rr.k_register(name, ptr, arity);
    }
  }.go;
  reg_fn(r, "AudioInit", @ptrCast(&AudioInit), 1);
  reg_fn(r, "AudioMaster", @ptrCast(&AudioMaster), 1);
  reg_fn(r, "AudioPlay", @ptrCast(&AudioPlay), 1);
  reg_fn(r, "AudioLoad", @ptrCast(&AudioLoad), 1);
  reg_fn(r, "AudioStream", @ptrCast(&AudioStream), 1);
  reg_fn(r, "AudioStart", @ptrCast(&AudioStart), 1);
  reg_fn(r, "AudioStop", @ptrCast(&AudioStop), 1);
  reg_fn(r, "AudioUnload", @ptrCast(&AudioUnload), 1);
  reg_fn(r, "AudioState", @ptrCast(&AudioState), 1);
  reg_fn(r, "AudioListener", @ptrCast(&AudioListener), 1);
  reg_fn(r, "AudioListenerDir", @ptrCast(&AudioListenerDir), 1);
  reg_fn(r, "AudioListenerVel", @ptrCast(&AudioListenerVel), 1);
  reg_fn(r, "AudioListenerUp", @ptrCast(&AudioListenerUp), 1);
  reg_fn(r, "AudioRecStart", @ptrCast(&AudioRecStart), 1);
  reg_fn(r, "AudioRecStop", @ptrCast(&AudioRecStop), 1);
  reg_fn(r, "AudioRecInfo", @ptrCast(&AudioRecInfo), 1);
  reg_fn(r, "AudioRecRead", @ptrCast(&AudioRecRead), 1);
  reg_fn(r, "AudioDecode", @ptrCast(&AudioDecode), 1);
  reg_fn(r, "AudioVolume", @ptrCast(&AudioVolume), 2);
  reg_fn(r, "AudioPitch", @ptrCast(&AudioPitch), 2);
  reg_fn(r, "AudioPan", @ptrCast(&AudioPan), 2);
  reg_fn(r, "AudioLoop", @ptrCast(&AudioLoop), 2);
  reg_fn(r, "AudioSeek", @ptrCast(&AudioSeek), 2);
  reg_fn(r, "AudioSpatial", @ptrCast(&AudioSpatial), 2);
  reg_fn(r, "AudioPos", @ptrCast(&AudioPos), 2);
  reg_fn(r, "AudioVel", @ptrCast(&AudioVel), 2);
  reg_fn(r, "AudioDir", @ptrCast(&AudioDir), 2);
  reg_fn(r, "AudioRange", @ptrCast(&AudioRange), 2);
  reg_fn(r, "AudioEncode", @ptrCast(&AudioEncode), 1);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void { initApi(reg); }
export fn ink_ext_init_audio(reg: *anyopaque) callconv(.c) void { initApi(reg); }
