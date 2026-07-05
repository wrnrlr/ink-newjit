/// TGA (Truevision Targa) decode, ported from stb_image's public-domain TGA
/// reader: 8-bit grey, 15/16/24/32-bit direct, and 8/16-bit colormapped, each
/// with optional RLE. Returns an 8-bit common.Image.

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const common = @import("common.zig");

const Alloc = std.mem.Allocator;
const Error = common.Error;
const Image = common.Image;

fn getComp(bpp: u32, is_grey: bool, is_rgb16: *bool) u32 {
  is_rgb16.* = false;
  return switch (bpp) {
    8 => 1,
    16 => if (is_grey) 2 else blk: {
      is_rgb16.* = true;
      break :blk 3;
    },
    15 => blk: {
      is_rgb16.* = true;
      break :blk 3;
    },
    24 => 3,
    32 => 4,
    else => 0,
  };
}

fn readRgb16(r: *Reader, out: []u8) void {
  const px = r.get16le();
  const mask: u32 = 31;
  const rr = (px >> 10) & mask;
  const gg = (px >> 5) & mask;
  const bb = px & mask;
  out[0] = @intCast((rr * 255) / 31);
  out[1] = @intCast((gg * 255) / 31);
  out[2] = @intCast((bb * 255) / 31);
}

/// A quick validity check for format sniffing (mirrors stbi__tga_test loosely).
pub fn isTga(file: []const u8) bool {
  if (file.len < 18) return false;
  const cmap = file[1];
  if (cmap > 1) return false;
  const it = file[2];
  const t = it & ~@as(u8, 8);
  if (cmap == 1) {
    if (it != 1 and it != 9) return false;
  } else {
    if (t != 2 and t != 3) return false;
  }
  const bpp = file[16];
  return bpp == 8 or bpp == 15 or bpp == 16 or bpp == 24 or bpp == 32;
}

pub fn decode(alloc: Alloc, file: []const u8) Error!Image {
  var r = Reader.init(file);
  const offset = r.get8();
  const indexed = r.get8();
  var image_type = r.get8();
  const palette_start = r.get16le();
  const palette_len = r.get16le();
  const palette_bits = r.get8();
  _ = r.get16le(); // x origin
  _ = r.get16le(); // y origin
  const w: usize = r.get16le();
  const h: usize = r.get16le();
  const bpp = r.get8();
  var inverted = r.get8();

  if (w == 0 or h == 0) return Error.Corrupt;
  if (w > common.MAX_DIM or h > common.MAX_DIM) return Error.TooLarge;

  var is_rle = false;
  if (image_type >= 8) {
    image_type -= 8;
    is_rle = true;
  }
  inverted = 1 - ((inverted >> 5) & 1);

  var rgb16 = false;
  const comp: usize = if (indexed != 0)
    getComp(palette_bits, false, &rgb16)
  else
    getComp(bpp, image_type == 3, &rgb16);
  if (comp == 0) return Error.Unsupported;

  const data = alloc.alloc(u8, try common.checkedSize(w, h, comp)) catch return Error.OutOfMemory;
  errdefer alloc.free(data);

  r.skip(offset);

  if (indexed == 0 and !is_rle and !rgb16) {
    var i: usize = 0;
    while (i < h) : (i += 1) {
      const row = if (inverted != 0) h - i - 1 else i;
      _ = r.getn(data[row * w * comp ..][0 .. w * comp]);
    }
  } else {
    var palette: []u8 = &.{};
    defer if (palette.len > 0) alloc.free(palette);
    if (indexed != 0) {
      if (palette_len == 0) return Error.Corrupt;
      r.skip(palette_start);
      palette = alloc.alloc(u8, palette_len * comp) catch return Error.OutOfMemory;
      if (rgb16) {
        var p: usize = 0;
        while (p < palette_len) : (p += 1) readRgb16(&r, palette[p * comp ..]);
      } else {
        _ = r.getn(palette);
      }
    }

    var raw = [4]u8{ 0, 0, 0, 0 };
    var rle_count: usize = 0;
    var rle_repeating = false;
    var read_next = true;
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
      if (is_rle) {
        if (rle_count == 0) {
          const cmd = r.get8();
          rle_count = 1 + (cmd & 127);
          rle_repeating = (cmd >> 7) != 0;
          read_next = true;
        } else if (!rle_repeating) {
          read_next = true;
        }
      } else read_next = true;

      if (read_next) {
        if (indexed != 0) {
          var idx: usize = if (bpp == 8) r.get8() else r.get16le();
          if (idx >= palette_len) idx = 0;
          idx *= comp;
          var j: usize = 0;
          while (j < comp) : (j += 1) raw[j] = palette[idx + j];
        } else if (rgb16) {
          readRgb16(&r, raw[0..]);
        } else {
          var j: usize = 0;
          while (j < comp) : (j += 1) raw[j] = r.get8();
        }
        read_next = false;
      }
      var j: usize = 0;
      while (j < comp) : (j += 1) data[i * comp + j] = raw[j];
      rle_count -= 1;
    }

    if (inverted != 0) {
      var jrow: usize = 0;
      while (jrow * 2 < h) : (jrow += 1) {
        var a = jrow * w * comp;
        var b = (h - 1 - jrow) * w * comp;
        var kk: usize = w * comp;
        while (kk > 0) : (kk -= 1) {
          const t = data[a];
          data[a] = data[b];
          data[b] = t;
          a += 1;
          b += 1;
        }
      }
    }
  }

  // BGR → RGB (rgb16 already emits RGB order)
  if (comp >= 3 and !rgb16) {
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
      const t = data[i * comp];
      data[i * comp] = data[i * comp + 2];
      data[i * comp + 2] = t;
    }
  }

  return .{ .w = w, .h = h, .comp = comp, .src_comp = comp, .data = data, .alloc = alloc };
}
