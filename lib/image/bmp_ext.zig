/// libbmp — the BMP image extension for ink.
///
///   BmpRead   "path"                         → structural dict (see below)
///   BmpDecode "path"                         → image dict `width`height`comp`data
///   BmpEncode (path; w; h; comp; data)       → 1b   (encode a decoded image)
///   BmpWriteS (path; w; h; depth; compression; masks; palette; pixels) → 1b
///
/// The structural dict mirrors the on-disk file, `magic first (a per-format
/// marker), then the file header, DIB header, optional colour masks, optional
/// palette, and the raw pixel bytes:
///   `magic`header`dib[`masks][`palette]`pixels
/// with header = `size`reserved`offset, dib = `size`width`height`planes`depth
/// `compression`imagesize`xppm`yppm`colors`important (compression a symbol),
/// masks = `r`g`b`a, palette an (n;4) RGBA matrix, pixels a raw char vector
/// (bottom-up, row-padded, exactly as stored).

const std = @import("std");
const k = @import("kbuild.zig");
const common = @import("common.zig");
const bmp = @import("bmp.zig");

const alloc = std.heap.c_allocator;

fn buildPalette(s: *const bmp.Struct) ?k.K {
  if (s.pal_count == 0) return null;
  const list = k.KL(s.pal_count) orelse return null;
  var i: usize = 0;
  while (i < s.pal_count) : (i += 1) {
    const row = k.KI(4) orelse return list;
    if (k.ip(row)) |p| {
      const base = i * s.pal_stride;
      p[0] = s.palette[base + 2]; // R (stored BGR[A])
      p[1] = s.palette[base + 1]; // G
      p[2] = s.palette[base + 0]; // B
      p[3] = if (s.pal_stride == 4) s.palette[base + 3] else 255; // A
    }
    k.listSet(list, i, row);
  }
  return list;
}

export fn BmpRead(path_k: ?k.K) callconv(.c) ?k.K {
  const file = common.readFileK(alloc, path_k) orelse return null;
  defer alloc.free(file);
  const s = bmp.readStruct(file) catch return null;

  const hkeys = [_][*:0]const u8{ "size", "reserved", "offset" };
  const hvals = [_]?k.K{ k.ki(@bitCast(s.file_size)), k.ki(@bitCast(s.reserved)), k.ki(@bitCast(s.offset)) };
  const header = k.dict(&hkeys, &hvals);

  const dkeys = [_][*:0]const u8{ "size", "width", "height", "planes", "depth", "compression", "imagesize", "xppm", "yppm", "colors", "important" };
  const dvals = [_]?k.K{
    k.ki(@bitCast(s.dib_size)), k.ki(s.width),               k.ki(s.height),
    k.ki(s.planes),             k.ki(s.depth),               k.ks(bmp.compressionName(s.compression)),
    k.ki(@bitCast(s.image_size)), k.ki(s.xppm),              k.ki(s.yppm),
    k.ki(@bitCast(s.colors)),   k.ki(@bitCast(s.important)),
  };
  const dib = k.dict(&dkeys, &dvals);

  // Top-level dict, built with only the fields that are present.
  var keys: [6][*:0]const u8 = undefined;
  var vals: [6]?k.K = undefined;
  var n: usize = 0;
  keys[n] = "magic";
  vals[n] = k.str("BM");
  n += 1;
  keys[n] = "header";
  vals[n] = header;
  n += 1;
  keys[n] = "dib";
  vals[n] = dib;
  n += 1;
  if (s.has_masks) {
    const mkeys = [_][*:0]const u8{ "r", "g", "b", "a" };
    const mvals = [_]?k.K{ k.ki(@bitCast(s.mask_r)), k.ki(@bitCast(s.mask_g)), k.ki(@bitCast(s.mask_b)), k.ki(@bitCast(s.mask_a)) };
    keys[n] = "masks";
    vals[n] = k.dict(&mkeys, &mvals);
    n += 1;
  }
  if (buildPalette(&s)) |pal| {
    keys[n] = "palette";
    vals[n] = pal;
    n += 1;
  }
  keys[n] = "pixels";
  vals[n] = k.str(s.pixels);
  n += 1;
  return k.dict(keys[0..n], vals[0..n]);
}

export fn BmpDecode(path_k: ?k.K) callconv(.c) ?k.K {
  const file = common.readFileK(alloc, path_k) orelse return null;
  defer alloc.free(file);
  var img = bmp.decode(alloc, file) catch return null;
  return common.imageDict(&img);
}

export fn BmpEncode(arg_k: ?k.K) callconv(.c) ?k.K {
  const wa = common.parseWriteArgs(alloc, arg_k) orelse return k.kb(false);
  defer alloc.free(wa.pixels);
  defer k.unref(wa.path_k);
  const file = bmp.encode(alloc, wa.w, wa.h, wa.comp, wa.pixels) catch return k.kb(false);
  defer alloc.free(file);
  return k.kb(common.writeFileK(wa.path_k, file));
}

/// arg = (path; w; h; depth; compression; masks_I(4); palette_I(flat RGBA); pixels_C)
export fn BmpWriteS(arg_k: ?k.K) callconv(.c) ?k.K {
  if (k.kn(arg_k) < 8) return k.kb(false);
  const path_k = k.listGet(arg_k, 0);
  defer k.unref(path_k);
  const w_k = k.listGet(arg_k, 1);
  defer k.unref(w_k);
  const h_k = k.listGet(arg_k, 2);
  defer k.unref(h_k);
  const depth_k = k.listGet(arg_k, 3);
  defer k.unref(depth_k);
  const comp_k = k.listGet(arg_k, 4);
  defer k.unref(comp_k);
  const masks_k = k.listGet(arg_k, 5);
  defer k.unref(masks_k);
  const pal_k = k.listGet(arg_k, 6);
  defer k.unref(pal_k);
  const px_k = k.listGet(arg_k, 7);
  defer k.unref(px_k);

  const w: i32 = k.kival(w_k);
  const h: i32 = k.kival(h_k);
  const depth: u16 = @intCast(@max(0, k.kival(depth_k)));
  const compression: u32 = @bitCast(k.kival(comp_k));

  var masks = [4]u32{ 0, 0, 0, 0 };
  if (k.ip(masks_k)) |mp| {
    const mn: usize = @intCast(@max(0, @min(4, k.kn(masks_k))));
    for (0..mn) |i| masks[i] = @bitCast(mp[i]);
  }

  const paln: usize = @intCast(@max(0, k.kn(pal_k)));
  var pal_buf: []u8 = &.{};
  defer if (pal_buf.len > 0) alloc.free(pal_buf);
  if (paln > 0) {
    if (k.ip(pal_k)) |pp| {
      pal_buf = alloc.alloc(u8, paln) catch return k.kb(false);
      for (0..paln) |i| pal_buf[i] = @intCast(std.math.clamp(pp[i], 0, 255));
    }
  }

  const pxn: usize = @intCast(@max(0, k.kn(px_k)));
  const px = if (k.cp(px_k)) |p| p[0..pxn] else &[_]u8{};

  const file = bmp.writeStruct(alloc, w, h, depth, compression, masks, pal_buf, px) catch return k.kb(false);
  defer alloc.free(file);
  return k.kb(common.writeFileK(path_k, file));
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  const kr: *const @import("kabi").KRegistry(*anyopaque) = @ptrCast(@alignCast(reg));
  kr.k_register("BmpRead", @ptrCast(&BmpRead), 1);
  kr.k_register("BmpDecode", @ptrCast(&BmpDecode), 1);
  kr.k_register("BmpEncode", @ptrCast(&BmpEncode), 1);
  kr.k_register("BmpWriteS", @ptrCast(&BmpWriteS), 1);
}
export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_bmp(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
