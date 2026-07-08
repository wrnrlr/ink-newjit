// shim.c — a small, stable C ABI over miniaudio for the ink `audio` extension.
//
// Rationale: miniaudio.h is a 4MB single-header library.  Rather than translate
// its whole surface through Zig's @cImport, this shim compiles the miniaudio
// implementation once and exposes exactly the handful of integer-handle-based
// entry points the k side needs.  The Zig extension (audio.zig) declares these
// as extern and bridges them to the k-ABI.
//
// Threading model — the important part:
//   * Playback goes through miniaudio's high-level `ma_engine`, which owns its
//     own real-time audio thread and mixes/spatialises internally.  The k side
//     never touches that thread: it just issues fire-and-forget commands
//     (play/start/stop/set-position/…), so playback needs no k-side loop.
//   * Recording runs a capture `ma_device` whose real-time callback writes PCM
//     into a lock-free ring buffer (`ma_pcm_rb`).  The k main loop drains the
//     buffer with ia_record_read() whenever it likes — a non-blocking poll,
//     exactly like reading input events off the window loop.  We never call
//     into the (single-threaded, non-reentrant) ink VM from the audio thread.

#define MINIAUDIO_IMPLEMENTATION
// We don't need miniaudio's tone/waveform generators; keep the build lean.
#define MA_NO_GENERATION
#include "miniaudio.h"

#include <string.h>
#include <stdlib.h>

// ── Engine (playback) ──────────────────────────────────────────────────────────

static ma_engine g_engine;
static int       g_engine_ready = 0;

// Lazily bring the engine up on first use so the k side can just call any
// playback function without an explicit init.  Returns 1 on success.
static int ensure_engine(void) {
  if (g_engine_ready) return 1;
  if (ma_engine_init(NULL, &g_engine) != MA_SUCCESS) return 0;
  g_engine_ready = 1;
  return 1;
}

int ia_init(void) { return ensure_engine(); }

void ia_uninit(void) {
  if (g_engine_ready) { ma_engine_uninit(&g_engine); g_engine_ready = 0; }
}

int ia_master_volume(float v) {
  if (!ensure_engine()) return 0;
  return ma_engine_set_volume(&g_engine, v) == MA_SUCCESS;
}

// Fire-and-forget one-shot (UI blips, quick SFX).  No handle to manage — the
// engine reclaims the voice when it finishes.
int ia_play(const char* path) {
  if (!ensure_engine()) return 0;
  return ma_engine_play_sound(&g_engine, path, NULL) == MA_SUCCESS;
}

// ── Managed sounds (integer handles) ───────────────────────────────────────────

#define IA_MAX_SOUNDS 1024
static ma_sound* g_sounds[IA_MAX_SOUNDS];  // NULL == free slot; handle == index

static ma_sound* snd(int h) {
  if (h < 0 || h >= IA_MAX_SOUNDS) return NULL;
  return g_sounds[h];
}

// Load a sound file into a controllable voice.  `stream` != 0 decodes on the
// fly (music / long clips); otherwise the whole file is decoded into memory
// (short SFX you retrigger).  Returns a handle >= 0, or -1 on failure.
int ia_load(const char* path, int stream) {
  if (!ensure_engine()) return -1;
  int h = -1;
  for (int i = 0; i < IA_MAX_SOUNDS; i++) { if (!g_sounds[i]) { h = i; break; } }
  if (h < 0) return -1;
  ma_sound* s = (ma_sound*)calloc(1, sizeof(ma_sound));
  if (!s) return -1;
  ma_uint32 flags = stream ? MA_SOUND_FLAG_STREAM : 0;
  if (ma_sound_init_from_file(&g_engine, path, flags, NULL, NULL, s) != MA_SUCCESS) {
    free(s);
    return -1;
  }
  g_sounds[h] = s;
  return h;
}

int ia_start(int h)  { ma_sound* s = snd(h); return s && ma_sound_start(s) == MA_SUCCESS; }
int ia_stop(int h)   { ma_sound* s = snd(h); return s && ma_sound_stop(s)  == MA_SUCCESS; }

int ia_unload(int h) {
  ma_sound* s = snd(h);
  if (!s) return 0;
  ma_sound_uninit(s);
  free(s);
  g_sounds[h] = NULL;
  return 1;
}

int ia_playing(int h) { ma_sound* s = snd(h); return s ? ma_sound_is_playing(s) : 0; }
int ia_at_end(int h)  { ma_sound* s = snd(h); return s ? ma_sound_at_end(s)     : 0; }

int ia_set_volume(int h, float v)  { ma_sound* s = snd(h); if (!s) return 0; ma_sound_set_volume(s, v); return 1; }
int ia_set_pitch(int h, float p)   { ma_sound* s = snd(h); if (!s) return 0; ma_sound_set_pitch(s, p);  return 1; }
int ia_set_pan(int h, float p)     { ma_sound* s = snd(h); if (!s) return 0; ma_sound_set_pan(s, p);    return 1; }
int ia_set_looping(int h, int on)  { ma_sound* s = snd(h); if (!s) return 0; ma_sound_set_looping(s, on ? MA_TRUE : MA_FALSE); return 1; }

int ia_seek(int h, unsigned long long frame) {
  ma_sound* s = snd(h);
  return s && ma_sound_seek_to_pcm_frame(s, frame) == MA_SUCCESS;
}

// Current playback position, in PCM frames.
long long ia_cursor(int h) {
  ma_sound* s = snd(h);
  if (!s) return -1;
  ma_uint64 c = 0;
  if (ma_sound_get_cursor_in_pcm_frames(s, &c) != MA_SUCCESS) return -1;
  return (long long)c;
}

// Total length in PCM frames (-1 if unknown, e.g. an endless stream).
long long ia_length(int h) {
  ma_sound* s = snd(h);
  if (!s) return -1;
  ma_uint64 n = 0;
  if (ma_sound_get_length_in_pcm_frames(s, &n) != MA_SUCCESS) return -1;
  return (long long)n;
}

// ── 3D spatialisation ──────────────────────────────────────────────────────────

int ia_set_position(int h, float x, float y, float z)  { ma_sound* s = snd(h); if (!s) return 0; ma_sound_set_position(s, x, y, z);  return 1; }
int ia_set_velocity(int h, float x, float y, float z)  { ma_sound* s = snd(h); if (!s) return 0; ma_sound_set_velocity(s, x, y, z);  return 1; }
int ia_set_direction(int h, float x, float y, float z) { ma_sound* s = snd(h); if (!s) return 0; ma_sound_set_direction(s, x, y, z); return 1; }

int ia_set_spatial(int h, int on) {
  ma_sound* s = snd(h);
  if (!s) return 0;
  ma_sound_set_spatialization_enabled(s, on ? MA_TRUE : MA_FALSE);
  return 1;
}

// Distance attenuation range: sound is at full volume within `mn`, silent past
// `mx`, and rolls off in between.
int ia_set_range(int h, float mn, float mx) {
  ma_sound* s = snd(h);
  if (!s) return 0;
  ma_sound_set_min_distance(s, mn);
  ma_sound_set_max_distance(s, mx);
  return 1;
}

int ia_listener_position(float x, float y, float z)  { if (!ensure_engine()) return 0; ma_engine_listener_set_position(&g_engine, 0, x, y, z);  return 1; }
int ia_listener_direction(float x, float y, float z) { if (!ensure_engine()) return 0; ma_engine_listener_set_direction(&g_engine, 0, x, y, z); return 1; }
int ia_listener_velocity(float x, float y, float z)  { if (!ensure_engine()) return 0; ma_engine_listener_set_velocity(&g_engine, 0, x, y, z);  return 1; }
int ia_listener_up(float x, float y, float z)        { if (!ensure_engine()) return 0; ma_engine_listener_set_world_up(&g_engine, 0, x, y, z);  return 1; }

// ── Recording (capture → lock-free ring buffer) ────────────────────────────────

static ma_device g_capture;
static ma_pcm_rb g_rb;
static int       g_recording = 0;
static int       g_rec_channels = 1;
static int       g_rec_rate = 48000;

// Real-time audio thread: copy captured frames into the ring buffer.  If the k
// side falls behind and the buffer fills, the excess is dropped (we never block
// the audio thread).
static void capture_callback(ma_device* dev, void* out, const void* in, ma_uint32 frames) {
  (void)dev; (void)out;
  const float* src = (const float*)in;
  ma_uint32 remaining = frames;
  while (remaining > 0) {
    ma_uint32 n = remaining;
    void* dst;
    if (ma_pcm_rb_acquire_write(&g_rb, &n, &dst) != MA_SUCCESS || n == 0) break;
    memcpy(dst, src, (size_t)n * g_rec_channels * sizeof(float));
    ma_pcm_rb_commit_write(&g_rb, n);
    src += (size_t)n * g_rec_channels;
    remaining -= n;
  }
}

// Start capturing.  channels/rate <= 0 fall back to sensible mono@48k defaults.
// The ring buffer holds ~2s so a UI-rate poll never underflows.
int ia_record_start(int channels, int rate) {
  if (g_recording) return 1;
  g_rec_channels = channels > 0 ? channels : 1;
  g_rec_rate     = rate     > 0 ? rate     : 48000;

  if (ma_pcm_rb_init(ma_format_f32, g_rec_channels, g_rec_rate * 2, NULL, NULL, &g_rb) != MA_SUCCESS)
    return 0;

  ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
  cfg.capture.format   = ma_format_f32;
  cfg.capture.channels = g_rec_channels;
  cfg.sampleRate       = g_rec_rate;
  cfg.dataCallback     = capture_callback;

  if (ma_device_init(NULL, &cfg, &g_capture) != MA_SUCCESS) {
    ma_pcm_rb_uninit(&g_rb);
    return 0;
  }
  if (ma_device_start(&g_capture) != MA_SUCCESS) {
    ma_device_uninit(&g_capture);
    ma_pcm_rb_uninit(&g_rb);
    return 0;
  }
  g_recording = 1;
  return 1;
}

int ia_record_stop(void) {
  if (!g_recording) return 0;
  ma_device_uninit(&g_capture);
  ma_pcm_rb_uninit(&g_rb);
  g_recording = 0;
  return 1;
}

int ia_record_channels(void) { return g_rec_channels; }
int ia_record_rate(void)     { return g_rec_rate; }
int ia_record_available(void) { return g_recording ? (int)ma_pcm_rb_available_read(&g_rb) : 0; }

// Drain up to `maxframes` frames into `out` (interleaved f32).  Returns the
// number of frames actually written; 0 when nothing is buffered.  Non-blocking.
int ia_record_read(float* out, int maxframes) {
  if (!g_recording || maxframes <= 0) return 0;
  ma_uint32 got = 0;
  ma_uint32 want = (ma_uint32)maxframes;
  while (want > 0) {
    ma_uint32 n = want;
    void* src;
    if (ma_pcm_rb_acquire_read(&g_rb, &n, &src) != MA_SUCCESS || n == 0) break;
    memcpy(out + (size_t)got * g_rec_channels, src, (size_t)n * g_rec_channels * sizeof(float));
    ma_pcm_rb_commit_read(&g_rb, n);
    got  += n;
    want -= n;
  }
  return (int)got;
}

// ── File decode / encode (load / save) ─────────────────────────────────────────

// Decode an entire audio file (WAV/FLAC/MP3) to interleaved f32.  On success
// returns the frame count and hands back a malloc'd buffer via *out (free it
// with ia_free) plus the channel count and sample rate.  Returns -1 on error.
long long ia_decode(const char* path, float** out, int* channels, int* rate) {
  ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 0, 0);
  ma_uint64 frames = 0;
  void* pcm = NULL;
  if (ma_decode_file(path, &cfg, &frames, &pcm) != MA_SUCCESS) return -1;
  *out      = (float*)pcm;
  *channels = (int)cfg.channels;
  *rate     = (int)cfg.sampleRate;
  return (long long)frames;
}

void ia_free(void* p) { ma_free(p, NULL); }

// Write interleaved f32 PCM to a WAV file.  Returns 1 on success.
int ia_encode(const char* path, const float* data, long long frames, int channels, int rate) {
  ma_encoder_config cfg = ma_encoder_config_init(ma_encoding_format_wav, ma_format_f32,
                                                 (ma_uint32)channels, (ma_uint32)rate);
  ma_encoder enc;
  if (ma_encoder_init_file(path, &cfg, &enc) != MA_SUCCESS) return 0;
  ma_uint64 written = 0;
  ma_result r = ma_encoder_write_pcm_frames(&enc, data, (ma_uint64)frames, &written);
  ma_encoder_uninit(&enc);
  return r == MA_SUCCESS;
}
