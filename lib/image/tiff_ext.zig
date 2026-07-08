/// libtiff — the TIFF image extension for ink.
///
/// K API (loaded via lib/tiff.k, or auto-loaded through lib/image.k):
///   TiffRead  "path"   → image dict `width`height`comp`data
///
/// Baseline TIFF only (8-bit chunky RGB/grayscale, uncompressed or Deflate with
/// an optional horizontal predictor) — enough for the Earth normal/specular maps.
/// `data is a row-major, top-left-first, channel-interleaved I vector.

const std = @import("std");
const k = @import("kbuild.zig");
const common = @import("common.zig");
const tiff = @import("tiff.zig");

const alloc = std.heap.c_allocator;

fn readFile(path_k: ?k.K) ?[]u8 {
  const cp = k.cp(path_k) orelse return null;
  const n: usize = @intCast(@max(0, k.kn(path_k)));
  if (n == 0) return null;
  const io = std.Io.Threaded.global_single_threaded.io();
  return std.Io.Dir.cwd().readFileAlloc(io, cp[0..n], alloc, std.Io.Limit.limited(512 << 20)) catch null;
}

export fn TiffRead(path_k: ?k.K) callconv(.c) ?k.K {
  const file = readFile(path_k) orelse return null;
  defer alloc.free(file);
  var img = tiff.decode(alloc, file) catch return null;
  return common.imageDict(&img);
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  const kr: *const @import("kabi").KRegistry(k.K) = @ptrCast(@alignCast(reg));
  kr.k_register("TiffRead", @ptrCast(&TiffRead), 1);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_tiff(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
