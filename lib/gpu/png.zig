// Minimal PNG writer for screenshots.  Emits a fully valid 8-bit RGBA PNG using
// DEFLATE *stored* (uncompressed) blocks, so it needs no compression library —
// just CRC32 (chunk framing) + Adler32 (zlib trailer).  Files are large (~raw
// size) but universally viewable; fine for debug snapshots.  If size ever
// matters, a real DEFLATE backend can replace deflateStored() without touching
// callers.

const std = @import("std");
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;

// CRC32 (PNG polynomial 0xEDB88320), table generated at comptime.
const crc_table: [256]u32 = blk: {
  @setEvalBranchQuota(20000);
  var t: [256]u32 = undefined;
  var n: usize = 0;
  while (n < 256) : (n += 1) {
    var c: u32 = @intCast(n);
    var k: usize = 0;
    while (k < 8) : (k += 1) {
      c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
    }
    t[n] = c;
  }
  break :blk t;
};

fn crc32(data: []const u8) u32 {
  var c: u32 = 0xFFFFFFFF;
  for (data) |b| c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
  return c ^ 0xFFFFFFFF;
}

fn adler32(data: []const u8) u32 {
  var a: u32 = 1;
  var b: u32 = 0;
  for (data) |x| {
    a = (a + x) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

fn putU32BE(out: *ArrayList(u8), alloc: Alloc, v: u32) !void {
  try out.appendSlice(alloc, &[_]u8{
    @intCast((v >> 24) & 0xFF), @intCast((v >> 16) & 0xFF),
    @intCast((v >> 8) & 0xFF),  @intCast(v & 0xFF),
  });
}

fn chunk(out: *ArrayList(u8), alloc: Alloc, typ: *const [4]u8, data: []const u8) !void {
  try putU32BE(out, alloc, @intCast(data.len));
  const start = out.items.len;
  try out.appendSlice(alloc, typ);
  try out.appendSlice(alloc, data);
  try putU32BE(out, alloc, crc32(out.items[start..]));
}

// zlib stream wrapping `raw` in DEFLATE stored blocks (≤65535 bytes each).
fn deflateStored(out: *ArrayList(u8), alloc: Alloc, raw: []const u8) !void {
  try out.appendSlice(alloc, &[_]u8{ 0x78, 0x01 }); // zlib header (no dict)
  var off: usize = 0;
  while (true) {
    const block: usize = @min(raw.len - off, 65535);
    const final = (off + block) >= raw.len;
    const len: u16 = @intCast(block);
    try out.append(alloc, if (final) 1 else 0); // BFINAL, BTYPE=00 (stored)
    try out.appendSlice(alloc, &[_]u8{ @intCast(len & 0xFF), @intCast(len >> 8) });
    const nlen = ~len;
    try out.appendSlice(alloc, &[_]u8{ @intCast(nlen & 0xFF), @intCast(nlen >> 8) });
    try out.appendSlice(alloc, raw[off .. off + block]);
    off += block;
    if (final) break;
  }
  try putU32BE(out, alloc, adler32(raw));
}

// Write `width`×`height` pixels (read from `src`, BGRA8 rows of `src_stride`
// bytes — the format Dawn hands back from a bgra8_unorm texture) to `path` as
// an RGBA PNG.  Rows are unfiltered (filter byte 0) and channels swizzled to RGBA.
pub fn writePng(alloc: Alloc, path: []const u8, width: u32, height: u32, src: []const u8, src_stride: u32) !void {
  const w: usize = width;
  const h: usize = height;
  const row_bytes = w * 4;

  // Filtered raw image data: each row prefixed with a 0 (no-filter) byte.
  var raw = try alloc.alloc(u8, h * (1 + row_bytes));
  defer alloc.free(raw);
  var ri: usize = 0;
  var y: usize = 0;
  while (y < h) : (y += 1) {
    raw[ri] = 0;
    ri += 1;
    const row = src[y * src_stride ..][0..row_bytes];
    var x: usize = 0;
    while (x < w) : (x += 1) {
      const p = row[x * 4 ..][0..4]; // B, G, R, A
      raw[ri + 0] = p[2]; // R
      raw[ri + 1] = p[1]; // G
      raw[ri + 2] = p[0]; // B
      raw[ri + 3] = p[3]; // A
      ri += 4;
    }
  }

  var out: ArrayList(u8) = .empty;
  defer out.deinit(alloc);
  try out.appendSlice(alloc, &[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 }); // PNG signature

  var ihdr: [13]u8 = undefined;
  std.mem.writeInt(u32, ihdr[0..4], width, .big);
  std.mem.writeInt(u32, ihdr[4..8], height, .big);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace
  try chunk(&out, alloc, "IHDR", &ihdr);

  var idat: ArrayList(u8) = .empty;
  defer idat.deinit(alloc);
  try deflateStored(&idat, alloc, raw);
  try chunk(&out, alloc, "IDAT", idat.items);

  try chunk(&out, alloc, "IEND", &.{});

  const io = std.Io.Threaded.global_single_threaded.io();
  const file = try std.Io.Dir.cwd().createFile(io, path, .{});
  defer file.close(io);
  try file.writePositionalAll(io, out.items, 0);
}
