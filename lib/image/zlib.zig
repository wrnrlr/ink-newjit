/// DEFLATE / zlib codec, ported from stb_image's public-domain zlib decoder,
/// plus a minimal stored-block encoder for PNG writing.
///
///   inflate(alloc, input, parse_header) → owned []u8   (RFC 1950/1951 decode)
///   deflateStored(alloc, data)          → owned []u8   (zlib stream, no compression)
///
/// The decoder buffers all output in one growable slice (PNG hands us the full
/// concatenated IDAT stream, so there is no streaming requirement).

const std = @import("std");
const Alloc = std.mem.Allocator;
pub const Error = error{ OutOfMemory, Corrupt };

const ZFAST_BITS = 9;
const ZFAST_MASK = (1 << ZFAST_BITS) - 1;
const ZNSYMS = 288;

fn bitreverse16(n0: u32) u32 {
  var n = n0;
  n = ((n & 0xAAAA) >> 1) | ((n & 0x5555) << 1);
  n = ((n & 0xCCCC) >> 2) | ((n & 0x3333) << 2);
  n = ((n & 0xF0F0) >> 4) | ((n & 0x0F0F) << 4);
  n = ((n & 0xFF00) >> 8) | ((n & 0x00FF) << 8);
  return n;
}
fn bitReverse(v: u32, bits: u5) u32 {
  return bitreverse16(v) >> @intCast(16 - @as(u32, bits));
}

const ZHuffman = struct {
  fast: [1 << ZFAST_BITS]u16 = undefined,
  firstcode: [16]u16 = undefined,
  maxcode: [17]i32 = undefined,
  firstsymbol: [16]u16 = undefined,
  size: [ZNSYMS]u8 = undefined,
  value: [ZNSYMS]u16 = undefined,

  fn build(z: *ZHuffman, sizelist: []const u8) Error!void {
    var next_code: [16]i32 = undefined;
    var sizes = [_]i32{0} ** 17;
    @memset(&z.fast, 0);
    for (sizelist) |s| sizes[s] += 1;
    sizes[0] = 0;
    var i: usize = 1;
    while (i < 16) : (i += 1) if (sizes[i] > (@as(i32, 1) << @intCast(i))) return Error.Corrupt;
    var code: i32 = 0;
    var kk: i32 = 0;
    i = 1;
    while (i < 16) : (i += 1) {
      next_code[i] = code;
      z.firstcode[i] = @intCast(code);
      z.firstsymbol[i] = @intCast(kk);
      code += sizes[i];
      if (sizes[i] != 0 and code - 1 >= (@as(i32, 1) << @intCast(i))) return Error.Corrupt;
      z.maxcode[i] = code << @intCast(16 - i);
      code <<= 1;
      kk += sizes[i];
    }
    z.maxcode[16] = 0x10000;
    for (sizelist, 0..) |s, sym| {
      if (s != 0) {
        const c: usize = @intCast(next_code[s] - z.firstcode[s] + z.firstsymbol[s]);
        const fastv: u16 = @intCast((@as(u32, s) << 9) | @as(u32, @intCast(sym)));
        z.size[c] = s;
        z.value[c] = @intCast(sym);
        if (s <= ZFAST_BITS) {
          var j = bitReverse(@intCast(next_code[s]), @intCast(s));
          while (j < (1 << ZFAST_BITS)) : (j += (@as(u32, 1) << @intCast(s))) z.fast[j] = fastv;
        }
        next_code[s] += 1;
      }
    }
  }
};

const ZBuf = struct {
  in: []const u8,
  pos: usize = 0,
  num_bits: i32 = 0,
  code_buffer: u32 = 0,
  hit_zeof_once: bool = false,
  out: std.ArrayList(u8),
  z_length: ZHuffman = .{},
  z_distance: ZHuffman = .{},

  fn zeof(z: *const ZBuf) bool {
    return z.pos >= z.in.len;
  }
  fn get8(z: *ZBuf) u8 {
    if (z.pos >= z.in.len) return 0;
    const v = z.in[z.pos];
    z.pos += 1;
    return v;
  }
  fn fillBits(z: *ZBuf) void {
    while (true) {
      if (z.code_buffer >= (@as(u32, 1) << @intCast(z.num_bits))) {
        z.pos = z.in.len; // treat as EOF so we fail
        return;
      }
      z.code_buffer |= @as(u32, z.get8()) << @intCast(z.num_bits);
      z.num_bits += 8;
      if (z.num_bits > 24) break;
    }
  }
  fn receive(z: *ZBuf, n: u5) u32 {
    if (z.num_bits < n) z.fillBits();
    const k = z.code_buffer & ((@as(u32, 1) << n) - 1);
    z.code_buffer >>= n;
    z.num_bits -= n;
    return k;
  }

  fn decodeSlow(z: *ZBuf, h: *const ZHuffman) i32 {
    const k = bitReverse(z.code_buffer, 16);
    var s: usize = ZFAST_BITS + 1;
    while (true) : (s += 1) {
      if (@as(i32, @intCast(k)) < h.maxcode[s]) break;
      if (s >= 16) return -1;
    }
    if (s >= 16) return -1;
    const b: usize = @intCast((@as(i32, @intCast(k >> @intCast(16 - s))) - h.firstcode[s]) + h.firstsymbol[s]);
    if (b >= ZNSYMS) return -1;
    if (h.size[b] != s) return -1;
    z.code_buffer >>= @intCast(s);
    z.num_bits -= @intCast(s);
    return h.value[b];
  }

  fn decode(z: *ZBuf, h: *const ZHuffman) i32 {
    if (z.num_bits < 16) {
      if (z.zeof()) {
        if (!z.hit_zeof_once) {
          z.hit_zeof_once = true;
          z.num_bits += 16;
        } else return -1;
      } else z.fillBits();
    }
    const b = h.fast[z.code_buffer & ZFAST_MASK];
    if (b != 0) {
      const s: u5 = @intCast(b >> 9);
      z.code_buffer >>= s;
      z.num_bits -= s;
      return @intCast(b & 511);
    }
    return z.decodeSlow(h);
  }

  fn huffmanBlock(z: *ZBuf) Error!void {
    while (true) {
      var val = z.decode(&z.z_length);
      if (val < 256) {
        if (val < 0) return Error.Corrupt;
        try z.out.append(gpa, @intCast(val));
      } else {
        if (val == 256) {
          if (z.hit_zeof_once and z.num_bits < 16) return Error.Corrupt;
          return;
        }
        if (val >= 286) return Error.Corrupt;
        val -= 257;
        const zi: usize = @intCast(val);
        var len: usize = zlength_base[zi];
        if (zlength_extra[zi] != 0) len += z.receive(@intCast(zlength_extra[zi]));
        const dval = z.decode(&z.z_distance);
        if (dval < 0 or dval >= 30) return Error.Corrupt;
        const di: usize = @intCast(dval);
        var dist: usize = zdist_base[di];
        if (zdist_extra[di] != 0) dist += z.receive(@intCast(zdist_extra[di]));
        if (z.out.items.len < dist) return Error.Corrupt;
        try z.out.ensureUnusedCapacity(gpa, len);
        const start = z.out.items.len - dist;
        var i: usize = 0;
        while (i < len) : (i += 1) {
          const byte = z.out.items[start + i];
          z.out.appendAssumeCapacity(byte);
        }
      }
    }
  }

  fn computeCodes(z: *ZBuf) Error!void {
    const dezig = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var codelength = ZHuffman{};
    var lencodes: [286 + 32 + 137]u8 = undefined;
    var clsizes = [_]u8{0} ** 19;

    const hlit = z.receive(5) + 257;
    const hdist = z.receive(5) + 1;
    const hclen = z.receive(4) + 4;
    const ntot = hlit + hdist;

    var i: usize = 0;
    while (i < hclen) : (i += 1) clsizes[dezig[i]] = @intCast(z.receive(3));
    try codelength.build(&clsizes);

    var n: usize = 0;
    while (n < ntot) {
      var c = z.decode(&codelength);
      if (c < 0 or c >= 19) return Error.Corrupt;
      if (c < 16) {
        lencodes[n] = @intCast(c);
        n += 1;
      } else {
        var fill: u8 = 0;
        if (c == 16) {
          c = @intCast(z.receive(2) + 3);
          if (n == 0) return Error.Corrupt;
          fill = lencodes[n - 1];
        } else if (c == 17) {
          c = @intCast(z.receive(3) + 3);
        } else if (c == 18) {
          c = @intCast(z.receive(7) + 11);
        } else return Error.Corrupt;
        const cc: usize = @intCast(c);
        if (ntot - n < cc) return Error.Corrupt;
        @memset(lencodes[n .. n + cc], fill);
        n += cc;
      }
    }
    if (n != ntot) return Error.Corrupt;
    try z.z_length.build(lencodes[0..hlit]);
    try z.z_distance.build(lencodes[hlit..ntot]);
  }

  fn uncompressedBlock(z: *ZBuf) Error!void {
    var header: [4]u8 = undefined;
    if (z.num_bits & 7 != 0) _ = z.receive(@intCast(z.num_bits & 7)); // discard
    var k: usize = 0;
    while (z.num_bits > 0) {
      header[k] = @intCast(z.code_buffer & 255);
      k += 1;
      z.code_buffer >>= 8;
      z.num_bits -= 8;
    }
    if (z.num_bits < 0) return Error.Corrupt;
    while (k < 4) : (k += 1) header[k] = z.get8();
    const len: usize = @as(usize, header[1]) * 256 + header[0];
    const nlen: usize = @as(usize, header[3]) * 256 + header[2];
    if (nlen != (len ^ 0xffff)) return Error.Corrupt;
    if (z.pos + len > z.in.len) return Error.Corrupt;
    try z.out.appendSlice(gpa, z.in[z.pos .. z.pos + len]);
    z.pos += len;
  }

  fn parseHeader(z: *ZBuf) Error!void {
    const cmf = z.get8();
    const cm = cmf & 15;
    const flg = z.get8();
    if (z.zeof()) return Error.Corrupt;
    if ((@as(u32, cmf) * 256 + flg) % 31 != 0) return Error.Corrupt;
    if (flg & 32 != 0) return Error.Corrupt; // preset dict
    if (cm != 8) return Error.Corrupt;
  }

  fn parse(z: *ZBuf, parse_header: bool) Error!void {
    if (parse_header) try z.parseHeader();
    z.num_bits = 0;
    z.code_buffer = 0;
    z.hit_zeof_once = false;
    var final: u32 = 0;
    while (final == 0) {
      final = z.receive(1);
      const t = z.receive(2);
      switch (t) {
        0 => try z.uncompressedBlock(),
        3 => return Error.Corrupt,
        1 => {
          try z.z_length.build(&zdefault_length);
          try z.z_distance.build(&zdefault_distance);
          try z.huffmanBlock();
        },
        else => {
          try z.computeCodes();
          try z.huffmanBlock();
        },
      }
    }
  }
};

var gpa: Alloc = undefined;

pub fn inflate(alloc: Alloc, input: []const u8, parse_header: bool) Error![]u8 {
  gpa = alloc;
  var z = ZBuf{ .in = input, .out = .empty };
  errdefer z.out.deinit(alloc);
  try z.parse(parse_header);
  return z.out.toOwnedSlice(alloc);
}

// ── stored-block zlib encoder (for PNG write) ──────────────────────────────────

fn adler32(data: []const u8) u32 {
  var a: u32 = 1;
  var b: u32 = 0;
  for (data) |byte| {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

/// Wrap `data` in a valid zlib stream using stored (type-0) DEFLATE blocks — no
/// compression, but every decoder accepts it and the encoder is trivially
/// correct. Returns an owned slice.
pub fn deflateStored(alloc: Alloc, data: []const u8) Error![]u8 {
  const nblocks = (data.len + 65534) / 65535;
  const total = 2 + data.len + nblocks * 5 + 4 + (if (data.len == 0) @as(usize, 5) else 0);
  var out = std.ArrayList(u8).initCapacity(alloc, total) catch return Error.OutOfMemory;
  errdefer out.deinit(alloc);
  out.appendSliceAssumeCapacity(&.{ 0x78, 0x01 }); // CMF/FLG (default window, no dict)

  var off: usize = 0;
  if (data.len == 0) {
    out.appendSliceAssumeCapacity(&.{ 0x01, 0x00, 0x00, 0xff, 0xff });
  }
  while (off < data.len) {
    const n = @min(@as(usize, 65535), data.len - off);
    const final: u8 = if (off + n >= data.len) 1 else 0;
    out.appendAssumeCapacity(final);
    out.appendAssumeCapacity(@intCast(n & 0xff));
    out.appendAssumeCapacity(@intCast((n >> 8) & 0xff));
    const nn = ~@as(u16, @intCast(n));
    out.appendAssumeCapacity(@intCast(nn & 0xff));
    out.appendAssumeCapacity(@intCast((nn >> 8) & 0xff));
    out.appendSliceAssumeCapacity(data[off .. off + n]);
    off += n;
  }
  const ad = adler32(data);
  out.appendSliceAssumeCapacity(&.{
    @intCast((ad >> 24) & 0xff),
    @intCast((ad >> 16) & 0xff),
    @intCast((ad >> 8) & 0xff),
    @intCast(ad & 0xff),
  });
  return out.toOwnedSlice(alloc);
}

// ── DEFLATE constant tables ────────────────────────────────────────────────────

const zlength_base = [31]usize{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0, 0 };
const zlength_extra = [31]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0 };
const zdist_base = [32]usize{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 0, 0 };
const zdist_extra = [32]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 0, 0 };

const zdefault_length = blk: {
  var a: [ZNSYMS]u8 = undefined;
  var i: usize = 0;
  while (i <= 143) : (i += 1) a[i] = 8;
  while (i <= 255) : (i += 1) a[i] = 9;
  while (i <= 279) : (i += 1) a[i] = 7;
  while (i <= 287) : (i += 1) a[i] = 8;
  break :blk a;
};
const zdefault_distance = [32]u8{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 };
