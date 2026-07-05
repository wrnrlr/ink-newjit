/// Radiance RGBE (.hdr) decode, ported from stb_image's public-domain HDR
/// reader. Returns a 3-channel float image (linear RGB); the `data column of
/// the image dict is therefore an F vector.

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const common = @import("common.zig");

const Alloc = std.mem.Allocator;
const Error = common.Error;

pub const FloatImage = struct {
  w: usize,
  h: usize,
  comp: usize,
  data: []f32,
};

pub fn isHdr(file: []const u8) bool {
  return std.mem.startsWith(u8, file, "#?RADIANCE\n") or std.mem.startsWith(u8, file, "#?RGBE\n");
}

fn rgbeToFloat(out: []f32, e: [4]u8) void {
  if (e[3] != 0) {
    const f1 = std.math.ldexp(@as(f32, 1.0), @as(i32, e[3]) - (128 + 8));
    out[0] = @as(f32, @floatFromInt(e[0])) * f1;
    out[1] = @as(f32, @floatFromInt(e[1])) * f1;
    out[2] = @as(f32, @floatFromInt(e[2])) * f1;
  } else {
    out[0] = 0;
    out[1] = 0;
    out[2] = 0;
  }
}

fn getToken(r: *Reader, buf: []u8) []const u8 {
  var len: usize = 0;
  var c = r.get8();
  while (!r.atEof() and c != '\n') {
    if (len < buf.len - 1) {
      buf[len] = c;
      len += 1;
    }
    c = r.get8();
  }
  return buf[0..len];
}

pub fn decode(alloc: Alloc, file: []const u8) Error!FloatImage {
  var r = Reader.init(file);
  var buf: [1024]u8 = undefined;

  const first = getToken(&r, &buf);
  if (!std.mem.eql(u8, first, "#?RADIANCE") and !std.mem.eql(u8, first, "#?RGBE")) return Error.Corrupt;

  var valid = false;
  while (true) {
    const tok = getToken(&r, &buf);
    if (tok.len == 0) break;
    if (std.mem.eql(u8, tok, "FORMAT=32-bit_rle_rgbe")) valid = true;
  }
  if (!valid) return Error.Unsupported;

  const dims = getToken(&r, &buf);
  // Expect "-Y <h> +X <w>"
  var it = std.mem.tokenizeScalar(u8, dims, ' ');
  const yk = it.next() orelse return Error.Corrupt;
  if (!std.mem.eql(u8, yk, "-Y")) return Error.Unsupported;
  const h = std.fmt.parseInt(usize, it.next() orelse return Error.Corrupt, 10) catch return Error.Corrupt;
  const xk = it.next() orelse return Error.Corrupt;
  if (!std.mem.eql(u8, xk, "+X")) return Error.Unsupported;
  const w = std.fmt.parseInt(usize, it.next() orelse return Error.Corrupt, 10) catch return Error.Corrupt;

  if (w == 0 or h == 0) return Error.Corrupt;
  if (w > common.MAX_DIM or h > common.MAX_DIM) return Error.TooLarge;

  const comp = 3;
  const data = alloc.alloc(f32, try common.checkedSize(w * h, comp, 1)) catch return Error.OutOfMemory;
  errdefer alloc.free(data);

  if (w < 8 or w >= 32768) {
    // flat scanlines
    var j: usize = 0;
    while (j < h) : (j += 1) {
      var i: usize = 0;
      while (i < w) : (i += 1) {
        var rgbe: [4]u8 = undefined;
        _ = r.getn(&rgbe);
        rgbeToFloat(data[(j * w + i) * comp ..], rgbe);
      }
    }
    return .{ .w = w, .h = h, .comp = comp, .data = data };
  }

  const scanline = alloc.alloc(u8, w * 4) catch return Error.OutOfMemory;
  defer alloc.free(scanline);

  var j: usize = 0;
  while (j < h) : (j += 1) {
    const c1 = r.get8();
    const c2 = r.get8();
    const l0 = r.get8();
    if (c1 != 2 or c2 != 2 or (l0 & 0x80) != 0) {
      // Not new-style RLE: this + the rest of the image are flat RGBE.
      var rgbe = [4]u8{ c1, c2, l0, r.get8() };
      rgbeToFloat(data[0..], rgbe);
      var idx: usize = 1;
      while (idx < w * h) : (idx += 1) {
        _ = r.getn(&rgbe);
        rgbeToFloat(data[idx * comp ..], rgbe);
      }
      return .{ .w = w, .h = h, .comp = comp, .data = data };
    }
    const len = (@as(usize, l0) << 8) | r.get8();
    if (len != w) return Error.Corrupt;

    var k: usize = 0;
    while (k < 4) : (k += 1) {
      var i: usize = 0;
      while (i < w) {
        var count = r.get8();
        if (count > 128) {
          const value = r.get8();
          count -= 128;
          if (count == 0 or @as(usize, count) > w - i) return Error.Corrupt;
          var z: usize = 0;
          while (z < count) : (z += 1) {
            scanline[i * 4 + k] = value;
            i += 1;
          }
        } else {
          if (count == 0 or @as(usize, count) > w - i) return Error.Corrupt;
          var z: usize = 0;
          while (z < count) : (z += 1) {
            scanline[i * 4 + k] = r.get8();
            i += 1;
          }
        }
      }
    }
    var i: usize = 0;
    while (i < w) : (i += 1) {
      const rgbe = [4]u8{ scanline[i * 4], scanline[i * 4 + 1], scanline[i * 4 + 2], scanline[i * 4 + 3] };
      rgbeToFloat(data[(j * w + i) * comp ..], rgbe);
    }
  }
  return .{ .w = w, .h = h, .comp = comp, .data = data };
}
