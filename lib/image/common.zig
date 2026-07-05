/// Shared image utilities: the decoded-pixel container, channel-count conversion
/// (ported from stb_image's stbi__convert_format), overflow-checked size math,
/// vertical flip, and the K-value builders that turn a decoded buffer into the
/// ink image dict every `*.read` returns.
///
/// Image dict shape (matches the "font-like data layout" convention — a plain
/// symbol-keyed dict of scalars + a bare data vector):
///   `width`height`comp`data ! (w; h; n; DATA)
/// DATA is a row-major, top-left-first, channel-interleaved vector of length
/// w*h*n: an I vector for 8/16-bit images (samples 0..255 / 0..65535) or an F
/// vector for HDR/float images.

const std = @import("std");
const k = @import("kbuild.zig");

pub const Alloc = std.mem.Allocator;
pub const Error = error{ OutOfMemory, Corrupt, Unsupported, TooLarge };

pub const MAX_DIM: usize = 1 << 24; // reject absurd dimensions (stb default)

pub const Image = struct {
  w: usize,
  h: usize,
  comp: usize, // channels actually present in `data`
  src_comp: usize = 0, // channels in the source file (reported to the user)
  data: []u8,
  alloc: Alloc,

  pub fn deinit(self: *Image) void {
    if (self.data.len > 0) self.alloc.free(self.data);
    self.data = &.{};
  }
};

// ── size helpers (overflow-checked, like stb) ──────────────────────────────────

pub fn checkedSize(a: usize, b: usize, c: usize) Error!usize {
  const ab = std.math.mul(usize, a, b) catch return Error.TooLarge;
  return std.math.mul(usize, ab, c) catch return Error.TooLarge;
}

// ── grayscale luma (BT.601-ish, matches stb) ───────────────────────────────────

pub fn computeY(r: u8, g: u8, b: u8) u8 {
  const rr: u32 = r;
  const gg: u32 = g;
  const bb: u32 = b;
  return @intCast(((rr * 77) + (gg * 150) + (bb * 29)) >> 8);
}

/// Convert an 8-bit interleaved buffer from `img_n` channels to `req_comp`
/// channels in place of a fresh allocation; frees `data` and returns the new
/// buffer. Channel semantics: 1=grey 2=grey+a 3=rgb 4=rgba.
pub fn convertFormat(alloc: Alloc, data: []u8, img_n: usize, req_comp: usize, w: usize, h: usize) Error![]u8 {
  if (req_comp == img_n) return data;
  std.debug.assert(req_comp >= 1 and req_comp <= 4);
  const good = alloc.alloc(u8, try checkedSize(req_comp, w, h)) catch return Error.OutOfMemory;
  errdefer alloc.free(good);

  var j: usize = 0;
  while (j < h) : (j += 1) {
    const src = data[j * w * img_n ..];
    const dst = good[j * w * req_comp ..];
    const combo = img_n * 8 + req_comp;
    var i: usize = 0;
    var s: usize = 0;
    var d: usize = 0;
    while (i < w) : ({
      i += 1;
      s += img_n;
      d += req_comp;
    }) {
      switch (combo) {
        1 * 8 + 2 => {
          dst[d + 0] = src[s];
          dst[d + 1] = 255;
        },
        1 * 8 + 3 => {
          dst[d + 0] = src[s];
          dst[d + 1] = src[s];
          dst[d + 2] = src[s];
        },
        1 * 8 + 4 => {
          dst[d + 0] = src[s];
          dst[d + 1] = src[s];
          dst[d + 2] = src[s];
          dst[d + 3] = 255;
        },
        2 * 8 + 1 => dst[d] = src[s],
        2 * 8 + 3 => {
          dst[d + 0] = src[s];
          dst[d + 1] = src[s];
          dst[d + 2] = src[s];
        },
        2 * 8 + 4 => {
          dst[d + 0] = src[s];
          dst[d + 1] = src[s];
          dst[d + 2] = src[s];
          dst[d + 3] = src[s + 1];
        },
        3 * 8 + 4 => {
          dst[d + 0] = src[s + 0];
          dst[d + 1] = src[s + 1];
          dst[d + 2] = src[s + 2];
          dst[d + 3] = 255;
        },
        3 * 8 + 1 => dst[d] = computeY(src[s], src[s + 1], src[s + 2]),
        3 * 8 + 2 => {
          dst[d + 0] = computeY(src[s], src[s + 1], src[s + 2]);
          dst[d + 1] = 255;
        },
        4 * 8 + 1 => dst[d] = computeY(src[s], src[s + 1], src[s + 2]),
        4 * 8 + 2 => {
          dst[d + 0] = computeY(src[s], src[s + 1], src[s + 2]);
          dst[d + 1] = src[s + 3];
        },
        4 * 8 + 3 => {
          dst[d + 0] = src[s + 0];
          dst[d + 1] = src[s + 1];
          dst[d + 2] = src[s + 2];
        },
        else => return Error.Unsupported,
      }
    }
  }
  alloc.free(data);
  return good;
}

/// Flip an interleaved buffer vertically (top row ↔ bottom row).
pub fn flipVertical(data: []u8, w: usize, h: usize, bpp: usize) void {
  const row = w * bpp;
  var y: usize = 0;
  while (y < h / 2) : (y += 1) {
    const a = data[y * row ..][0..row];
    const b = data[(h - 1 - y) * row ..][0..row];
    var i: usize = 0;
    while (i < row) : (i += 1) {
      const t = a[i];
      a[i] = b[i];
      b[i] = t;
    }
  }
}

// ── K builders ─────────────────────────────────────────────────────────────────

const IMG_KEYS = [_][*:0]const u8{ "width", "height", "comp", "data" };

/// Build the `width`height`comp`data ! (…) image dict from an 8-bit buffer and
/// free the image. `data` becomes an I vector (samples widened to i32).
pub fn imageDict(img: *Image) ?k.K {
  defer img.deinit();
  const n = img.w * img.h * img.comp;
  const dv = k.KI(n) orelse return null;
  if (k.ip(dv)) |p| for (0..n) |i| {
    p[i] = img.data[i];
  };
  const rep: usize = if (img.src_comp != 0) img.src_comp else img.comp;
  const vals = [_]?k.K{
    k.ki(@intCast(img.w)),
    k.ki(@intCast(img.h)),
    k.ki(@intCast(rep)),
    dv,
  };
  return k.dict(&IMG_KEYS, &vals);
}

/// Build the image dict from a 16-bit buffer (samples 0..65535 → I vector).
pub fn imageDict16(alloc: Alloc, w: usize, h: usize, comp: usize, src_comp: usize, data: []u16) ?k.K {
  defer alloc.free(data);
  const n = w * h * comp;
  const dv = k.KI(n) orelse return null;
  if (k.ip(dv)) |p| for (0..n) |i| {
    p[i] = data[i];
  };
  const rep: usize = if (src_comp != 0) src_comp else comp;
  const vals = [_]?k.K{ k.ki(@intCast(w)), k.ki(@intCast(h)), k.ki(@intCast(rep)), dv };
  return k.dict(&IMG_KEYS, &vals);
}

/// Build the image dict from a float buffer (HDR → F vector).
pub fn imageDictF(alloc: Alloc, w: usize, h: usize, comp: usize, data: []f32) ?k.K {
  defer alloc.free(data);
  const n = w * h * comp;
  const dv = k.KF(n) orelse return null;
  if (k.fp(dv)) |p| @memcpy(p[0..n], data[0..n]);
  const vals = [_]?k.K{ k.ki(@intCast(w)), k.ki(@intCast(h)), k.ki(@intCast(comp)), dv };
  return k.dict(&IMG_KEYS, &vals);
}

// ── file I/O over a K path (shared by every ext) ───────────────────────────────

/// Read the whole file named by a C-vector path K value into a heap slice.
pub fn readFileK(alloc: Alloc, path_k: ?k.K) ?[]u8 {
  const cp = k.cp(path_k) orelse return null;
  const n: usize = @intCast(@max(0, k.kn(path_k)));
  if (n == 0) return null;
  const io = std.Io.Threaded.global_single_threaded.io();
  return std.Io.Dir.cwd().readFileAlloc(io, cp[0..n], alloc, std.Io.Limit.limited(512 << 20)) catch null;
}

/// Write `bytes` to the file named by a C-vector path K value.
pub fn writeFileK(path_k: ?k.K, bytes: []const u8) bool {
  const cp = k.cp(path_k) orelse return false;
  const n: usize = @intCast(@max(0, k.kn(path_k)));
  if (n == 0) return false;
  const io = std.Io.Threaded.global_single_threaded.io();
  var f = std.Io.Dir.cwd().createFile(io, cp[0..n], .{}) catch return false;
  defer f.close(io);
  f.writeStreamingAll(io, bytes) catch return false;
  return true;
}

/// Extract w,h,comp,pixels (clamped 0..255) from a `(path;w;h;comp;data_I)`
/// write-arg list. Returns the pixel buffer (caller frees) plus dims, or null.
pub const WriteArgs = struct { path_k: ?k.K, w: usize, h: usize, comp: usize, pixels: []u8, alloc: Alloc };

pub fn parseWriteArgs(alloc: Alloc, arg_k: ?k.K) ?WriteArgs {
  if (k.kn(arg_k) < 5) return null;
  const path_k = k.listGet(arg_k, 0);
  const w_k = k.listGet(arg_k, 1);
  defer k.unref(w_k);
  const h_k = k.listGet(arg_k, 2);
  defer k.unref(h_k);
  const comp_k = k.listGet(arg_k, 3);
  defer k.unref(comp_k);
  const data_k = k.listGet(arg_k, 4);
  defer k.unref(data_k);
  const w: usize = @intCast(@max(0, k.kival(w_k)));
  const h: usize = @intCast(@max(0, k.kival(h_k)));
  const comp: usize = @intCast(@max(0, k.kival(comp_k)));
  const want = w * h * comp;
  if (want == 0 or @as(usize, @intCast(@max(0, k.kn(data_k)))) < want) {
    k.unref(path_k);
    return null;
  }
  const dp = k.ip(data_k) orelse {
    k.unref(path_k);
    return null;
  };
  const pixels = alloc.alloc(u8, want) catch {
    k.unref(path_k);
    return null;
  };
  for (0..want) |i| pixels[i] = @intCast(std.math.clamp(dp[i], 0, 255));
  return .{ .path_k = path_k, .w = w, .h = h, .comp = comp, .pixels = pixels, .alloc = alloc };
}
