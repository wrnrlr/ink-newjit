/// GIF decode (first frame), ported from stb_image's public-domain GIF reader:
/// global/local palettes, LZW, interlace, transparency. Always returns a
/// 4-channel (RGBA) 8-bit common.Image, matching stb's *comp==4 behaviour.

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const common = @import("common.zig");

const Alloc = std.mem.Allocator;
const Error = common.Error;
const Image = common.Image;

const Lzw = struct { prefix: i16, first: u8, suffix: u8 };

const Gif = struct {
  r: *Reader,
  w: usize = 0,
  h: usize = 0,
  out: []u8 = &.{},
  history: []u8 = &.{},
  flags: u8 = 0,
  bgindex: u8 = 0,
  transparent: i32 = -1,
  eflags: u8 = 0,
  pal: [256][4]u8 = undefined,
  lpal: [256][4]u8 = undefined,
  codes: [8192]Lzw = undefined,
  color_table: [*]const u8 = undefined,
  parse: i32 = 0,
  step: i32 = 0,
  lflags: u8 = 0,
  start_x: i32 = 0,
  start_y: i32 = 0,
  max_x: i32 = 0,
  max_y: i32 = 0,
  cur_x: i32 = 0,
  cur_y: i32 = 0,
  line_size: i32 = 0,

  fn parseColortable(g: *Gif, pal: *[256][4]u8, num: usize, transp: i32) void {
    var i: usize = 0;
    while (i < num) : (i += 1) {
      pal[i][2] = g.r.get8();
      pal[i][1] = g.r.get8();
      pal[i][0] = g.r.get8();
      pal[i][3] = if (transp == @as(i32, @intCast(i))) 0 else 255;
    }
  }

  fn outCode(g: *Gif, code: u16) void {
    if (g.codes[code].prefix >= 0) g.outCode(@intCast(g.codes[code].prefix));
    if (g.cur_y >= g.max_y) return;
    const idx: usize = @intCast(g.cur_x + g.cur_y);
    g.history[idx / 4] = 1;
    const c = g.color_table[@as(usize, g.codes[code].suffix) * 4 ..];
    if (c[3] > 128) {
      g.out[idx + 0] = c[2];
      g.out[idx + 1] = c[1];
      g.out[idx + 2] = c[0];
      g.out[idx + 3] = c[3];
    }
    g.cur_x += 4;
    if (g.cur_x >= g.max_x) {
      g.cur_x = g.start_x;
      g.cur_y += g.step;
      while (g.cur_y >= g.max_y and g.parse > 0) {
        g.step = (@as(i32, 1) << @intCast(g.parse)) * g.line_size;
        g.cur_y = g.start_y + (g.step >> 1);
        g.parse -= 1;
      }
    }
  }

  fn processRaster(g: *Gif) Error!void {
    const lzw_cs = g.r.get8();
    if (lzw_cs > 12) return Error.Corrupt;
    const clear: i32 = @as(i32, 1) << @intCast(lzw_cs);
    var first: bool = true;
    var codesize: u5 = @intCast(lzw_cs + 1);
    var codemask: i32 = (@as(i32, 1) << codesize) - 1;
    var bits: i32 = 0;
    var valid_bits: i32 = 0;
    var init_code: i32 = 0;
    while (init_code < clear) : (init_code += 1) {
      g.codes[@intCast(init_code)] = .{ .prefix = -1, .first = @intCast(init_code), .suffix = @intCast(init_code) };
    }
    var avail: i32 = clear + 2;
    var oldcode: i32 = -1;
    var len: i32 = 0;
    while (true) {
      if (valid_bits < codesize) {
        if (len == 0) {
          len = g.r.get8();
          if (len == 0) return;
        }
        len -= 1;
        bits |= @as(i32, g.r.get8()) << @intCast(valid_bits);
        valid_bits += 8;
      } else {
        const code = bits & codemask;
        bits >>= codesize;
        valid_bits -= codesize;
        if (code == clear) {
          codesize = @intCast(lzw_cs + 1);
          codemask = (@as(i32, 1) << codesize) - 1;
          avail = clear + 2;
          oldcode = -1;
          first = false;
        } else if (code == clear + 1) {
          g.r.skip(@intCast(len));
          var l = g.r.get8();
          while (l > 0) : (l = g.r.get8()) g.r.skip(l);
          return;
        } else if (code <= avail) {
          if (first) return Error.Corrupt;
          if (oldcode >= 0) {
            if (avail > 8192) return Error.Corrupt;
            const p = &g.codes[@intCast(avail)];
            avail += 1;
            p.prefix = @intCast(oldcode);
            p.first = g.codes[@intCast(oldcode)].first;
            p.suffix = if (code == avail - 1) p.first else g.codes[@intCast(code)].first;
          } else if (code == avail) return Error.Corrupt;
          g.outCode(@intCast(code));
          if ((avail & codemask) == 0 and avail <= 0x0FFF) {
            codesize += 1;
            codemask = (@as(i32, 1) << codesize) - 1;
          }
          oldcode = code;
        } else return Error.Corrupt;
      }
    }
  }
};

pub fn isGif(file: []const u8) bool {
  if (file.len < 6) return false;
  if (!std.mem.eql(u8, file[0..4], "GIF8")) return false;
  return (file[4] == '7' or file[4] == '9') and file[5] == 'a';
}

pub fn decode(alloc: Alloc, file: []const u8) Error!Image {
  var r = Reader.init(file);
  if (r.get8() != 'G' or r.get8() != 'I' or r.get8() != 'F' or r.get8() != '8') return Error.Corrupt;
  const version = r.get8();
  if (version != '7' and version != '9') return Error.Corrupt;
  if (r.get8() != 'a') return Error.Corrupt;

  var g = Gif{ .r = &r };
  g.w = r.get16le();
  g.h = r.get16le();
  g.flags = r.get8();
  g.bgindex = r.get8();
  _ = r.get8(); // ratio
  if (g.w == 0 or g.h == 0) return Error.Corrupt;
  if (g.w > common.MAX_DIM or g.h > common.MAX_DIM) return Error.TooLarge;
  if (g.flags & 0x80 != 0) g.parseColortable(&g.pal, @as(usize, 2) << @intCast(g.flags & 7), -1);

  const pcount = g.w * g.h;
  g.out = alloc.alloc(u8, try common.checkedSize(pcount, 4, 1)) catch return Error.OutOfMemory;
  errdefer alloc.free(g.out);
  g.history = alloc.alloc(u8, pcount) catch return Error.OutOfMemory;
  defer alloc.free(g.history);
  @memset(g.out, 0);
  @memset(g.history, 0);

  while (true) {
    const tag = r.get8();
    switch (tag) {
      0x2C => { // image descriptor
        const x: i32 = @intCast(r.get16le());
        const y: i32 = @intCast(r.get16le());
        const iw: i32 = @intCast(r.get16le());
        const ih: i32 = @intCast(r.get16le());
        if ((x + iw) > @as(i32, @intCast(g.w)) or (y + ih) > @as(i32, @intCast(g.h))) return Error.Corrupt;
        g.line_size = @as(i32, @intCast(g.w)) * 4;
        g.start_x = x * 4;
        g.start_y = y * g.line_size;
        g.max_x = g.start_x + iw * 4;
        g.max_y = g.start_y + ih * g.line_size;
        g.cur_x = g.start_x;
        g.cur_y = g.start_y;
        if (iw == 0) g.cur_y = g.max_y;
        g.lflags = r.get8();
        if (g.lflags & 0x40 != 0) {
          g.step = 8 * g.line_size;
          g.parse = 3;
        } else {
          g.step = g.line_size;
          g.parse = 0;
        }
        if (g.lflags & 0x80 != 0) {
          g.parseColortable(&g.lpal, @as(usize, 2) << @intCast(g.lflags & 7), if (g.eflags & 0x01 != 0) g.transparent else -1);
          g.color_table = @ptrCast(&g.lpal);
        } else if (g.flags & 0x80 != 0) {
          g.color_table = @ptrCast(&g.pal);
        } else return Error.Corrupt;
        try g.processRaster();
        return .{ .w = g.w, .h = g.h, .comp = 4, .src_comp = 4, .data = g.out, .alloc = alloc };
      },
      0x21 => { // extension
        const ext = r.get8();
        if (ext == 0xF9) {
          const len = r.get8();
          if (len == 4) {
            g.eflags = r.get8();
            _ = r.get16le(); // delay
            if (g.transparent >= 0) g.pal[@intCast(g.transparent)][3] = 255;
            if (g.eflags & 0x01 != 0) {
              g.transparent = r.get8();
              if (g.transparent >= 0) g.pal[@intCast(g.transparent)][3] = 0;
            } else {
              r.skip(1);
              g.transparent = -1;
            }
          } else {
            r.skip(len);
          }
        }
        var l = r.get8();
        while (l != 0) : (l = r.get8()) r.skip(l);
      },
      0x3B => return Error.Corrupt, // trailer before any image
      else => return Error.Corrupt,
    }
  }
}
