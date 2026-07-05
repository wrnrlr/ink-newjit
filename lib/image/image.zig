/// Format-agnostic helpers for libimage: magic-byte sniffing and bilinear
/// resampling. The per-format decoders live in their own libraries; this one
/// carries only what `image.read` (dispatch) and `image.scale` need.

const std = @import("std");
const common = @import("common.zig");
const png = @import("png.zig");
const bmp = @import("bmp.zig");
const gif = @import("gif.zig");
const tga = @import("tga.zig");
const hdr = @import("hdr.zig");
const pic = @import("pic.zig");

const Alloc = std.mem.Allocator;
const Error = common.Error;

pub const Format = enum { png, jpeg, gif, bmp, hdr, pic, tga, unknown };

fn isJpeg(f: []const u8) bool {
  return f.len >= 3 and f[0] == 0xFF and f[1] == 0xD8 and f[2] == 0xFF;
}

/// Identify a format from the leading bytes of a file (same order stb tries).
pub fn sniff(f: []const u8) Format {
  if (png.isPng(f)) return .png;
  if (bmp.isBmp(f)) return .bmp;
  if (gif.isGif(f)) return .gif;
  if (pic.isPic(f)) return .pic;
  if (isJpeg(f)) return .jpeg;
  if (hdr.isHdr(f)) return .hdr;
  if (tga.isTga(f)) return .tga; // crappy test — last, like stb
  return .unknown;
}

/// Bilinear resample an interleaved 8/16-bit integer image (samples held in i32)
/// from w×h to nw×nh, preserving `comp` channels. Returns an owned i32 buffer.
pub fn scale(alloc: Alloc, w: usize, h: usize, comp: usize, src: []const i32, nw: usize, nh: usize) Error![]i32 {
  const out = alloc.alloc(i32, try common.checkedSize(nw * nh, comp, 1)) catch return Error.OutOfMemory;
  errdefer alloc.free(out);
  if (nw == 0 or nh == 0 or w == 0 or h == 0) return out;
  const fw: f32 = @floatFromInt(w);
  const fh: f32 = @floatFromInt(h);
  const fnw: f32 = @floatFromInt(nw);
  const fnh: f32 = @floatFromInt(nh);

  var y: usize = 0;
  while (y < nh) : (y += 1) {
    var sy = (@as(f32, @floatFromInt(y)) + 0.5) * fh / fnh - 0.5;
    if (sy < 0) sy = 0;
    const y0f = @floor(sy);
    const y0: usize = @intFromFloat(y0f);
    const y1: usize = @min(y0 + 1, h - 1);
    const wy = sy - y0f;

    var x: usize = 0;
    while (x < nw) : (x += 1) {
      var sx = (@as(f32, @floatFromInt(x)) + 0.5) * fw / fnw - 0.5;
      if (sx < 0) sx = 0;
      const x0f = @floor(sx);
      const x0: usize = @intFromFloat(x0f);
      const x1: usize = @min(x0 + 1, w - 1);
      const wx = sx - x0f;

      const p00 = (y0 * w + x0) * comp;
      const p01 = (y0 * w + x1) * comp;
      const p10 = (y1 * w + x0) * comp;
      const p11 = (y1 * w + x1) * comp;
      const dbase = (y * nw + x) * comp;
      var c: usize = 0;
      while (c < comp) : (c += 1) {
        const a: f32 = @floatFromInt(src[p00 + c]);
        const b: f32 = @floatFromInt(src[p01 + c]);
        const cc: f32 = @floatFromInt(src[p10 + c]);
        const d: f32 = @floatFromInt(src[p11 + c]);
        const top = a + (b - a) * wx;
        const bot = cc + (d - cc) * wx;
        out[dbase + c] = @intFromFloat(@round(top + (bot - top) * wy));
      }
    }
  }
  return out;
}
