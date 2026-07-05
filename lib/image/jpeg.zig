/// Baseline + progressive JPEG decode, ported from stb_image's public-domain
/// JFIF decoder (scalar IDCT, no SIMD; 8-bit only, no arithmetic coding — same
/// subset as the stock IJG library). Returns an 8-bit common.Image (1 or 3
/// channels). `header` parses the marker structure for the ink data layout.

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const common = @import("common.zig");

const Alloc = std.mem.Allocator;
const Error = common.Error;
const Image = common.Image;

const FAST_BITS = 9;
const MARKER_none: u8 = 0xff;

const bmask = [17]u32{ 0, 1, 3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535 };
const jbias = [16]i32{ 0, -1, -3, -7, -15, -31, -63, -127, -255, -511, -1023, -2047, -4095, -8191, -16383, -32767 };

const dezigzag = [64 + 15]u8{
  0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
  12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
  63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
};

fn toShort(x: i32) i16 {
  return @bitCast(@as(u16, @truncate(@as(u32, @bitCast(x)))));
}

const Huffman = struct {
  fast: [1 << FAST_BITS]u8 = undefined,
  code: [256]u16 = undefined,
  values: [256]u8 = undefined,
  size: [257]u8 = undefined,
  maxcode: [18]u32 = undefined,
  delta: [17]i32 = undefined,

  fn build(h: *Huffman, count: []const i32) Error!void {
    var k: usize = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
      var j: i32 = 0;
      while (j < count[i]) : (j += 1) {
        h.size[k] = @intCast(i + 1);
        k += 1;
        if (k >= 257) return Error.Corrupt;
      }
    }
    h.size[k] = 0;
    var code: u32 = 0;
    k = 0;
    var jj: usize = 1;
    while (jj <= 16) : (jj += 1) {
      h.delta[jj] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
      if (h.size[k] == jj) {
        while (h.size[k] == jj) {
          h.code[k] = @intCast(code);
          code += 1;
          k += 1;
        }
        if (code - 1 >= (@as(u32, 1) << @intCast(jj))) return Error.Corrupt;
      }
      h.maxcode[jj] = code << @intCast(16 - jj);
      code <<= 1;
    }
    h.maxcode[17] = 0xffffffff;
    @memset(&h.fast, 255);
    i = 0;
    while (i < k) : (i += 1) {
      const s = h.size[i];
      if (s <= FAST_BITS) {
        const c = @as(usize, h.code[i]) << @intCast(FAST_BITS - s);
        const m = @as(usize, 1) << @intCast(FAST_BITS - s);
        var j: usize = 0;
        while (j < m) : (j += 1) h.fast[c + j] = @intCast(i);
      }
    }
  }
};

fn buildFastAc(fast_ac: *[1 << FAST_BITS]i16, h: *const Huffman) void {
  var i: usize = 0;
  while (i < (1 << FAST_BITS)) : (i += 1) {
    const fast = h.fast[i];
    fast_ac[i] = 0;
    if (fast < 255) {
      const rs = h.values[fast];
      const run = (rs >> 4) & 15;
      const magbits: u5 = @intCast(rs & 15);
      const len = h.size[fast];
      if (magbits != 0 and len + magbits <= FAST_BITS) {
        var kk: i32 = @intCast((@as(u32, @intCast(i)) << @intCast(len)) & ((1 << FAST_BITS) - 1));
        kk >>= @intCast(FAST_BITS - magbits);
        const m: i32 = @as(i32, 1) << (magbits - 1);
        if (kk < m) kk += (@as(i32, -1) << magbits) + 1;
        if (kk >= -128 and kk <= 127) fast_ac[i] = @intCast((kk * 256) + (@as(i32, run) * 16) + (len + magbits));
      }
    }
  }
}

const Comp = struct {
  id: i32 = 0,
  h: i32 = 0,
  v: i32 = 0,
  tq: i32 = 0,
  hd: i32 = 0,
  ha: i32 = 0,
  dc_pred: i32 = 0,
  x: usize = 0,
  y: usize = 0,
  w2: usize = 0,
  h2: usize = 0,
  data: []u8 = &.{},
  linebuf: []u8 = &.{},
  coeff: []i16 = &.{},
  coeff_w: usize = 0,
  coeff_h: usize = 0,
};

const Jpeg = struct {
  r: Reader,
  alloc: Alloc,
  img_x: usize = 0,
  img_y: usize = 0,
  img_n: usize = 0,
  img_out_n: usize = 0,

  huff_dc: [4]Huffman = undefined,
  huff_ac: [4]Huffman = undefined,
  dequant: [4][64]u16 = undefined,
  fast_ac: [4][1 << FAST_BITS]i16 = undefined,

  img_h_max: i32 = 0,
  img_v_max: i32 = 0,
  img_mcu_x: usize = 0,
  img_mcu_y: usize = 0,
  img_mcu_w: usize = 0,
  img_mcu_h: usize = 0,
  comp: [4]Comp = .{ .{}, .{}, .{}, .{} },

  code_buffer: u32 = 0,
  code_bits: i32 = 0,
  marker: u8 = MARKER_none,
  nomore: bool = false,

  progressive: bool = false,
  spec_start: i32 = 0,
  spec_end: i32 = 0,
  succ_high: i32 = 0,
  succ_low: i32 = 0,
  eob_run: i32 = 0,
  jfif: i32 = 0,
  app14_color_transform: i32 = -1,
  rgb: i32 = 0,

  scan_n: i32 = 0,
  order: [4]usize = .{ 0, 0, 0, 0 },
  restart_interval: i32 = 0,
  todo: i32 = 0,

  fn get8(j: *Jpeg) u8 {
    return j.r.get8();
  }
  fn get16be(j: *Jpeg) u32 {
    return j.r.get16be();
  }

  fn growBuffer(j: *Jpeg) void {
    while (true) {
      const b: u32 = if (j.nomore) 0 else j.get8();
      if (b == 0xff) {
        var c = j.get8();
        while (c == 0xff) c = j.get8();
        if (c != 0) {
          j.marker = c;
          j.nomore = true;
          return;
        }
      }
      j.code_buffer |= b << @intCast(24 - j.code_bits);
      j.code_bits += 8;
      if (j.code_bits > 24) break;
    }
  }

  fn huffDecode(j: *Jpeg, h: *const Huffman) i32 {
    if (j.code_bits < 16) j.growBuffer();
    const c = (j.code_buffer >> (32 - FAST_BITS)) & ((1 << FAST_BITS) - 1);
    const kf = h.fast[c];
    if (kf < 255) {
      const s = h.size[kf];
      if (s > j.code_bits) return -1;
      j.code_buffer <<= @intCast(s);
      j.code_bits -= s;
      return h.values[kf];
    }
    const temp = j.code_buffer >> 16;
    var k: usize = FAST_BITS + 1;
    while (temp >= h.maxcode[k]) : (k += 1) {}
    if (k == 17) {
      j.code_bits -= 16;
      return -1;
    }
    if (k > j.code_bits) return -1;
    const idx: usize = @intCast((@as(i32, @intCast((j.code_buffer >> @intCast(32 - k)) & bmask[k]))) + h.delta[k]);
    if (idx >= 256) return -1;
    j.code_bits -= @intCast(k);
    j.code_buffer <<= @intCast(k);
    return h.values[idx];
  }

  fn extendReceive(j: *Jpeg, n: u5) i32 {
    if (j.code_bits < n) j.growBuffer();
    if (j.code_bits < n) return 0;
    const sgn: i32 = @intCast(j.code_buffer >> 31);
    var k = std.math.rotl(u32, j.code_buffer, n);
    j.code_buffer = k & ~bmask[n];
    k &= bmask[n];
    j.code_bits -= n;
    return @as(i32, @intCast(k)) + (jbias[n] & (sgn - 1));
  }

  fn getBits(j: *Jpeg, n: u5) i32 {
    if (j.code_bits < n) j.growBuffer();
    if (j.code_bits < n) return 0;
    var k = std.math.rotl(u32, j.code_buffer, n);
    j.code_buffer = k & ~bmask[n];
    k &= bmask[n];
    j.code_bits -= n;
    return @intCast(k);
  }

  fn getBit(j: *Jpeg) bool {
    if (j.code_bits < 1) j.growBuffer();
    if (j.code_bits < 1) return false;
    const k = j.code_buffer;
    j.code_buffer <<= 1;
    j.code_bits -= 1;
    return (k & 0x80000000) != 0;
  }

  fn reset(j: *Jpeg) void {
    j.code_bits = 0;
    j.code_buffer = 0;
    j.nomore = false;
    j.comp[0].dc_pred = 0;
    j.comp[1].dc_pred = 0;
    j.comp[2].dc_pred = 0;
    j.comp[3].dc_pred = 0;
    j.marker = MARKER_none;
    j.todo = if (j.restart_interval != 0) j.restart_interval else 0x7fffffff;
    j.eob_run = 0;
  }

  fn getMarker(j: *Jpeg) u8 {
    if (j.marker != MARKER_none) {
      const x = j.marker;
      j.marker = MARKER_none;
      return x;
    }
    var x = j.get8();
    if (x != 0xff) return MARKER_none;
    while (x == 0xff) x = j.get8();
    return x;
  }

  // ── block decoders ──────────────────────────────────────────────────────────

  fn decodeBlock(j: *Jpeg, data: *[64]i16, hdc: *const Huffman, hac: *const Huffman, fac: *const [1 << FAST_BITS]i16, b: usize, dq: *const [64]u16) Error!void {
    if (j.code_bits < 16) j.growBuffer();
    const t = j.huffDecode(hdc);
    if (t < 0 or t > 15) return Error.Corrupt;
    @memset(data, 0);
    const diff = if (t != 0) j.extendReceive(@intCast(t)) else 0;
    const dc = j.comp[b].dc_pred + diff;
    j.comp[b].dc_pred = dc;
    data[0] = toShort(dc * @as(i32, dq[0]));
    var k: usize = 1;
    while (true) {
      if (j.code_bits < 16) j.growBuffer();
      const c = (j.code_buffer >> (32 - FAST_BITS)) & ((1 << FAST_BITS) - 1);
      var r = fac[c];
      if (r != 0) {
        k += @intCast((r >> 4) & 15);
        const s: u5 = @intCast(r & 15);
        if (s > j.code_bits) return Error.Corrupt;
        j.code_buffer <<= s;
        j.code_bits -= s;
        const zig = dezigzag[k];
        k += 1;
        data[zig] = toShort((@as(i32, r) >> 8) * @as(i32, dq[zig]));
      } else {
        const rs = j.huffDecode(hac);
        if (rs < 0) return Error.Corrupt;
        const s: u5 = @intCast(rs & 15);
        r = @intCast(rs >> 4);
        if (s == 0) {
          if (rs != 0xf0) break;
          k += 16;
        } else {
          k += @intCast(r);
          const zig = dezigzag[k];
          k += 1;
          data[zig] = toShort(j.extendReceive(s) * @as(i32, dq[zig]));
        }
      }
      if (k >= 64) break;
    }
  }

  fn decodeBlockProgDc(j: *Jpeg, data: *[64]i16, hdc: *const Huffman, b: usize) Error!void {
    if (j.spec_end != 0) return Error.Corrupt;
    if (j.code_bits < 16) j.growBuffer();
    if (j.succ_high == 0) {
      @memset(data, 0);
      const t = j.huffDecode(hdc);
      if (t < 0 or t > 15) return Error.Corrupt;
      const diff = if (t != 0) j.extendReceive(@intCast(t)) else 0;
      const dc = j.comp[b].dc_pred + diff;
      j.comp[b].dc_pred = dc;
      data[0] = toShort(dc * (@as(i32, 1) << @intCast(j.succ_low)));
    } else {
      if (j.getBit()) data[0] +%= toShort(@as(i32, 1) << @intCast(j.succ_low));
    }
  }

  fn decodeBlockProgAc(j: *Jpeg, data: *[64]i16, hac: *const Huffman, fac: *const [1 << FAST_BITS]i16) Error!void {
    if (j.spec_start == 0) return Error.Corrupt;
    if (j.succ_high == 0) {
      const shift: u4 = @intCast(j.succ_low);
      if (j.eob_run != 0) {
        j.eob_run -= 1;
        return;
      }
      var k: usize = @intCast(j.spec_start);
      while (true) {
        if (j.code_bits < 16) j.growBuffer();
        const c = (j.code_buffer >> (32 - FAST_BITS)) & ((1 << FAST_BITS) - 1);
        var r = fac[c];
        if (r != 0) {
          k += @intCast((r >> 4) & 15);
          const s: u5 = @intCast(r & 15);
          if (s > j.code_bits) return Error.Corrupt;
          j.code_buffer <<= s;
          j.code_bits -= s;
          const zig = dezigzag[k];
          k += 1;
          data[zig] = toShort((@as(i32, r) >> 8) * (@as(i32, 1) << shift));
        } else {
          const rs = j.huffDecode(hac);
          if (rs < 0) return Error.Corrupt;
          const s = rs & 15;
          r = @intCast(rs >> 4);
          if (s == 0) {
            if (r < 15) {
              j.eob_run = (@as(i32, 1) << @intCast(r)) - 1;
              if (r != 0) j.eob_run += j.getBits(@intCast(r));
              break;
            }
            k += 16;
          } else {
            k += @intCast(r);
            const zig = dezigzag[k];
            k += 1;
            data[zig] = toShort(j.extendReceive(@intCast(s)) * (@as(i32, 1) << shift));
          }
        }
        if (k > j.spec_end) break;
      }
    } else {
      const bit = toShort(@as(i32, 1) << @intCast(j.succ_low));
      if (j.eob_run != 0) {
        j.eob_run -= 1;
        var k: usize = @intCast(j.spec_start);
        while (k <= j.spec_end) : (k += 1) {
          const p = &data[dezigzag[k]];
          if (p.* != 0) {
            if (j.getBit() and (p.* & bit) == 0) {
              if (p.* > 0) p.* +%= bit else p.* -%= bit;
            }
          }
        }
      } else {
        var k: usize = @intCast(j.spec_start);
        while (true) {
          const rs = j.huffDecode(hac);
          if (rs < 0) return Error.Corrupt;
          var s: i32 = rs & 15;
          var r: i32 = rs >> 4;
          if (s == 0) {
            if (r < 15) {
              j.eob_run = (@as(i32, 1) << @intCast(r)) - 1;
              if (r != 0) j.eob_run += j.getBits(@intCast(r));
              r = 64;
            }
          } else {
            if (s != 1) return Error.Corrupt;
            s = if (j.getBit()) bit else -@as(i32, bit);
          }
          while (k <= j.spec_end) {
            const p = &data[dezigzag[k]];
            k += 1;
            if (p.* != 0) {
              if (j.getBit() and (p.* & bit) == 0) {
                if (p.* > 0) p.* +%= bit else p.* -%= bit;
              }
            } else {
              if (r == 0) {
                p.* = @intCast(s);
                break;
              }
              r -= 1;
            }
          }
          if (k > j.spec_end) break;
        }
      }
    }
  }

  // ── entropy-coded scan ──────────────────────────────────────────────────────

  fn restartNeeded(marker: u8) bool {
    return marker >= 0xd0 and marker <= 0xd7;
  }

  fn parseEntropy(j: *Jpeg) Error!void {
    j.reset();
    if (!j.progressive) {
      if (j.scan_n == 1) {
        var data: [64]i16 = undefined;
        const n = j.order[0];
        const w = (j.comp[n].x + 7) >> 3;
        const h = (j.comp[n].y + 7) >> 3;
        var jj: usize = 0;
        while (jj < h) : (jj += 1) {
          var i: usize = 0;
          while (i < w) : (i += 1) {
            const ha: usize = @intCast(j.comp[n].ha);
            try j.decodeBlock(&data, &j.huff_dc[@intCast(j.comp[n].hd)], &j.huff_ac[ha], &j.fast_ac[ha], n, &j.dequant[@intCast(j.comp[n].tq)]);
            idctBlock(j.comp[n].data[j.comp[n].w2 * jj * 8 + i * 8 ..], j.comp[n].w2, &data);
            j.todo -= 1;
            if (j.todo <= 0) {
              if (j.code_bits < 24) j.growBuffer();
              if (!restartNeeded(j.marker)) return;
              j.reset();
            }
          }
        }
      } else {
        var data: [64]i16 = undefined;
        var jj: usize = 0;
        while (jj < j.img_mcu_y) : (jj += 1) {
          var i: usize = 0;
          while (i < j.img_mcu_x) : (i += 1) {
            var kk: usize = 0;
            while (kk < @as(usize, @intCast(j.scan_n))) : (kk += 1) {
              const n = j.order[kk];
              var y: usize = 0;
              while (y < @as(usize, @intCast(j.comp[n].v))) : (y += 1) {
                var x: usize = 0;
                while (x < @as(usize, @intCast(j.comp[n].h))) : (x += 1) {
                  const x2 = (i * @as(usize, @intCast(j.comp[n].h)) + x) * 8;
                  const y2 = (jj * @as(usize, @intCast(j.comp[n].v)) + y) * 8;
                  const ha: usize = @intCast(j.comp[n].ha);
                  try j.decodeBlock(&data, &j.huff_dc[@intCast(j.comp[n].hd)], &j.huff_ac[ha], &j.fast_ac[ha], n, &j.dequant[@intCast(j.comp[n].tq)]);
                  idctBlock(j.comp[n].data[j.comp[n].w2 * y2 + x2 ..], j.comp[n].w2, &data);
                }
              }
            }
            j.todo -= 1;
            if (j.todo <= 0) {
              if (j.code_bits < 24) j.growBuffer();
              if (!restartNeeded(j.marker)) return;
              j.reset();
            }
          }
        }
      }
    } else {
      if (j.scan_n == 1) {
        const n = j.order[0];
        const w = (j.comp[n].x + 7) >> 3;
        const h = (j.comp[n].y + 7) >> 3;
        var jj: usize = 0;
        while (jj < h) : (jj += 1) {
          var i: usize = 0;
          while (i < w) : (i += 1) {
            const data = j.comp[n].coeff[64 * (i + jj * j.comp[n].coeff_w) ..][0..64];
            if (j.spec_start == 0) {
              try j.decodeBlockProgDc(@ptrCast(data.ptr), &j.huff_dc[@intCast(j.comp[n].hd)], n);
            } else {
              const ha: usize = @intCast(j.comp[n].ha);
              try j.decodeBlockProgAc(@ptrCast(data.ptr), &j.huff_ac[ha], &j.fast_ac[ha]);
            }
            j.todo -= 1;
            if (j.todo <= 0) {
              if (j.code_bits < 24) j.growBuffer();
              if (!restartNeeded(j.marker)) return;
              j.reset();
            }
          }
        }
      } else {
        var jj: usize = 0;
        while (jj < j.img_mcu_y) : (jj += 1) {
          var i: usize = 0;
          while (i < j.img_mcu_x) : (i += 1) {
            var kk: usize = 0;
            while (kk < @as(usize, @intCast(j.scan_n))) : (kk += 1) {
              const n = j.order[kk];
              var y: usize = 0;
              while (y < @as(usize, @intCast(j.comp[n].v))) : (y += 1) {
                var x: usize = 0;
                while (x < @as(usize, @intCast(j.comp[n].h))) : (x += 1) {
                  const x2 = i * @as(usize, @intCast(j.comp[n].h)) + x;
                  const y2 = jj * @as(usize, @intCast(j.comp[n].v)) + y;
                  const data = j.comp[n].coeff[64 * (x2 + y2 * j.comp[n].coeff_w) ..][0..64];
                  try j.decodeBlockProgDc(@ptrCast(data.ptr), &j.huff_dc[@intCast(j.comp[n].hd)], n);
                }
              }
            }
            j.todo -= 1;
            if (j.todo <= 0) {
              if (j.code_bits < 24) j.growBuffer();
              if (!restartNeeded(j.marker)) return;
              j.reset();
            }
          }
        }
      }
    }
  }

  fn finish(j: *Jpeg) void {
    if (!j.progressive) return;
    var n: usize = 0;
    while (n < j.img_n) : (n += 1) {
      const w = (j.comp[n].x + 7) >> 3;
      const h = (j.comp[n].y + 7) >> 3;
      var jj: usize = 0;
      while (jj < h) : (jj += 1) {
        var i: usize = 0;
        while (i < w) : (i += 1) {
          const data = j.comp[n].coeff[64 * (i + jj * j.comp[n].coeff_w) ..][0..64];
          const dq = &j.dequant[@intCast(j.comp[n].tq)];
          var kk: usize = 0;
          while (kk < 64) : (kk += 1) data[kk] = toShort(@as(i32, data[kk]) * @as(i32, dq[kk]));
          idctBlock(j.comp[n].data[j.comp[n].w2 * jj * 8 + i * 8 ..], j.comp[n].w2, @ptrCast(data.ptr));
        }
      }
    }
  }

  // ── markers ─────────────────────────────────────────────────────────────────

  fn processMarker(j: *Jpeg, m: u8) Error!void {
    switch (m) {
      MARKER_none => return Error.Corrupt,
      0xDD => { // DRI
        if (j.get16be() != 4) return Error.Corrupt;
        j.restart_interval = @intCast(j.get16be());
        return;
      },
      0xDB => { // DQT
        var l: i32 = @as(i32, @intCast(j.get16be())) - 2;
        while (l > 0) {
          const q = j.get8();
          const p = q >> 4;
          const sixteen = p != 0;
          const t = q & 15;
          if (p != 0 and p != 1) return Error.Corrupt;
          if (t > 3) return Error.Corrupt;
          var i: usize = 0;
          while (i < 64) : (i += 1) {
            j.dequant[t][dezigzag[i]] = @intCast(if (sixteen) j.get16be() else j.get8());
          }
          l -= if (sixteen) 129 else 65;
        }
        if (l != 0) return Error.Corrupt;
        return;
      },
      0xC4 => { // DHT
        var l: i32 = @as(i32, @intCast(j.get16be())) - 2;
        while (l > 0) {
          var sizes: [16]i32 = undefined;
          var n: i32 = 0;
          const q = j.get8();
          const tc = q >> 4;
          const th = q & 15;
          if (tc > 1 or th > 3) return Error.Corrupt;
          var i: usize = 0;
          while (i < 16) : (i += 1) {
            sizes[i] = j.get8();
            n += sizes[i];
          }
          if (n > 256) return Error.Corrupt;
          l -= 17;
          if (tc == 0) {
            try j.huff_dc[th].build(&sizes);
            var ii: usize = 0;
            while (ii < @as(usize, @intCast(n))) : (ii += 1) j.huff_dc[th].values[ii] = j.get8();
          } else {
            try j.huff_ac[th].build(&sizes);
            var ii: usize = 0;
            while (ii < @as(usize, @intCast(n))) : (ii += 1) j.huff_ac[th].values[ii] = j.get8();
            buildFastAc(&j.fast_ac[th], &j.huff_ac[th]);
          }
          l -= n;
        }
        if (l != 0) return Error.Corrupt;
        return;
      },
      else => {},
    }
    if ((m >= 0xE0 and m <= 0xEF) or m == 0xFE) {
      var l: i32 = @intCast(j.get16be());
      if (l < 2) return Error.Corrupt;
      l -= 2;
      if (m == 0xE0 and l >= 5) {
        const tag = [5]u8{ 'J', 'F', 'I', 'F', 0 };
        var ok = true;
        var i: usize = 0;
        while (i < 5) : (i += 1) if (j.get8() != tag[i]) {
          ok = false;
        };
        l -= 5;
        if (ok) j.jfif = 1;
      } else if (m == 0xEE and l >= 12) {
        const tag = [6]u8{ 'A', 'd', 'o', 'b', 'e', 0 };
        var ok = true;
        var i: usize = 0;
        while (i < 6) : (i += 1) if (j.get8() != tag[i]) {
          ok = false;
        };
        l -= 6;
        if (ok) {
          _ = j.get8();
          _ = j.get16be();
          _ = j.get16be();
          j.app14_color_transform = j.get8();
          l -= 6;
        }
      }
      if (l > 0) j.r.skip(@intCast(l));
      return;
    }
    return Error.Corrupt;
  }

  fn processScanHeader(j: *Jpeg) Error!void {
    const ls = j.get16be();
    j.scan_n = @intCast(j.get8());
    if (j.scan_n < 1 or j.scan_n > 4 or j.scan_n > @as(i32, @intCast(j.img_n))) return Error.Corrupt;
    if (ls != 6 + 2 * @as(u32, @intCast(j.scan_n))) return Error.Corrupt;
    var i: usize = 0;
    while (i < @as(usize, @intCast(j.scan_n))) : (i += 1) {
      const id: i32 = @intCast(j.get8());
      const q = j.get8();
      var which: usize = 0;
      while (which < j.img_n) : (which += 1) if (j.comp[which].id == id) break;
      if (which == j.img_n) return Error.Corrupt;
      j.comp[which].hd = q >> 4;
      if (j.comp[which].hd > 3) return Error.Corrupt;
      j.comp[which].ha = q & 15;
      if (j.comp[which].ha > 3) return Error.Corrupt;
      j.order[i] = which;
    }
    j.spec_start = @intCast(j.get8());
    j.spec_end = @intCast(j.get8());
    const aa = j.get8();
    j.succ_high = aa >> 4;
    j.succ_low = aa & 15;
    if (j.progressive) {
      if (j.spec_start > 63 or j.spec_end > 63 or j.spec_start > j.spec_end or j.succ_high > 13 or j.succ_low > 13) return Error.Corrupt;
    } else {
      if (j.spec_start != 0) return Error.Corrupt;
      if (j.succ_high != 0 or j.succ_low != 0) return Error.Corrupt;
      j.spec_end = 63;
    }
  }

  fn processFrameHeader(j: *Jpeg, scan_load: bool) Error!void {
    const lf = j.get16be();
    if (lf < 11) return Error.Corrupt;
    const p = j.get8();
    if (p != 8) return Error.Unsupported;
    j.img_y = j.get16be();
    if (j.img_y == 0) return Error.Unsupported;
    j.img_x = j.get16be();
    if (j.img_x == 0) return Error.Corrupt;
    if (j.img_y > common.MAX_DIM or j.img_x > common.MAX_DIM) return Error.TooLarge;
    const c = j.get8();
    if (c != 3 and c != 1 and c != 4) return Error.Corrupt;
    j.img_n = c;
    if (lf != 8 + 3 * @as(u32, @intCast(j.img_n))) return Error.Corrupt;

    j.rgb = 0;
    var h_max: i32 = 1;
    var v_max: i32 = 1;
    var i: usize = 0;
    while (i < j.img_n) : (i += 1) {
      const rgb = [3]u8{ 'R', 'G', 'B' };
      j.comp[i].id = @intCast(j.get8());
      if (j.img_n == 3 and j.comp[i].id == rgb[i]) j.rgb += 1;
      const q = j.get8();
      j.comp[i].h = q >> 4;
      if (j.comp[i].h == 0 or j.comp[i].h > 4) return Error.Corrupt;
      j.comp[i].v = q & 15;
      if (j.comp[i].v == 0 or j.comp[i].v > 4) return Error.Corrupt;
      j.comp[i].tq = j.get8();
      if (j.comp[i].tq > 3) return Error.Corrupt;
    }
    if (!scan_load) return;

    i = 0;
    while (i < j.img_n) : (i += 1) {
      if (j.comp[i].h > h_max) h_max = j.comp[i].h;
      if (j.comp[i].v > v_max) v_max = j.comp[i].v;
    }
    i = 0;
    while (i < j.img_n) : (i += 1) {
      if (@rem(h_max, j.comp[i].h) != 0) return Error.Corrupt;
      if (@rem(v_max, j.comp[i].v) != 0) return Error.Corrupt;
    }
    j.img_h_max = h_max;
    j.img_v_max = v_max;
    j.img_mcu_w = @intCast(h_max * 8);
    j.img_mcu_h = @intCast(v_max * 8);
    j.img_mcu_x = (j.img_x + j.img_mcu_w - 1) / j.img_mcu_w;
    j.img_mcu_y = (j.img_y + j.img_mcu_h - 1) / j.img_mcu_h;

    i = 0;
    while (i < j.img_n) : (i += 1) {
      j.comp[i].x = (j.img_x * @as(usize, @intCast(j.comp[i].h)) + @as(usize, @intCast(h_max)) - 1) / @as(usize, @intCast(h_max));
      j.comp[i].y = (j.img_y * @as(usize, @intCast(j.comp[i].v)) + @as(usize, @intCast(v_max)) - 1) / @as(usize, @intCast(v_max));
      j.comp[i].w2 = j.img_mcu_x * @as(usize, @intCast(j.comp[i].h)) * 8;
      j.comp[i].h2 = j.img_mcu_y * @as(usize, @intCast(j.comp[i].v)) * 8;
      j.comp[i].data = j.alloc.alloc(u8, j.comp[i].w2 * j.comp[i].h2) catch return Error.OutOfMemory;
      if (j.progressive) {
        j.comp[i].coeff_w = j.comp[i].w2 / 8;
        j.comp[i].coeff_h = j.comp[i].h2 / 8;
        j.comp[i].coeff = j.alloc.alloc(i16, j.comp[i].w2 * j.comp[i].h2) catch return Error.OutOfMemory;
        @memset(j.comp[i].coeff, 0);
      }
    }
  }

  fn decodeHeader(j: *Jpeg, scan_load: bool) Error!void {
    j.jfif = 0;
    j.app14_color_transform = -1;
    j.marker = MARKER_none;
    var m = j.getMarker();
    if (m != 0xd8) return Error.Corrupt; // SOI
    m = j.getMarker();
    while (!(m == 0xc0 or m == 0xc1 or m == 0xc2)) { // until SOF
      try j.processMarker(m);
      m = j.getMarker();
      while (m == MARKER_none) {
        if (j.r.atEof()) return Error.Corrupt;
        m = j.getMarker();
      }
    }
    j.progressive = (m == 0xc2);
    try j.processFrameHeader(scan_load);
  }

  fn skipJunk(j: *Jpeg) u8 {
    while (!j.r.atEof()) {
      var x = j.get8();
      while (x == 0xff) {
        if (j.r.atEof()) return MARKER_none;
        x = j.get8();
        if (x != 0x00 and x != 0xff) return x;
      }
    }
    return MARKER_none;
  }

  fn decodeImage(j: *Jpeg) Error!void {
    j.restart_interval = 0;
    try j.decodeHeader(true);
    var m = j.getMarker();
    while (m != 0xd9) { // EOI
      if (m == 0xda) { // SOS
        try j.processScanHeader();
        try j.parseEntropy();
        if (j.marker == MARKER_none) j.marker = j.skipJunk();
        m = j.getMarker();
        if (restartNeeded(m)) m = j.getMarker();
      } else if (m == 0xdc) { // DNL
        const ld = j.get16be();
        const nl = j.get16be();
        if (ld != 4) return Error.Corrupt;
        if (nl != j.img_y) return Error.Corrupt;
        m = j.getMarker();
      } else {
        j.processMarker(m) catch return; // tolerate trailing junk
        m = j.getMarker();
      }
    }
    if (j.progressive) j.finish();
  }

  fn cleanup(j: *Jpeg) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
      if (j.comp[i].data.len > 0) j.alloc.free(j.comp[i].data);
      if (j.comp[i].coeff.len > 0) j.alloc.free(j.comp[i].coeff);
      if (j.comp[i].linebuf.len > 0) j.alloc.free(j.comp[i].linebuf);
      j.comp[i].data = &.{};
      j.comp[i].coeff = &.{};
      j.comp[i].linebuf = &.{};
    }
  }
};

// ── IDCT (scalar, DCT_ISLOW) ───────────────────────────────────────────────────

fn f2f(comptime x: f64) i32 {
  return @intFromFloat(x * 4096 + 0.5);
}

const Idct1 = struct { x0: i32, x1: i32, x2: i32, x3: i32, t0: i32, t1: i32, t2: i32, t3: i32 };

fn idct1d(s0: i32, s1: i32, s2: i32, s3: i32, s4: i32, s5: i32, s6: i32, s7: i32) Idct1 {
  var p2 = s2;
  var p3 = s6;
  var p1 = (p2 + p3) * f2f(0.5411961);
  var t2 = p1 + p3 * f2f(-1.847759065);
  var t3 = p1 + p2 * f2f(0.765366865);
  p2 = s0;
  p3 = s4;
  var t0 = (p2 + p3) * 4096;
  var t1 = (p2 - p3) * 4096;
  const x0 = t0 + t3;
  const x3 = t0 - t3;
  const x1 = t1 + t2;
  const x2 = t1 - t2;
  t0 = s7;
  t1 = s5;
  t2 = s3;
  t3 = s1;
  p3 = t0 + t2;
  var p4 = t1 + t3;
  p1 = t0 + t3;
  p2 = t1 + t2;
  const p5 = (p3 + p4) * f2f(1.175875602);
  t0 = t0 * f2f(0.298631336);
  t1 = t1 * f2f(2.053119869);
  t2 = t2 * f2f(3.072711026);
  t3 = t3 * f2f(1.501321110);
  p1 = p5 + p1 * f2f(-0.899976223);
  p2 = p5 + p2 * f2f(-2.562915447);
  p3 = p3 * f2f(-1.961570560);
  p4 = p4 * f2f(-0.390180644);
  t3 += p1 + p4;
  t2 += p2 + p3;
  t1 += p2 + p4;
  t0 += p1 + p3;
  return .{ .x0 = x0, .x1 = x1, .x2 = x2, .x3 = x3, .t0 = t0, .t1 = t1, .t2 = t2, .t3 = t3 };
}

fn clamp8(x: i32) u8 {
  if (x < 0) return 0;
  if (x > 255) return 255;
  return @intCast(x);
}

fn idctBlock(out: []u8, out_stride: usize, data: *const [64]i16) void {
  var val: [64]i32 = undefined;
  var i: usize = 0;
  while (i < 8) : (i += 1) {
    const d = data;
    if (d[i + 8] == 0 and d[i + 16] == 0 and d[i + 24] == 0 and d[i + 32] == 0 and d[i + 40] == 0 and d[i + 48] == 0 and d[i + 56] == 0) {
      const dcterm = @as(i32, d[i]) * 4;
      val[i] = dcterm;
      val[i + 8] = dcterm;
      val[i + 16] = dcterm;
      val[i + 24] = dcterm;
      val[i + 32] = dcterm;
      val[i + 40] = dcterm;
      val[i + 48] = dcterm;
      val[i + 56] = dcterm;
    } else {
      var r = idct1d(d[i], d[i + 8], d[i + 16], d[i + 24], d[i + 32], d[i + 40], d[i + 48], d[i + 56]);
      r.x0 += 512;
      r.x1 += 512;
      r.x2 += 512;
      r.x3 += 512;
      val[i] = (r.x0 + r.t3) >> 10;
      val[i + 56] = (r.x0 - r.t3) >> 10;
      val[i + 8] = (r.x1 + r.t2) >> 10;
      val[i + 48] = (r.x1 - r.t2) >> 10;
      val[i + 16] = (r.x2 + r.t1) >> 10;
      val[i + 40] = (r.x2 - r.t1) >> 10;
      val[i + 24] = (r.x3 + r.t0) >> 10;
      val[i + 32] = (r.x3 - r.t0) >> 10;
    }
  }
  i = 0;
  while (i < 8) : (i += 1) {
    const v = val[i * 8 ..];
    const o = out[i * out_stride ..];
    var r = idct1d(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
    const bias = 65536 + (128 << 17);
    r.x0 += bias;
    r.x1 += bias;
    r.x2 += bias;
    r.x3 += bias;
    o[0] = clamp8((r.x0 + r.t3) >> 17);
    o[7] = clamp8((r.x0 - r.t3) >> 17);
    o[1] = clamp8((r.x1 + r.t2) >> 17);
    o[6] = clamp8((r.x1 - r.t2) >> 17);
    o[2] = clamp8((r.x2 + r.t1) >> 17);
    o[5] = clamp8((r.x2 - r.t1) >> 17);
    o[3] = clamp8((r.x3 + r.t0) >> 17);
    o[4] = clamp8((r.x3 - r.t0) >> 17);
  }
}

// ── resample + colour ──────────────────────────────────────────────────────────

fn div4(x: i32) u8 {
  return @intCast((x >> 2) & 0xff);
}
fn div16(x: i32) u8 {
  return @intCast((x >> 4) & 0xff);
}

const Resample = struct {
  mode: u8, // 0=1:1 1=v2 2=h2 3=hv2 4=generic
  line0: []u8,
  line1: []u8,
  hs: i32,
  vs: i32,
  w_lores: usize,
  ystep: i32,
  ypos: usize,
};

fn resampleRow1(out: []u8, in_near: []const u8, w: usize) void {
  @memcpy(out[0..w], in_near[0..w]);
}
fn resampleRowV2(out: []u8, in_near: []const u8, in_far: []const u8, w: usize) void {
  var i: usize = 0;
  while (i < w) : (i += 1) out[i] = div4(3 * @as(i32, in_near[i]) + @as(i32, in_far[i]) + 2);
}
fn resampleRowH2(out: []u8, in_near: []const u8, w: usize) void {
  if (w == 1) {
    out[0] = in_near[0];
    out[1] = in_near[0];
    return;
  }
  out[0] = in_near[0];
  out[1] = div4(@as(i32, in_near[0]) * 3 + @as(i32, in_near[1]) + 2);
  var i: usize = 1;
  while (i < w - 1) : (i += 1) {
    const n = 3 * @as(i32, in_near[i]) + 2;
    out[i * 2 + 0] = div4(n + @as(i32, in_near[i - 1]));
    out[i * 2 + 1] = div4(n + @as(i32, in_near[i + 1]));
  }
  out[i * 2 + 0] = div4(@as(i32, in_near[w - 2]) * 3 + @as(i32, in_near[w - 1]) + 2);
  out[i * 2 + 1] = in_near[w - 1];
}
fn resampleRowHV2(out: []u8, in_near: []const u8, in_far: []const u8, w: usize) void {
  if (w == 1) {
    const v = div4(3 * @as(i32, in_near[0]) + @as(i32, in_far[0]) + 2);
    out[0] = v;
    out[1] = v;
    return;
  }
  var t1 = 3 * @as(i32, in_near[0]) + @as(i32, in_far[0]);
  out[0] = div4(t1 + 2);
  var i: usize = 1;
  while (i < w) : (i += 1) {
    const t0 = t1;
    t1 = 3 * @as(i32, in_near[i]) + @as(i32, in_far[i]);
    out[i * 2 - 1] = div16(3 * t0 + t1 + 8);
    out[i * 2] = div16(3 * t1 + t0 + 8);
  }
  out[w * 2 - 1] = div4(t1 + 2);
}
fn resampleRowGeneric(out: []u8, in_near: []const u8, w: usize, hs: usize) void {
  var i: usize = 0;
  while (i < w) : (i += 1) {
    var jx: usize = 0;
    while (jx < hs) : (jx += 1) out[i * hs + jx] = in_near[i];
  }
}

fn f2fixed(comptime x: f32) i32 {
  return @as(i32, @intFromFloat(x * 4096.0 + 0.5)) << 8;
}

fn ycbcrToRgb(out: []u8, y: []const u8, pcb: []const u8, pcr: []const u8, count: usize, step: usize) void {
  var i: usize = 0;
  var o: usize = 0;
  while (i < count) : (i += 1) {
    const y_fixed = (@as(i32, y[i]) << 20) + (1 << 19);
    const cr = @as(i32, pcr[i]) - 128;
    const cb = @as(i32, pcb[i]) - 128;
    var r = y_fixed + cr * f2fixed(1.40200);
    const mask: i32 = @bitCast(@as(u32, 0xffff0000));
    var g = y_fixed + (cr * -f2fixed(0.71414)) + ((cb * -f2fixed(0.34414)) & mask);
    var b = y_fixed + cb * f2fixed(1.77200);
    r >>= 20;
    g >>= 20;
    b >>= 20;
    out[o + 0] = clamp8(r);
    out[o + 1] = clamp8(g);
    out[o + 2] = clamp8(b);
    out[o + 3] = 255;
    o += step;
  }
}

fn blinn(x: u8, y: u8) u8 {
  const t: u32 = @as(u32, x) * @as(u32, y) + 128;
  return @intCast((t + (t >> 8)) >> 8);
}

fn computeYc(r: u8, g: u8, b: u8) u8 {
  return common.computeY(r, g, b);
}

// ── output assembly ─────────────────────────────────────────────────────────────

fn loadImage(j: *Jpeg) Error!Image {
  try j.decodeImage();

  const n: usize = if (j.img_n >= 3) 3 else 1;
  const is_rgb = j.img_n == 3 and (j.rgb == 3 or (j.app14_color_transform == 0 and j.jfif == 0));
  var decode_n: usize = if (j.img_n == 3 and n < 3 and !is_rgb) 1 else j.img_n;

  var res: [4]Resample = undefined;
  var k: usize = 0;
  while (k < decode_n) : (k += 1) {
    j.comp[k].linebuf = j.alloc.alloc(u8, j.img_x + 3) catch return Error.OutOfMemory;
    const hs = @divTrunc(j.img_h_max, j.comp[k].h);
    const vs = @divTrunc(j.img_v_max, j.comp[k].v);
    res[k] = .{
      .mode = if (hs == 1 and vs == 1) 0 else if (hs == 1 and vs == 2) 1 else if (hs == 2 and vs == 1) 2 else if (hs == 2 and vs == 2) 3 else 4,
      .line0 = j.comp[k].data,
      .line1 = j.comp[k].data,
      .hs = hs,
      .vs = vs,
      .w_lores = (j.img_x + @as(usize, @intCast(hs)) - 1) / @as(usize, @intCast(hs)),
      .ystep = vs >> 1,
      .ypos = 0,
    };
  }

  // +1 slack: ycbcrToRgb writes out[o+3] even for 3-channel output, so the last
  // pixel of the last row touches one byte past n*x*y (stb allocates the same).
  const output = j.alloc.alloc(u8, (try common.checkedSize(n, j.img_x, j.img_y)) + 1) catch return Error.OutOfMemory;
  errdefer j.alloc.free(output);

  var coutput: [4][]u8 = .{ &.{}, &.{}, &.{}, &.{} };

  var jrow: usize = 0;
  while (jrow < j.img_y) : (jrow += 1) {
    const out = output[n * j.img_x * jrow ..];
    k = 0;
    while (k < decode_n) : (k += 1) {
      const r = &res[k];
      const y_bot = r.ystep >= (r.vs >> 1);
      const near = if (y_bot) r.line1 else r.line0;
      const far = if (y_bot) r.line0 else r.line1;
      const lb = j.comp[k].linebuf;
      switch (r.mode) {
        0 => {
          resampleRow1(lb, near, r.w_lores);
          coutput[k] = lb;
        },
        1 => {
          resampleRowV2(lb, near, far, r.w_lores);
          coutput[k] = lb;
        },
        2 => {
          resampleRowH2(lb, near, r.w_lores);
          coutput[k] = lb;
        },
        3 => {
          resampleRowHV2(lb, near, far, r.w_lores);
          coutput[k] = lb;
        },
        else => {
          resampleRowGeneric(lb, near, r.w_lores, @intCast(r.hs));
          coutput[k] = lb;
        },
      }
      r.ystep += 1;
      if (r.ystep >= r.vs) {
        r.ystep = 0;
        r.line0 = r.line1;
        r.ypos += 1;
        if (r.ypos < j.comp[k].y) r.line1 = r.line1[j.comp[k].w2..];
      }
    }

    if (n >= 3) {
      const y = coutput[0];
      if (j.img_n == 3) {
        if (is_rgb) {
          var i: usize = 0;
          var o: usize = 0;
          while (i < j.img_x) : (i += 1) {
            out[o + 0] = y[i];
            out[o + 1] = coutput[1][i];
            out[o + 2] = coutput[2][i];
            out[o + 3] = 255;
            o += n;
          }
        } else {
          ycbcrToRgb(out, y, coutput[1], coutput[2], j.img_x, n);
        }
      } else if (j.img_n == 4) {
        if (j.app14_color_transform == 0) { // CMYK
          var i: usize = 0;
          var o: usize = 0;
          while (i < j.img_x) : (i += 1) {
            const m = coutput[3][i];
            out[o + 0] = blinn(coutput[0][i], m);
            out[o + 1] = blinn(coutput[1][i], m);
            out[o + 2] = blinn(coutput[2][i], m);
            out[o + 3] = 255;
            o += n;
          }
        } else if (j.app14_color_transform == 2) { // YCCK
          ycbcrToRgb(out, y, coutput[1], coutput[2], j.img_x, n);
          var i: usize = 0;
          var o: usize = 0;
          while (i < j.img_x) : (i += 1) {
            const m = coutput[3][i];
            out[o + 0] = blinn(255 - out[o + 0], m);
            out[o + 1] = blinn(255 - out[o + 1], m);
            out[o + 2] = blinn(255 - out[o + 2], m);
            o += n;
          }
        } else {
          ycbcrToRgb(out, y, coutput[1], coutput[2], j.img_x, n);
        }
      } else {
        var i: usize = 0;
        var o: usize = 0;
        while (i < j.img_x) : (i += 1) {
          out[o + 0] = y[i];
          out[o + 1] = y[i];
          out[o + 2] = y[i];
          out[o + 3] = 255;
          o += n;
        }
      }
    } else {
      if (is_rgb) {
        if (n == 1) {
          var i: usize = 0;
          while (i < j.img_x) : (i += 1) out[i] = computeYc(coutput[0][i], coutput[1][i], coutput[2][i]);
        } else {
          var i: usize = 0;
          var o: usize = 0;
          while (i < j.img_x) : (i += 1) {
            out[o] = computeYc(coutput[0][i], coutput[1][i], coutput[2][i]);
            out[o + 1] = 255;
            o += 2;
          }
        }
      } else if (j.img_n == 4 and j.app14_color_transform == 0) {
        var i: usize = 0;
        var o: usize = 0;
        while (i < j.img_x) : (i += 1) {
          const m = coutput[3][i];
          const rr = blinn(coutput[0][i], m);
          const gg = blinn(coutput[1][i], m);
          const bb = blinn(coutput[2][i], m);
          out[o] = computeYc(rr, gg, bb);
          if (n == 2) out[o + 1] = 255;
          o += n;
        }
      } else if (j.img_n == 4 and j.app14_color_transform == 2) {
        var i: usize = 0;
        var o: usize = 0;
        while (i < j.img_x) : (i += 1) {
          out[o] = blinn(255 - coutput[0][i], coutput[3][i]);
          if (n == 2) out[o + 1] = 255;
          o += n;
        }
      } else {
        const y = coutput[0];
        if (n == 1) {
          var i: usize = 0;
          while (i < j.img_x) : (i += 1) out[i] = y[i];
        } else {
          var i: usize = 0;
          var o: usize = 0;
          while (i < j.img_x) : (i += 1) {
            out[o] = y[i];
            out[o + 1] = 255;
            o += 2;
          }
        }
      }
    }
  }
  _ = &decode_n;

  return .{ .w = j.img_x, .h = j.img_y, .comp = n, .src_comp = n, .data = output, .alloc = j.alloc };
}

pub fn isJpeg(f: []const u8) bool {
  return f.len >= 3 and f[0] == 0xFF and f[1] == 0xD8 and f[2] == 0xFF;
}

pub fn decode(alloc: Alloc, file: []const u8) Error!Image {
  var j = Jpeg{ .r = Reader.init(file), .alloc = alloc };
  defer j.cleanup();
  return loadImage(&j);
}
