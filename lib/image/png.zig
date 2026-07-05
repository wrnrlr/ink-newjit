/// PNG decode + encode, ported from stb_image's public-domain PNG decoder
/// (1/2/4/8/16-bit, grayscale/RGB/palette, tRNS, Adam7 interlace, iPhone CgBI)
/// and a straightforward filter-none encoder built on the stored-block zlib in
/// zlib.zig.
///
///   decode(alloc, file)                 → Decoded   (native channels + bit depth)
///   info(alloc, file)                   → header struct (see png_ext.zig)
///   encode(alloc, w, h, comp, pixels)   → owned []u8 (a valid .png file)

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const common = @import("common.zig");
const zlib = @import("zlib.zig");

const Alloc = std.mem.Allocator;
const Error = common.Error;

pub const Decoded = struct {
  w: usize,
  h: usize,
  comp: usize, // channels in `data` (img_out_n)
  src_comp: usize, // channels reported to the user (img_n / palette n)
  depth: u8, // 8 or 16 (1/2/4 expand to 8)
  data: []u8, // byte buffer: w*h*comp (8-bit) or w*h*comp*2 native-u16 (16-bit)
  alloc: Alloc,

  pub fn deinit(self: *Decoded) void {
    if (self.data.len > 0) self.alloc.free(self.data);
    self.data = &.{};
  }
};

pub fn isPng(file: []const u8) bool {
  const sig = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
  return file.len >= 8 and std.mem.eql(u8, file[0..8], &sig);
}

// ── filters ────────────────────────────────────────────────────────────────────

const F_none = 0;
const F_sub = 1;
const F_up = 2;
const F_avg = 3;
const F_paeth = 4;
const F_avg_first = 5;

const first_row_filter = [5]u8{ F_none, F_sub, F_none, F_avg_first, F_sub };
const depth_scale = [9]u8{ 0, 0xff, 0x55, 0, 0x11, 0, 0, 0, 0x01 };

fn paeth(a: i32, b: i32, c: i32) i32 {
  const thresh = c * 3 - (a + b);
  const lo = if (a < b) a else b;
  const hi = if (a < b) b else a;
  const t0 = if (hi <= thresh) lo else c;
  return if (thresh <= lo) hi else t0;
}

fn alphaExpand8(dst: []u8, src: []const u8, x: usize, img_n: usize) void {
  // Process backwards so dst==src is legal.
  if (img_n == 1) {
    var i: usize = x;
    while (i > 0) {
      i -= 1;
      dst[i * 2 + 1] = 255;
      dst[i * 2 + 0] = src[i];
    }
  } else {
    var i: usize = x;
    while (i > 0) {
      i -= 1;
      dst[i * 4 + 3] = 255;
      dst[i * 4 + 2] = src[i * 3 + 2];
      dst[i * 4 + 1] = src[i * 3 + 1];
      dst[i * 4 + 0] = src[i * 3 + 0];
    }
  }
}

const Png = struct {
  alloc: Alloc,
  x: usize = 0,
  y: usize = 0,
  img_n: usize = 0,
  out_n: usize = 0,
  depth: u8 = 0,
  color: u8 = 0,
  out: []u8 = &.{},

  fn createRaw(a: *Png, raw: []const u8, out_n: usize, x: usize, y: usize) Error!void {
    const bytes: usize = if (a.depth == 16) 2 else 1;
    const stride = x * out_n * bytes;
    const img_n = a.img_n;
    var filter_bytes = img_n * bytes;
    var width = x;
    const output_bytes = out_n * bytes;

    a.out = a.alloc.alloc(u8, try common.checkedSize(x * y, output_bytes, 1)) catch return Error.OutOfMemory;

    const img_width_bytes = (img_n * x * a.depth + 7) >> 3;
    const img_len = (img_width_bytes + 1) * y;
    if (raw.len < img_len) return Error.Corrupt;

    const filter_buf = a.alloc.alloc(u8, img_width_bytes * 2) catch return Error.OutOfMemory;
    defer a.alloc.free(filter_buf);
    @memset(filter_buf, 0);

    if (a.depth < 8) {
      filter_bytes = 1;
      width = img_width_bytes;
    }

    var rp: usize = 0;
    var j: usize = 0;
    while (j < y) : (j += 1) {
      const cur = filter_buf[(j & 1) * img_width_bytes ..][0..img_width_bytes];
      const prior = filter_buf[(~j & 1) * img_width_bytes ..][0..img_width_bytes];
      const dest = a.out[stride * j ..];
      const nk = width * filter_bytes;
      var filter = raw[rp];
      rp += 1;
      if (filter > 4) return Error.Corrupt;
      if (j == 0) filter = first_row_filter[filter];

      const row = raw[rp .. rp + nk];
      switch (filter) {
        F_none => @memcpy(cur[0..nk], row),
        F_sub => {
          @memcpy(cur[0..filter_bytes], row[0..filter_bytes]);
          var kk = filter_bytes;
          while (kk < nk) : (kk += 1) cur[kk] = row[kk] +% cur[kk - filter_bytes];
        },
        F_up => {
          var kk: usize = 0;
          while (kk < nk) : (kk += 1) cur[kk] = row[kk] +% prior[kk];
        },
        F_avg => {
          var kk: usize = 0;
          while (kk < filter_bytes) : (kk += 1) cur[kk] = row[kk] +% (prior[kk] >> 1);
          while (kk < nk) : (kk += 1) {
            const s: u32 = @as(u32, prior[kk]) + cur[kk - filter_bytes];
            cur[kk] = row[kk] +% @as(u8, @intCast((s >> 1) & 0xff));
          }
        },
        F_paeth => {
          var kk: usize = 0;
          while (kk < filter_bytes) : (kk += 1) cur[kk] = row[kk] +% prior[kk];
          while (kk < nk) : (kk += 1) {
            const pv = paeth(cur[kk - filter_bytes], prior[kk], prior[kk - filter_bytes]);
            cur[kk] = row[kk] +% @as(u8, @intCast(pv & 0xff));
          }
        },
        F_avg_first => {
          @memcpy(cur[0..filter_bytes], row[0..filter_bytes]);
          var kk = filter_bytes;
          while (kk < nk) : (kk += 1) cur[kk] = row[kk] +% (cur[kk - filter_bytes] >> 1);
        },
        else => unreachable,
      }
      rp += nk;

      // expand `cur` into `dest`, inserting alpha if the source lacked it
      if (a.depth < 8) {
        const scale: u8 = if (a.color == 0) depth_scale[a.depth] else 1;
        var in: usize = 0;
        var out: usize = 0;
        var inb: u8 = 0;
        const nsmp = x * img_n;
        var i: usize = 0;
        if (a.depth == 4) {
          while (i < nsmp) : (i += 1) {
            if (i & 1 == 0) {
              inb = cur[in];
              in += 1;
            }
            dest[out] = scale *% (inb >> 4);
            out += 1;
            inb <<= 4;
          }
        } else if (a.depth == 2) {
          while (i < nsmp) : (i += 1) {
            if (i & 3 == 0) {
              inb = cur[in];
              in += 1;
            }
            dest[out] = scale *% (inb >> 6);
            out += 1;
            inb <<= 2;
          }
        } else { // depth == 1
          while (i < nsmp) : (i += 1) {
            if (i & 7 == 0) {
              inb = cur[in];
              in += 1;
            }
            dest[out] = scale *% (inb >> 7);
            out += 1;
            inb <<= 1;
          }
        }
        if (img_n != out_n) alphaExpand8(dest, dest, x, img_n);
      } else if (a.depth == 8) {
        if (img_n == out_n) {
          @memcpy(dest[0 .. x * img_n], cur[0 .. x * img_n]);
        } else {
          alphaExpand8(dest, cur, x, img_n);
        }
      } else { // depth == 16 — assemble big-endian samples to native u16
        const dest16 = std.mem.bytesAsSlice(u16, dest[0 .. x * out_n * 2]);
        if (img_n == out_n) {
          var i: usize = 0;
          while (i < x * img_n) : (i += 1) dest16[i] = (@as(u16, cur[i * 2]) << 8) | cur[i * 2 + 1];
        } else if (img_n == 1) {
          var i: usize = 0;
          while (i < x) : (i += 1) {
            dest16[i * 2] = (@as(u16, cur[i * 2]) << 8) | cur[i * 2 + 1];
            dest16[i * 2 + 1] = 0xffff;
          }
        } else { // img_n == 3
          var i: usize = 0;
          while (i < x) : (i += 1) {
            dest16[i * 4 + 0] = (@as(u16, cur[i * 6 + 0]) << 8) | cur[i * 6 + 1];
            dest16[i * 4 + 1] = (@as(u16, cur[i * 6 + 2]) << 8) | cur[i * 6 + 3];
            dest16[i * 4 + 2] = (@as(u16, cur[i * 6 + 4]) << 8) | cur[i * 6 + 5];
            dest16[i * 4 + 3] = 0xffff;
          }
        }
      }
    }
  }

  fn createImage(a: *Png, image_data: []const u8, out_n: usize, interlaced: bool) Error!void {
    const bytes: usize = if (a.depth == 16) 2 else 1;
    const out_bytes = out_n * bytes;
    if (!interlaced) return a.createRaw(image_data, out_n, a.x, a.y);

    // Adam7 de-interlace
    const final = a.alloc.alloc(u8, try common.checkedSize(a.x * a.y, out_bytes, 1)) catch return Error.OutOfMemory;
    errdefer a.alloc.free(final);
    const xorig = [7]usize{ 0, 4, 0, 2, 0, 1, 0 };
    const yorig = [7]usize{ 0, 0, 4, 0, 2, 0, 1 };
    const xspc = [7]usize{ 8, 8, 4, 4, 2, 2, 1 };
    const yspc = [7]usize{ 8, 8, 8, 4, 4, 2, 2 };
    var data = image_data;
    var p: usize = 0;
    while (p < 7) : (p += 1) {
      const x = (a.x - xorig[p] + xspc[p] - 1) / xspc[p];
      const y = (a.y - yorig[p] + yspc[p] - 1) / yspc[p];
      if (x != 0 and y != 0) {
        const img_len = ((a.img_n * x * a.depth + 7) >> 3) + 1;
        try a.createRaw(data, out_n, x, y);
        defer a.alloc.free(a.out);
        var j: usize = 0;
        while (j < y) : (j += 1) {
          var i: usize = 0;
          while (i < x) : (i += 1) {
            const out_y = j * yspc[p] + yorig[p];
            const out_x = i * xspc[p] + xorig[p];
            @memcpy(
              final[out_y * a.x * out_bytes + out_x * out_bytes ..][0..out_bytes],
              a.out[(j * x + i) * out_bytes ..][0..out_bytes],
            );
          }
        }
        data = data[img_len * y ..];
      }
    }
    a.out = final;
  }
};

fn computeTransparency(a: *Png, tc: [3]u8, out_n: usize) void {
  const count = a.x * a.y;
  var p = a.out;
  if (out_n == 2) {
    var i: usize = 0;
    while (i < count) : (i += 1) {
      p[1] = if (p[0] == tc[0]) 0 else 255;
      p = p[2..];
    }
  } else {
    var i: usize = 0;
    while (i < count) : (i += 1) {
      if (p[0] == tc[0] and p[1] == tc[1] and p[2] == tc[2]) p[3] = 0;
      p = p[4..];
    }
  }
}

fn computeTransparency16(a: *Png, tc: [3]u16, out_n: usize) void {
  const count = a.x * a.y;
  const p16 = std.mem.bytesAsSlice(u16, a.out);
  if (out_n == 2) {
    var i: usize = 0;
    while (i < count) : (i += 1) {
      p16[i * 2 + 1] = if (p16[i * 2] == tc[0]) 0 else 0xffff;
    }
  } else {
    var i: usize = 0;
    while (i < count) : (i += 1) {
      if (p16[i * 4] == tc[0] and p16[i * 4 + 1] == tc[1] and p16[i * 4 + 2] == tc[2]) p16[i * 4 + 3] = 0;
    }
  }
}

fn expandPalette(a: *Png, palette: []const u8, pal_img_n: usize) Error!void {
  const count = a.x * a.y;
  const p = a.alloc.alloc(u8, try common.checkedSize(count, pal_img_n, 1)) catch return Error.OutOfMemory;
  if (pal_img_n == 3) {
    var i: usize = 0;
    while (i < count) : (i += 1) {
      const n = @as(usize, a.out[i]) * 4;
      p[i * 3 + 0] = palette[n + 0];
      p[i * 3 + 1] = palette[n + 1];
      p[i * 3 + 2] = palette[n + 2];
    }
  } else {
    var i: usize = 0;
    while (i < count) : (i += 1) {
      const n = @as(usize, a.out[i]) * 4;
      p[i * 4 + 0] = palette[n + 0];
      p[i * 4 + 1] = palette[n + 1];
      p[i * 4 + 2] = palette[n + 2];
      p[i * 4 + 3] = palette[n + 3];
    }
  }
  a.alloc.free(a.out);
  a.out = p;
}

fn deIphone(a: *Png) void {
  const count = a.x * a.y;
  var p = a.out;
  if (a.out_n == 3) {
    var i: usize = 0;
    while (i < count) : (i += 1) {
      const t = p[0];
      p[0] = p[2];
      p[2] = t;
      p = p[3..];
    }
  } else {
    var i: usize = 0;
    while (i < count) : (i += 1) {
      const t = p[0];
      p[0] = p[2];
      p[2] = t;
      p = p[4..];
    }
  }
}

fn tag(a: u8, b: u8, c: u8, d: u8) u32 {
  return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, c) << 8) | d;
}

/// Decode a whole PNG file to native channels + bit depth.
pub fn decode(alloc: Alloc, file: []const u8) Error!Decoded {
  if (!isPng(file)) return Error.Corrupt;
  var r = Reader.init(file);
  r.skip(8);

  var a = Png{ .alloc = alloc };
  var palette: [1024]u8 = undefined;
  var pal_len: usize = 0;
  var pal_img_n: usize = 0;
  var has_trans = false;
  var tc = [3]u8{ 0, 0, 0 };
  var tc16 = [3]u16{ 0, 0, 0 };
  var interlace: u8 = 0;
  var is_iphone = false;
  var first = true;

  var idata: std.ArrayList(u8) = .empty;
  defer idata.deinit(alloc);
  errdefer if (a.out.len > 0) alloc.free(a.out);

  while (true) {
    const clen = r.get32be();
    const ctype = r.get32be();
    switch (ctype) {
      tag('C', 'g', 'B', 'I') => {
        is_iphone = true;
        r.skip(clen);
      },
      tag('I', 'H', 'D', 'R') => {
        if (!first) return Error.Corrupt;
        first = false;
        if (clen != 13) return Error.Corrupt;
        a.x = r.get32be();
        a.y = r.get32be();
        if (a.x == 0 or a.y == 0) return Error.Corrupt;
        if (a.x > common.MAX_DIM or a.y > common.MAX_DIM) return Error.TooLarge;
        a.depth = r.get8();
        if (a.depth != 1 and a.depth != 2 and a.depth != 4 and a.depth != 8 and a.depth != 16) return Error.Unsupported;
        a.color = r.get8();
        if (a.color > 6) return Error.Corrupt;
        if (a.color == 3 and a.depth == 16) return Error.Corrupt;
        if (a.color == 3) {
          pal_img_n = 3;
        } else if (a.color & 1 != 0) return Error.Corrupt;
        if (r.get8() != 0) return Error.Corrupt; // compression
        if (r.get8() != 0) return Error.Corrupt; // filter
        interlace = r.get8();
        if (interlace > 1) return Error.Corrupt;
        if (pal_img_n == 0) {
          a.img_n = (if (a.color & 2 != 0) @as(usize, 3) else 1) + (if (a.color & 4 != 0) @as(usize, 1) else 0);
        } else {
          a.img_n = 1;
        }
      },
      tag('P', 'L', 'T', 'E') => {
        if (first) return Error.Corrupt;
        if (clen > 256 * 3) return Error.Corrupt;
        pal_len = clen / 3;
        if (pal_len * 3 != clen) return Error.Corrupt;
        var i: usize = 0;
        while (i < pal_len) : (i += 1) {
          palette[i * 4 + 0] = r.get8();
          palette[i * 4 + 1] = r.get8();
          palette[i * 4 + 2] = r.get8();
          palette[i * 4 + 3] = 255;
        }
      },
      tag('t', 'R', 'N', 'S') => {
        if (first) return Error.Corrupt;
        if (idata.items.len != 0) return Error.Corrupt;
        if (pal_img_n != 0) {
          if (pal_len == 0) return Error.Corrupt;
          if (clen > pal_len) return Error.Corrupt;
          pal_img_n = 4;
          var i: usize = 0;
          while (i < clen) : (i += 1) palette[i * 4 + 3] = r.get8();
        } else {
          if (a.img_n & 1 == 0) return Error.Corrupt;
          if (clen != a.img_n * 2) return Error.Corrupt;
          has_trans = true;
          if (a.depth == 16) {
            var kk: usize = 0;
            while (kk < a.img_n and kk < 3) : (kk += 1) tc16[kk] = @intCast(r.get16be());
          } else {
            var kk: usize = 0;
            while (kk < a.img_n and kk < 3) : (kk += 1) tc[kk] = @intCast((r.get16be() & 255) * depth_scale[a.depth]);
          }
        }
      },
      tag('I', 'D', 'A', 'T') => {
        if (first) return Error.Corrupt;
        idata.appendSlice(alloc, r.bytes(clen)) catch return Error.OutOfMemory;
      },
      tag('I', 'E', 'N', 'D') => {
        if (first) return Error.Corrupt;
        if (idata.items.len == 0) return Error.Corrupt;
        const expanded = try zlib.inflate(alloc, idata.items, !is_iphone);
        defer alloc.free(expanded);

        a.out_n = if ((has_trans and pal_img_n == 0)) a.img_n + 1 else a.img_n;
        try a.createImage(expanded, a.out_n, interlace == 1);

        if (has_trans) {
          if (a.depth == 16) computeTransparency16(&a, tc16, a.out_n) else computeTransparency(&a, tc, a.out_n);
        }
        if (is_iphone and a.out_n > 2) deIphone(&a);
        if (pal_img_n != 0) {
          a.img_n = pal_img_n;
          a.out_n = pal_img_n;
          try expandPalette(&a, palette[0 .. pal_len * 4], pal_img_n);
        } else if (has_trans) {
          a.img_n += 1;
        }
        return .{
          .w = a.x,
          .h = a.y,
          .comp = a.out_n,
          .src_comp = a.img_n,
          .depth = if (a.depth == 16) 16 else 8,
          .data = a.out,
          .alloc = alloc,
        };
      },
      else => {
        if (first) return Error.Corrupt;
        // Unknown chunk: if critical (bit 5 of first byte clear), fail.
        if (ctype & (1 << 29) == 0) return Error.Unsupported;
        r.skip(clen);
      },
    }
    _ = r.get32be(); // CRC (unchecked)
    if (r.atEof() and ctype != tag('I', 'E', 'N', 'D')) return Error.Corrupt;
  }
}

// ── info (structured header, no pixel decode) ──────────────────────────────────

pub const Info = struct {
  w: usize,
  h: usize,
  depth: u8,
  color: u8,
  interlace: u8,
  comp: usize,
};

pub fn info(file: []const u8) ?Info {
  if (!isPng(file)) return null;
  var r = Reader.init(file);
  r.skip(8);
  const clen = r.get32be();
  if (r.get32be() != tag('I', 'H', 'D', 'R') or clen != 13) return null;
  const x = r.get32be();
  const y = r.get32be();
  const depth = r.get8();
  const color = r.get8();
  _ = r.get8();
  _ = r.get8();
  const interlace = r.get8();
  const comp: usize = switch (color) {
    0 => 1,
    2 => 3,
    3 => 1,
    4 => 2,
    6 => 4,
    else => return null,
  };
  return .{ .w = x, .h = y, .depth = depth, .color = color, .interlace = interlace, .comp = comp };
}

// ── encode ─────────────────────────────────────────────────────────────────────

fn crcUpdate(crc0: u32, data: []const u8) u32 {
  var crc = crc0 ^ 0xffffffff;
  for (data) |byte| {
    crc ^= byte;
    var k: u8 = 0;
    while (k < 8) : (k += 1) {
      const mask = ~(crc & 1) +% 1; // 0xffffffff if bit set else 0
      crc = (crc >> 1) ^ (0xedb88320 & mask);
    }
  }
  return crc ^ 0xffffffff;
}

fn writeChunk(out: *std.ArrayList(u8), alloc: Alloc, ctype: *const [4]u8, payload: []const u8) Error!void {
  var lenb: [4]u8 = undefined;
  std.mem.writeInt(u32, &lenb, @intCast(payload.len), .big);
  out.appendSlice(alloc, &lenb) catch return Error.OutOfMemory;
  const start = out.items.len;
  out.appendSlice(alloc, ctype) catch return Error.OutOfMemory;
  out.appendSlice(alloc, payload) catch return Error.OutOfMemory;
  var crcb: [4]u8 = undefined;
  std.mem.writeInt(u32, &crcb, crcUpdate(0, out.items[start..]), .big);
  out.appendSlice(alloc, &crcb) catch return Error.OutOfMemory;
}

/// Encode `pixels` (w*h*comp interleaved 8-bit) into a PNG file. comp: 1 grey,
/// 2 grey+a, 3 rgb, 4 rgba. Uses filter 0 (none) on every row + stored zlib.
pub fn encode(alloc: Alloc, w: usize, h: usize, comp: usize, pixels: []const u8) Error![]u8 {
  if (comp < 1 or comp > 4) return Error.Unsupported;
  const ct_table = [5]u8{ 0, 0, 4, 2, 6 };
  const color_type = ct_table[comp];

  // Build the raw (unfiltered) scanline stream: 1 filter byte + row per line.
  const stride = w * comp;
  const raw = alloc.alloc(u8, (stride + 1) * h) catch return Error.OutOfMemory;
  defer alloc.free(raw);
  var j: usize = 0;
  while (j < h) : (j += 1) {
    raw[j * (stride + 1)] = 0; // filter: none
    @memcpy(raw[j * (stride + 1) + 1 ..][0..stride], pixels[j * stride ..][0..stride]);
  }

  const zdata = try zlib.deflateStored(alloc, raw);
  defer alloc.free(zdata);

  var out: std.ArrayList(u8) = .empty;
  errdefer out.deinit(alloc);
  out.appendSlice(alloc, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }) catch return Error.OutOfMemory;

  var ihdr: [13]u8 = undefined;
  std.mem.writeInt(u32, ihdr[0..4], @intCast(w), .big);
  std.mem.writeInt(u32, ihdr[4..8], @intCast(h), .big);
  ihdr[8] = 8; // bit depth
  ihdr[9] = color_type;
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace
  try writeChunk(&out, alloc, "IHDR", &ihdr);
  try writeChunk(&out, alloc, "IDAT", zdata);
  try writeChunk(&out, alloc, "IEND", &.{});
  return out.toOwnedSlice(alloc);
}
