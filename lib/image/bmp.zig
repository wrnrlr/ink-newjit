/// BMP decode + encode, ported from stb_image's public-domain BMP reader
/// (non-RLE; 1/4/8-bit palette, 16/24/32-bit direct or BI_BITFIELDS) plus a
/// 24/32-bit bottom-up writer.
///
///   decode(alloc, file)                 → common.Image (3 or 4 channels, 8-bit)
///   encode(alloc, w, h, comp, pixels)   → owned []u8 (a valid .bmp file)
///
/// The extension also uses `readStruct`/`writeStruct`/`compressionName` to expose
/// the raw file layout (magic + file header + DIB + masks + palette + raw pixel
/// bytes) as an ink dict, so array code can pick apart or rebuild a BMP directly.

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const common = @import("common.zig");

const Alloc = std.mem.Allocator;
const Error = common.Error;
const Image = common.Image;

// ── structural read (raw file layout, no pixel decode) ─────────────────────────

/// BMP compression code (BI_*) → ink symbol name. Codes are not contiguous
/// (0..6 then 11..13), hence a switch rather than an index.
pub fn compressionName(c: u32) [*:0]const u8 {
  return switch (c) {
    0 => "rgb",
    1 => "rle8",
    2 => "rle4",
    3 => "bitfields",
    4 => "jpeg",
    5 => "png",
    6 => "alphabitfields",
    11 => "cmyk",
    12 => "cmykrle8",
    13 => "cmykrle4",
    else => "unknown",
  };
}

/// The whole BMP file taken apart. Slices alias the caller's file buffer.
pub const Struct = struct {
  file_size: u32,
  reserved: u32,
  offset: u32,
  dib_size: u32,
  width: i32,
  height: i32,
  planes: u16,
  depth: u16,
  compression: u32,
  image_size: u32,
  xppm: i32,
  yppm: i32,
  colors: u32,
  important: u32,
  mask_r: u32 = 0,
  mask_g: u32 = 0,
  mask_b: u32 = 0,
  mask_a: u32 = 0,
  has_masks: bool = false,
  pal_count: usize = 0,
  pal_stride: usize = 4, // 4 for INFO+, 3 for CORE
  palette: []const u8 = &.{}, // raw palette bytes as stored (BGR[A])
  pixels: []const u8 = &.{}, // raw pixel array from `offset` to EOF
};

pub fn readStruct(file: []const u8) Error!Struct {
  var r = Reader.init(file);
  if (r.get8() != 'B' or r.get8() != 'M') return Error.Corrupt;
  var s: Struct = undefined;
  s.file_size = r.get32le();
  const res1 = r.get16le();
  const res2 = r.get16le();
  s.reserved = res1 | (res2 << 16);
  s.offset = r.get32le();
  s.dib_size = r.get32le();

  var extra_masks: usize = 0;
  s.has_masks = false;
  s.mask_r = 0;
  s.mask_g = 0;
  s.mask_b = 0;
  s.mask_a = 0;
  if (s.dib_size == 12) { // BITMAPCOREHEADER
    s.width = @intCast(r.get16le());
    s.height = @intCast(r.get16le());
    s.planes = @intCast(r.get16le());
    s.depth = @intCast(r.get16le());
    s.compression = 0;
    s.image_size = 0;
    s.xppm = 0;
    s.yppm = 0;
    s.colors = 0;
    s.important = 0;
    s.pal_stride = 3;
  } else {
    if (s.dib_size != 40 and s.dib_size != 52 and s.dib_size != 56 and s.dib_size != 108 and s.dib_size != 124) return Error.Unsupported;
    s.width = @bitCast(r.get32le());
    s.height = @bitCast(r.get32le());
    s.planes = @intCast(r.get16le());
    s.depth = @intCast(r.get16le());
    s.compression = r.get32le();
    s.image_size = r.get32le();
    s.xppm = @bitCast(r.get32le());
    s.yppm = @bitCast(r.get32le());
    s.colors = r.get32le();
    s.important = r.get32le();
    s.pal_stride = 4;
    if (s.dib_size == 40 and (s.compression == 3 or s.compression == 6)) {
      s.mask_r = r.get32le();
      s.mask_g = r.get32le();
      s.mask_b = r.get32le();
      extra_masks = 12;
      if (s.compression == 6) {
        s.mask_a = r.get32le();
        extra_masks = 16;
      }
      s.has_masks = true;
    } else if (s.dib_size >= 52) {
      s.mask_r = r.get32le();
      s.mask_g = r.get32le();
      s.mask_b = r.get32le();
      if (s.dib_size >= 56) s.mask_a = r.get32le();
      s.has_masks = true;
    }
  }

  const header_end: usize = 14 + s.dib_size + extra_masks;
  if (header_end > file.len) return Error.Corrupt;

  // palette (indexed images only)
  if (s.depth <= 8) {
    var cnt: usize = if (s.colors != 0) s.colors else (@as(usize, 1) << @intCast(s.depth));
    const avail = (@as(usize, s.offset) -| header_end) / s.pal_stride;
    if (avail < cnt) cnt = avail;
    s.pal_count = cnt;
    const pbytes = cnt * s.pal_stride;
    s.palette = if (header_end + pbytes <= file.len) file[header_end .. header_end + pbytes] else &.{};
  } else {
    s.pal_count = 0;
    s.palette = &.{};
  }

  s.pixels = if (s.offset <= file.len) file[@min(s.offset, file.len)..] else &.{};
  return s;
}

/// Serialize a BMP from raw parts: always emits a BITMAPFILEHEADER +
/// BITMAPINFOHEADER (40), plus BI_BITFIELDS masks when `compression` is 3/6, a
/// BGRA palette (from RGBA `palette_rgba`), then `pixels` verbatim. Round-trips
/// pixel data losslessly (the header is normalized to v3, not byte-preserved).
pub fn writeStruct(
  alloc: Alloc,
  width: i32,
  height: i32,
  depth: u16,
  compression: u32,
  masks: [4]u32,
  palette_rgba: []const u8, // n*4 RGBA
  pixels: []const u8,
) Error![]u8 {
  const pal_count = palette_rgba.len / 4;
  const mask_bytes: usize = if (compression == 6) 16 else if (compression == 3) 12 else 0;
  const pal_bytes = pal_count * 4;
  const offset: usize = 14 + 40 + mask_bytes + pal_bytes;
  const total = offset + pixels.len;

  const out = alloc.alloc(u8, total) catch return Error.OutOfMemory;
  errdefer alloc.free(out);
  @memset(out, 0);
  out[0] = 'B';
  out[1] = 'M';
  std.mem.writeInt(u32, out[2..6], @intCast(total), .little);
  std.mem.writeInt(u32, out[10..14], @intCast(offset), .little);
  std.mem.writeInt(u32, out[14..18], 40, .little); // dib size
  std.mem.writeInt(i32, out[18..22], width, .little);
  std.mem.writeInt(i32, out[22..26], height, .little);
  std.mem.writeInt(u16, out[26..28], 1, .little); // planes
  std.mem.writeInt(u16, out[28..30], depth, .little);
  std.mem.writeInt(u32, out[30..34], compression, .little);
  std.mem.writeInt(u32, out[34..38], @intCast(pixels.len), .little);
  std.mem.writeInt(u32, out[46..50], @intCast(pal_count), .little);

  var pos: usize = 54;
  if (mask_bytes >= 12) {
    std.mem.writeInt(u32, out[pos..][0..4], masks[0], .little);
    std.mem.writeInt(u32, out[pos + 4 ..][0..4], masks[1], .little);
    std.mem.writeInt(u32, out[pos + 8 ..][0..4], masks[2], .little);
    if (mask_bytes == 16) std.mem.writeInt(u32, out[pos + 12 ..][0..4], masks[3], .little);
    pos += mask_bytes;
  }
  var i: usize = 0;
  while (i < pal_count) : (i += 1) {
    out[pos + 0] = palette_rgba[i * 4 + 2]; // B
    out[pos + 1] = palette_rgba[i * 4 + 1]; // G
    out[pos + 2] = palette_rgba[i * 4 + 0]; // R
    out[pos + 3] = palette_rgba[i * 4 + 3]; // A
    pos += 4;
  }
  @memcpy(out[offset..], pixels);
  return out;
}

pub fn isBmp(file: []const u8) bool {
  if (file.len < 18) return false;
  if (file[0] != 'B' or file[1] != 'M') return false;
  const sz = std.mem.readInt(u32, file[14..18], .little);
  return sz == 12 or sz == 40 or sz == 56 or sz == 108 or sz == 124;
}

fn highBit(z0: u32) i32 {
  var z = z0;
  if (z == 0) return -1;
  var n: i32 = 0;
  if (z >= 0x10000) {
    n += 16;
    z >>= 16;
  }
  if (z >= 0x100) {
    n += 8;
    z >>= 8;
  }
  if (z >= 0x10) {
    n += 4;
    z >>= 4;
  }
  if (z >= 0x4) {
    n += 2;
    z >>= 2;
  }
  if (z >= 0x2) n += 1;
  return n;
}

fn bitCount(a0: u32) u32 {
  var a = a0;
  a = (a & 0x55555555) + ((a >> 1) & 0x55555555);
  a = (a & 0x33333333) + ((a >> 2) & 0x33333333);
  a = (a + (a >> 4)) & 0x0f0f0f0f;
  a = a + (a >> 8);
  a = a + (a >> 16);
  return a & 0xff;
}

fn shiftSigned(v0: u32, shift: i32, bits: u32) i32 {
  const mul_table = [9]u32{ 0, 0xff, 0x55, 0x49, 0x11, 0x21, 0x41, 0x81, 0x01 };
  const shift_table = [9]u32{ 0, 0, 0, 1, 0, 2, 4, 6, 0 };
  var v = v0;
  if (shift < 0) v <<= @intCast(-shift) else v >>= @intCast(shift);
  if (v >= 256) v = 255;
  v >>= @intCast(8 - bits);
  return @intCast((v *% mul_table[bits]) >> @intCast(shift_table[bits]));
}

const Header = struct {
  bpp: u32,
  offset: u32,
  hsz: u32,
  mr: u32 = 0,
  mg: u32 = 0,
  mb: u32 = 0,
  ma: u32 = 0,
  extra_read: u32 = 14,
};

fn setMaskDefaults(info: *Header, compress: u32) void {
  if (compress == 3) return;
  if (compress == 0) {
    if (info.bpp == 16) {
      info.mr = 31 << 10;
      info.mg = 31 << 5;
      info.mb = 31 << 0;
    } else if (info.bpp == 32) {
      info.mr = 0xff << 16;
      info.mg = 0xff << 8;
      info.mb = 0xff << 0;
      info.ma = 0xff << 24;
    }
  }
}

fn parseHeader(r: *Reader, w: *usize, h: *isize) Error!Header {
  if (r.get8() != 'B' or r.get8() != 'M') return Error.Corrupt;
  _ = r.get32le(); // filesize
  _ = r.get16le();
  _ = r.get16le();
  var info = Header{ .bpp = 0, .offset = r.get32le(), .hsz = r.get32le() };
  const hsz = info.hsz;
  if (hsz != 12 and hsz != 40 and hsz != 56 and hsz != 108 and hsz != 124) return Error.Unsupported;
  if (hsz == 12) {
    w.* = r.get16le();
    h.* = @intCast(@as(i16, @bitCast(@as(u16, @intCast(r.get16le())))));
  } else {
    w.* = r.get32le();
    h.* = @as(i32, @bitCast(r.get32le()));
  }
  if (r.get16le() != 1) return Error.Corrupt;
  info.bpp = r.get16le();
  if (hsz != 12) {
    const compress = r.get32le();
    if (compress == 1 or compress == 2) return Error.Unsupported; // RLE
    if (compress >= 4) return Error.Unsupported;
    if (compress == 3 and info.bpp != 16 and info.bpp != 32) return Error.Corrupt;
    _ = r.get32le(); // sizeof image
    _ = r.get32le(); // hres
    _ = r.get32le(); // vres
    _ = r.get32le(); // colors used
    _ = r.get32le(); // important
    if (hsz == 40 or hsz == 56) {
      if (hsz == 56) {
        _ = r.get32le();
        _ = r.get32le();
        _ = r.get32le();
        _ = r.get32le();
      }
      if (info.bpp == 16 or info.bpp == 32) {
        if (compress == 0) {
          setMaskDefaults(&info, compress);
        } else if (compress == 3) {
          info.mr = r.get32le();
          info.mg = r.get32le();
          info.mb = r.get32le();
          info.extra_read += 12;
          if (info.mr == info.mg and info.mg == info.mb) return Error.Corrupt;
        } else return Error.Corrupt;
      }
    } else {
      // V4/V5
      info.mr = r.get32le();
      info.mg = r.get32le();
      info.mb = r.get32le();
      info.ma = r.get32le();
      if (compress != 3) setMaskDefaults(&info, compress);
      _ = r.get32le(); // color space
      var i: usize = 0;
      while (i < 12) : (i += 1) _ = r.get32le();
      if (hsz == 124) {
        _ = r.get32le();
        _ = r.get32le();
        _ = r.get32le();
        _ = r.get32le();
      }
    }
  }
  return info;
}

pub fn decode(alloc: Alloc, file: []const u8) Error!Image {
  var r = Reader.init(file);
  var w: usize = 0;
  var hsig: isize = 0;
  const info = try parseHeader(&r, &w, &hsig);
  const flip = hsig > 0;
  const h: usize = @intCast(if (hsig < 0) -hsig else hsig);
  if (w > common.MAX_DIM or h > common.MAX_DIM) return Error.TooLarge;

  var mr = info.mr;
  var mg = info.mg;
  var mb = info.mb;
  var ma = info.ma;
  var all_a: u32 = 255;

  var psize: usize = 0;
  if (info.hsz == 12) {
    if (info.bpp < 24) psize = (info.offset - info.extra_read - 24) / 3;
  } else {
    if (info.bpp < 16) psize = (info.offset - info.extra_read - info.hsz) >> 2;
  }
  if (psize == 0) {
    const consumed: usize = r.pos;
    if (info.offset >= consumed) r.skip(info.offset - consumed);
  }

  const src_comp: usize = if (info.bpp == 24 and ma == 0xff000000) 3 else (if (ma != 0) 4 else 3);
  const target: usize = src_comp;

  const out = alloc.alloc(u8, try common.checkedSize(target, w, h)) catch return Error.OutOfMemory;
  errdefer alloc.free(out);

  if (info.bpp < 16) {
    var pal: [256][4]u8 = undefined;
    if (psize == 0 or psize > 256) return Error.Corrupt;
    var i: usize = 0;
    while (i < psize) : (i += 1) {
      pal[i][2] = r.get8();
      pal[i][1] = r.get8();
      pal[i][0] = r.get8();
      if (info.hsz != 12) _ = r.get8();
      pal[i][3] = 255;
    }
    const width_bytes = switch (info.bpp) {
      1 => (w + 7) >> 3,
      4 => (w + 1) >> 1,
      8 => w,
      else => return Error.Corrupt,
    };
    const pad = (0 -% width_bytes) & 3;
    var z: usize = 0;
    var j: usize = 0;
    while (j < h) : (j += 1) {
      if (info.bpp == 1) {
        var bit_offset: i32 = 7;
        var v = r.get8();
        i = 0;
        while (i < w) : (i += 1) {
          const color = (v >> @intCast(bit_offset)) & 1;
          out[z] = pal[color][0];
          out[z + 1] = pal[color][1];
          out[z + 2] = pal[color][2];
          z += 3;
          if (target == 4) {
            out[z] = 255;
            z += 1;
          }
          if (i + 1 == w) break;
          bit_offset -= 1;
          if (bit_offset < 0) {
            bit_offset = 7;
            v = r.get8();
          }
        }
      } else {
        i = 0;
        while (i < w) : (i += 2) {
          var v = r.get8();
          var v2: u8 = 0;
          if (info.bpp == 4) {
            v2 = v & 15;
            v >>= 4;
          }
          out[z] = pal[v][0];
          out[z + 1] = pal[v][1];
          out[z + 2] = pal[v][2];
          z += 3;
          if (target == 4) {
            out[z] = 255;
            z += 1;
          }
          if (i + 1 == w) break;
          v = if (info.bpp == 8) r.get8() else v2;
          out[z] = pal[v][0];
          out[z + 1] = pal[v][1];
          out[z + 2] = pal[v][2];
          z += 3;
          if (target == 4) {
            out[z] = 255;
            z += 1;
          }
        }
      }
      r.skip(pad);
    }
  } else {
    var easy: u8 = 0;
    const width_bytes: usize = switch (info.bpp) {
      24 => 3 * w,
      16 => 2 * w,
      else => 0,
    };
    const pad = (0 -% width_bytes) & 3;
    if (info.bpp == 24) {
      easy = 1;
    } else if (info.bpp == 32) {
      if (mb == 0xff and mg == 0xff00 and mr == 0x00ff0000 and ma == 0xff000000) easy = 2;
    }
    var rshift: i32 = 0;
    var gshift: i32 = 0;
    var bshift: i32 = 0;
    var ashift: i32 = 0;
    var rcnt: u32 = 0;
    var gcnt: u32 = 0;
    var bcnt: u32 = 0;
    var acnt: u32 = 0;
    if (easy == 0) {
      if (mr == 0 or mg == 0 or mb == 0) return Error.Corrupt;
      rshift = highBit(mr) - 7;
      rcnt = bitCount(mr);
      gshift = highBit(mg) - 7;
      gcnt = bitCount(mg);
      bshift = highBit(mb) - 7;
      bcnt = bitCount(mb);
      ashift = highBit(ma) - 7;
      acnt = bitCount(ma);
      if (rcnt > 8 or gcnt > 8 or bcnt > 8 or acnt > 8) return Error.Corrupt;
    }
    var z: usize = 0;
    var j: usize = 0;
    while (j < h) : (j += 1) {
      if (easy != 0) {
        var i: usize = 0;
        while (i < w) : (i += 1) {
          out[z + 2] = r.get8();
          out[z + 1] = r.get8();
          out[z + 0] = r.get8();
          z += 3;
          const a: u8 = if (easy == 2) r.get8() else 255;
          all_a |= a;
          if (target == 4) {
            out[z] = a;
            z += 1;
          }
        }
      } else {
        var i: usize = 0;
        while (i < w) : (i += 1) {
          const v: u32 = if (info.bpp == 16) r.get16le() else r.get32le();
          out[z] = @intCast(shiftSigned(v & mr, rshift, rcnt) & 0xff);
          z += 1;
          out[z] = @intCast(shiftSigned(v & mg, gshift, gcnt) & 0xff);
          z += 1;
          out[z] = @intCast(shiftSigned(v & mb, bshift, bcnt) & 0xff);
          z += 1;
          const a: u32 = if (ma != 0) @intCast(shiftSigned(v & ma, ashift, acnt)) else 255;
          all_a |= a;
          if (target == 4) {
            out[z] = @intCast(a & 0xff);
            z += 1;
          }
        }
      }
      r.skip(pad);
    }
    _ = &mr;
    _ = &mg;
    _ = &mb;
    _ = &ma;
  }

  // all-zero alpha ⇒ opaque
  if (target == 4 and all_a == 0) {
    var i: usize = 3;
    while (i < target * w * h) : (i += 4) out[i] = 255;
  }
  if (flip) common.flipVertical(out, w, h, target);

  return .{ .w = w, .h = h, .comp = target, .src_comp = src_comp, .data = out, .alloc = alloc };
}

// ── encode (24- or 32-bit bottom-up, no compression) ───────────────────────────

pub fn encode(alloc: Alloc, w: usize, h: usize, comp: usize, pixels: []const u8) Error![]u8 {
  // Emit 24-bit (BGR) for opaque sources, 32-bit (BGRA) when an alpha channel
  // is present. Grayscale sources expand to RGB.
  const has_alpha = comp == 2 or comp == 4;
  const obpp: usize = if (has_alpha) 4 else 3;
  const row = w * obpp;
  const pad: usize = if (has_alpha) 0 else ((0 -% row) & 3);
  const stride = row + pad;
  const header = if (has_alpha) @as(usize, 122) else 54;
  const total = header + stride * h;

  const out = alloc.alloc(u8, total) catch return Error.OutOfMemory;
  errdefer alloc.free(out);
  @memset(out, 0);
  out[0] = 'B';
  out[1] = 'M';
  std.mem.writeInt(u32, out[2..6], @intCast(total), .little);
  std.mem.writeInt(u32, out[10..14], @intCast(header), .little);
  const hsz: u32 = if (has_alpha) 108 else 40;
  std.mem.writeInt(u32, out[14..18], hsz, .little);
  std.mem.writeInt(i32, out[18..22], @intCast(w), .little);
  std.mem.writeInt(i32, out[22..26], @intCast(h), .little);
  std.mem.writeInt(u16, out[26..28], 1, .little);
  std.mem.writeInt(u16, out[28..30], @intCast(obpp * 8), .little);
  if (has_alpha) {
    std.mem.writeInt(u32, out[30..34], 3, .little); // BI_BITFIELDS
    std.mem.writeInt(u32, out[54..58], 0x00ff0000, .little); // R
    std.mem.writeInt(u32, out[58..62], 0x0000ff00, .little); // G
    std.mem.writeInt(u32, out[62..66], 0x000000ff, .little); // B
    std.mem.writeInt(u32, out[66..70], 0xff000000, .little); // A
  }

  const g = struct {
    fn sample(px: []const u8, base: usize, c: usize, chan: usize) u8 {
      // chan: 0=r 1=g 2=b 3=a; source comp ∈ {1,2,3,4}
      return switch (c) {
        1 => if (chan == 3) 255 else px[base],
        2 => if (chan == 3) px[base + 1] else px[base],
        3, 4 => if (chan == 3) (if (c == 4) px[base + 3] else 255) else px[base + chan],
        else => 0,
      };
    }
  };

  var y: usize = 0;
  while (y < h) : (y += 1) {
    const srow = (h - 1 - y) * w * comp; // bottom-up
    var drow = header + y * stride;
    var x: usize = 0;
    while (x < w) : (x += 1) {
      const base = srow + x * comp;
      out[drow + 0] = g.sample(pixels, base, comp, 2); // B
      out[drow + 1] = g.sample(pixels, base, comp, 1); // G
      out[drow + 2] = g.sample(pixels, base, comp, 0); // R
      if (has_alpha) {
        out[drow + 3] = g.sample(pixels, base, comp, 3); // A
        drow += 4;
      } else drow += 3;
    }
  }
  return out;
}
