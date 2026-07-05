/// libpng — the PNG image extension for ink.
///
/// K API (loaded via lib/image/png.k, or auto-loaded through lib/png.k):
///   PngRead  "path"                      → image dict `width`height`comp`data
///   PngInfo  "path"                      → header dict (no pixel decode)
///   PngWrite (path; w; h; comp; data)    → 1b on success
///
/// The image dict's `data is a row-major, top-left-first, channel-interleaved
/// I vector of length width*height*comp (samples 0..255, or 0..65535 for 16-bit
/// sources). See lib/image/common.zig.

const std = @import("std");
const k = @import("kbuild.zig");
const common = @import("common.zig");
const png = @import("png.zig");

const alloc = std.heap.c_allocator;

fn readFile(path_k: ?k.K) ?[]u8 {
  const cp = k.cp(path_k) orelse return null;
  const n: usize = @intCast(@max(0, k.kn(path_k)));
  if (n == 0) return null;
  const io = std.Io.Threaded.global_single_threaded.io();
  return std.Io.Dir.cwd().readFileAlloc(io, cp[0..n], alloc, std.Io.Limit.limited(512 << 20)) catch null;
}

export fn PngRead(path_k: ?k.K) callconv(.c) ?k.K {
  const file = readFile(path_k) orelse return null;
  defer alloc.free(file);
  var d = png.decode(alloc, file) catch return null;
  if (d.depth == 16) {
    const u16s = std.mem.bytesAsSlice(u16, d.data);
    const n = d.w * d.h * d.comp;
    // Hand ownership of a fresh u16 slice to imageDict16 (it frees it).
    const buf = alloc.alloc(u16, n) catch {
      d.deinit();
      return null;
    };
    @memcpy(buf, u16s[0..n]);
    d.deinit();
    return common.imageDict16(alloc, d.w, d.h, d.comp, d.src_comp, buf);
  }
  var img = common.Image{ .w = d.w, .h = d.h, .comp = d.comp, .src_comp = d.src_comp, .data = d.data, .alloc = alloc };
  return common.imageDict(&img);
}

export fn PngInfo(path_k: ?k.K) callconv(.c) ?k.K {
  const file = readFile(path_k) orelse return null;
  defer alloc.free(file);
  const nfo = png.info(file) orelse return null;
  const keys = [_][*:0]const u8{ "width", "height", "depth", "color", "interlace", "comp" };
  const vals = [_]?k.K{
    k.ki(@intCast(nfo.w)),      k.ki(@intCast(nfo.h)),    k.ki(nfo.depth),
    k.ki(nfo.color),            k.ki(nfo.interlace),      k.ki(@intCast(nfo.comp)),
  };
  return k.dict(&keys, &vals);
}

/// arg = (path_C; w_i; h_i; comp_i; data_I). Samples are clamped to 0..255.
export fn PngWrite(arg_k: ?k.K) callconv(.c) ?k.K {
  if (k.kn(arg_k) < 5) return k.kb(false);
  const path_k = k.listGet(arg_k, 0);
  defer k.unref(path_k);
  const w_k = k.listGet(arg_k, 1);
  defer k.unref(w_k);
  const h_k = k.listGet(arg_k, 2);
  defer k.unref(h_k);
  const comp_k = k.listGet(arg_k, 3);
  defer k.unref(comp_k);
  const data_k = k.listGet(arg_k, 4);
  defer k.unref(data_k);

  const w: usize = @intCast(@max(0, k.kival(w_k)));
  const h: usize = @intCast(@max(0, k.kival(h_k)));
  const comp: usize = @intCast(@max(0, k.kival(comp_k)));
  const want = w * h * comp;
  if (want == 0 or @as(usize, @intCast(@max(0, k.kn(data_k)))) < want) return k.kb(false);
  const dp = k.ip(data_k) orelse return k.kb(false);

  const pixels = alloc.alloc(u8, want) catch return k.kb(false);
  defer alloc.free(pixels);
  for (0..want) |i| pixels[i] = @intCast(std.math.clamp(dp[i], 0, 255));

  const file = png.encode(alloc, w, h, comp, pixels) catch return k.kb(false);
  defer alloc.free(file);

  const cp = k.cp(path_k) orelse return k.kb(false);
  const pn: usize = @intCast(@max(0, k.kn(path_k)));
  const io = std.Io.Threaded.global_single_threaded.io();
  var f = std.Io.Dir.cwd().createFile(io, cp[0..pn], .{}) catch return k.kb(false);
  defer f.close(io);
  f.writeStreamingAll(io, file) catch return k.kb(false);
  return k.kb(true);
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  const kr: *const @import("kabi").KRegistry(*anyopaque) = @ptrCast(@alignCast(reg));
  kr.k_register("PngRead", @ptrCast(&PngRead), 1);
  kr.k_register("PngInfo", @ptrCast(&PngInfo), 1);
  kr.k_register("PngWrite", @ptrCast(&PngWrite), 1);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_png(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
