/// Baseline TIFF decoder — enough for the equirectangular Earth maps from
/// solarsystemscope (little/big-endian, 8-bit, chunky RGB or grayscale, single
/// or multi-strip, uncompressed or Deflate/zlib with optional horizontal
/// predictor).  Deflate strips reuse lib/image/zlib.zig.  Unsupported variants
/// (LZW, tiled, planar, non-8-bit, float) return Error.Unsupported.

const std = @import("std");
const common = @import("common.zig");
const zlib = @import("zlib.zig");

const Alloc = common.Alloc;
const Error = common.Error;

pub fn isTiff(f: []const u8) bool {
  if (f.len < 4) return false;
  const le = f[0] == 'I' and f[1] == 'I' and f[2] == 42 and f[3] == 0;
  const be = f[0] == 'M' and f[1] == 'M' and f[2] == 0 and f[3] == 42;
  return le or be;
}

// Endian-aware reader over the file bytes. Out-of-range reads yield 0.
const Rdr = struct {
  f: []const u8,
  le: bool,
  fn rd16(self: Rdr, off: usize) u32 {
    if (off + 2 > self.f.len) return 0;
    return std.mem.readInt(u16, self.f[off..][0..2], if (self.le) .little else .big);
  }
  fn rd32(self: Rdr, off: usize) u32 {
    if (off + 4 > self.f.len) return 0;
    return std.mem.readInt(u32, self.f[off..][0..4], if (self.le) .little else .big);
  }
  // TIFF field element sizes by type: 1=BYTE 3=SHORT 4=LONG.
  fn typeSize(typ: u32) usize {
    return switch (typ) { 1 => 1, 3 => 2, else => 4 };
  }
  // The i-th value of a field: values live inline when they fit in 4 bytes,
  // otherwise `field_off` holds a u32 offset to the value array.
  fn elem(self: Rdr, field_off: usize, typ: u32, count: u32, i: usize) u32 {
    const sz = typeSize(typ);
    const base = if (sz * count <= 4) field_off else self.rd32(field_off);
    const o = base + i * sz;
    return switch (typ) {
      1 => if (o < self.f.len) self.f[o] else 0,
      3 => self.rd16(o),
      else => self.rd32(o),
    };
  }
};

fn inflateStrip(alloc: Alloc, data: []const u8) Error![]u8 {
  // TIFF Deflate (compression 8 / 32946) is zlib-wrapped; a few writers emit raw
  // deflate, so fall back to no-header.
  return zlib.inflate(alloc, data, true) catch
    zlib.inflate(alloc, data, false) catch Error.Corrupt;
}

pub fn decode(alloc: Alloc, file: []const u8) Error!common.Image {
  if (!isTiff(file)) return Error.Corrupt;
  const r = Rdr{ .f = file, .le = file[0] == 'I' };

  const ifd = r.rd32(4);
  if (ifd == 0 or ifd + 2 > file.len) return Error.Corrupt;
  const n = r.rd16(ifd);

  var width: u32 = 0;
  var height: u32 = 0;
  var bits: u32 = 8;
  var compression: u32 = 1;
  var samples: u32 = 1;
  var rows_per_strip: u32 = 0xffff_ffff;
  var predictor: u32 = 1;
  var planar: u32 = 1;

  var off_field: usize = 0;
  var off_type: u32 = 0;
  var strips: u32 = 0;
  var cnt_field: usize = 0;
  var cnt_type: u32 = 0;

  var e: usize = 0;
  while (e < n) : (e += 1) {
    const eo = ifd + 2 + e * 12;
    if (eo + 12 > file.len) break;
    const tag = r.rd16(eo);
    const typ = r.rd16(eo + 2);
    const cnt = r.rd32(eo + 4);
    switch (tag) {
      256 => width = r.elem(eo + 8, typ, 1, 0),
      257 => height = r.elem(eo + 8, typ, 1, 0),
      258 => bits = r.elem(eo + 8, typ, cnt, 0), // BitsPerSample (first channel)
      259 => compression = r.elem(eo + 8, typ, 1, 0),
      273 => { off_field = eo + 8; off_type = typ; strips = cnt; }, // StripOffsets
      277 => samples = r.elem(eo + 8, typ, 1, 0), // SamplesPerPixel
      278 => rows_per_strip = r.elem(eo + 8, typ, 1, 0),
      279 => { cnt_field = eo + 8; cnt_type = typ; }, // StripByteCounts
      284 => planar = r.elem(eo + 8, typ, 1, 0),
      317 => predictor = r.elem(eo + 8, typ, 1, 0),
      else => {},
    }
  }

  if (width == 0 or height == 0 or width > common.MAX_DIM or height > common.MAX_DIM) return Error.Corrupt;
  if (planar != 1 or bits != 8) return Error.Unsupported; // chunky 8-bit only
  if (compression != 1 and compression != 8 and compression != 32946) return Error.Unsupported;
  if (samples < 1 or samples > 4) return Error.Unsupported;
  if (strips == 0 or off_field == 0 or cnt_field == 0) return Error.Corrupt;

  const comp: usize = samples;
  const row_bytes = try common.checkedSize(width, comp, 1);
  const total = try common.checkedSize(row_bytes, height, 1);
  const out = alloc.alloc(u8, total) catch return Error.OutOfMemory;
  errdefer alloc.free(out);

  if (rows_per_strip == 0) rows_per_strip = height;
  var written: usize = 0;
  var s: usize = 0;
  while (s < strips and written < total) : (s += 1) {
    const so = r.elem(off_field, off_type, strips, s);
    const sc = r.elem(cnt_field, cnt_type, strips, s);
    if (so + sc > file.len or sc == 0) return Error.Corrupt;
    const packed_bytes = file[so .. so + sc];

    const raw: []u8 = if (compression == 1)
      alloc.dupe(u8, packed_bytes) catch return Error.OutOfMemory
    else
      try inflateStrip(alloc, packed_bytes);
    defer alloc.free(raw);

    const take = @min(raw.len, total - written);
    @memcpy(out[written .. written + take], raw[0..take]);
    written += take;
  }
  if (written < total) @memset(out[written..total], 0); // pad a short/truncated file

  // Horizontal differencing predictor: undo per row, per channel.
  if (predictor == 2) {
    var y: usize = 0;
    while (y < height) : (y += 1) {
      const row = out[y * row_bytes ..][0..row_bytes];
      var x: usize = comp;
      while (x < row_bytes) : (x += 1) row[x] = row[x] +% row[x - comp];
    }
  }

  return common.Image{ .w = width, .h = height, .comp = comp, .src_comp = comp, .data = out, .alloc = alloc };
}
