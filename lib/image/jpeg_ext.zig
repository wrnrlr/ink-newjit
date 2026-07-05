/// libjpeg — the JPEG image extension for ink.
///
///   JpegRead   "path"   → image dict `width`height`comp`data (1 or 3 channels)
///   JpegHeader "path"   → structured marker layout dict (no pixel decode):
///     `width`height`precision`ncomp`progressive`components`quant`huffman`restart`app
///   where `components is a table (id;h;v;tq), `huffman a table (class;id;count),
///   `app a table (marker;length), and `quant an I of quant-table ids present.
///   This mirrors the SOI→APPn→DQT→SOF→DHT→DRI→SOS structure of a JFIF file.

const std = @import("std");
const k = @import("kbuild.zig");
const common = @import("common.zig");
const jpeg = @import("jpeg.zig");
const Reader = @import("reader.zig").Reader;

const alloc = std.heap.c_allocator;

export fn JpegRead(path_k: ?k.K) callconv(.c) ?k.K {
  const file = common.readFileK(alloc, path_k) orelse return null;
  defer alloc.free(file);
  var img = jpeg.decode(alloc, file) catch return null;
  return common.imageDict(&img);
}

const IL = std.ArrayList(i32);

export fn JpegHeader(path_k: ?k.K) callconv(.c) ?k.K {
  const file = common.readFileK(alloc, path_k) orelse return null;
  defer alloc.free(file);
  var r = Reader.init(file);
  if (r.get8() != 0xFF or r.get8() != 0xD8) return null; // SOI

  var width: i32 = 0;
  var height: i32 = 0;
  var precision: i32 = 0;
  var ncomp: i32 = 0;
  var progressive = false;
  var restart: i32 = 0;

  var comp_id: IL = .empty;
  var comp_h: IL = .empty;
  var comp_v: IL = .empty;
  var comp_tq: IL = .empty;
  var quant: IL = .empty;
  var huff_class: IL = .empty;
  var huff_id: IL = .empty;
  var huff_count: IL = .empty;
  var app_marker: IL = .empty;
  var app_len: IL = .empty;
  defer {
    inline for (.{ &comp_id, &comp_h, &comp_v, &comp_tq, &quant, &huff_class, &huff_id, &huff_count, &app_marker, &app_len }) |lst| lst.deinit(alloc);
  }

  while (!r.atEof()) {
    var m = r.get8();
    if (m != 0xFF) continue;
    while (m == 0xFF and !r.atEof()) m = r.get8();
    if (m == 0xD9) break; // EOI
    if (m == 0xDA) break; // SOS — header ends here (scan data follows)
    // Markers without a length payload
    if (m == 0x01 or (m >= 0xD0 and m <= 0xD7)) continue;

    const len_full = r.get16be();
    if (len_full < 2) break;
    const payload: usize = len_full - 2;
    const end = r.pos + payload;

    switch (m) {
      0xC0, 0xC1, 0xC2 => { // SOF (baseline / extended / progressive)
        progressive = (m == 0xC2);
        precision = r.get8();
        height = @intCast(r.get16be());
        width = @intCast(r.get16be());
        ncomp = r.get8();
        var i: i32 = 0;
        while (i < ncomp) : (i += 1) {
          const id: i32 = r.get8();
          const hv = r.get8();
          const tq: i32 = r.get8();
          comp_id.append(alloc, id) catch return null;
          comp_h.append(alloc, hv >> 4) catch return null;
          comp_v.append(alloc, hv & 15) catch return null;
          comp_tq.append(alloc, tq) catch return null;
        }
      },
      0xDB => { // DQT
        while (r.pos < end) {
          const q = r.get8();
          const p = q >> 4;
          quant.append(alloc, q & 15) catch return null;
          r.skip(if (p != 0) @as(usize, 128) else 64);
        }
      },
      0xC4 => { // DHT
        while (r.pos < end) {
          const q = r.get8();
          var n: i32 = 0;
          var i: usize = 0;
          while (i < 16) : (i += 1) n += r.get8();
          huff_class.append(alloc, q >> 4) catch return null;
          huff_id.append(alloc, q & 15) catch return null;
          huff_count.append(alloc, n) catch return null;
          r.skip(@intCast(n));
        }
      },
      0xDD => { // DRI
        restart = @intCast(r.get16be());
      },
      else => {
        if (m >= 0xE0 and m <= 0xEF or m == 0xFE) {
          app_marker.append(alloc, m) catch return null;
          app_len.append(alloc, @intCast(payload)) catch return null;
        }
      },
    }
    r.seek(end);
  }

  // components table
  const comp_keys = [_][*:0]const u8{ "id", "h", "v", "tq" };
  const comp_vals = [_]?k.K{ k.ints(i32, comp_id.items), k.ints(i32, comp_h.items), k.ints(i32, comp_v.items), k.ints(i32, comp_tq.items) };
  const components = k.table(&comp_keys, &comp_vals);

  const huff_keys = [_][*:0]const u8{ "class", "id", "count" };
  const huff_vals = [_]?k.K{ k.ints(i32, huff_class.items), k.ints(i32, huff_id.items), k.ints(i32, huff_count.items) };
  const huffman = k.table(&huff_keys, &huff_vals);

  const app_keys = [_][*:0]const u8{ "marker", "length" };
  const app_vals = [_]?k.K{ k.ints(i32, app_marker.items), k.ints(i32, app_len.items) };
  const app = k.table(&app_keys, &app_vals);

  const keys = [_][*:0]const u8{ "width", "height", "precision", "ncomp", "progressive", "components", "quant", "huffman", "restart", "app" };
  const vals = [_]?k.K{
    k.ki(width),                 k.ki(height),  k.ki(precision),
    k.ki(ncomp),                 k.kb(progressive), components,
    k.ints(i32, quant.items),    huffman,       k.ki(restart),
    app,
  };
  return k.dict(&keys, &vals);
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  const kr: *const @import("kabi").KRegistry(*anyopaque) = @ptrCast(@alignCast(reg));
  kr.k_register("JpegRead", @ptrCast(&JpegRead), 1);
  kr.k_register("JpegHeader", @ptrCast(&JpegHeader), 1);
}
export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_jpeg(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
