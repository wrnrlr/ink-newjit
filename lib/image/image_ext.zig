/// libimage — format-agnostic image helpers shared across the per-format
/// extensions.
///
///   ImgSniff "path"                       → `png `jpeg `gif `bmp `hdr `pic `tga
///                                           (or `unknown)
///   ImgScale (w; h; comp; data; nw; nh)   → resampled I vector (nw*nh*comp)
///
/// The k side (lib/image.k) wraps these as image.read (sniff→dispatch) and
/// image.scale (resize an image dict).

const std = @import("std");
const k = @import("kbuild.zig");
const common = @import("common.zig");
const image = @import("image.zig");

const alloc = std.heap.c_allocator;

export fn ImgSniff(path_k: ?k.K) callconv(.c) ?k.K {
  const file = common.readFileK(alloc, path_k) orelse return k.ks("unknown");
  defer alloc.free(file);
  return k.ks(switch (image.sniff(file)) {
    .png => "png",
    .jpeg => "jpeg",
    .gif => "gif",
    .bmp => "bmp",
    .hdr => "hdr",
    .pic => "pic",
    .tga => "tga",
    .tiff => "tiff",
    .unknown => "unknown",
  });
}

/// arg = (w; h; comp; data_I; nw; nh) → resampled I vector.
export fn ImgScale(arg_k: ?k.K) callconv(.c) ?k.K {
  if (k.kn(arg_k) < 6) return null;
  const w_k = k.listGet(arg_k, 0);
  defer k.unref(w_k);
  const h_k = k.listGet(arg_k, 1);
  defer k.unref(h_k);
  const comp_k = k.listGet(arg_k, 2);
  defer k.unref(comp_k);
  const data_k = k.listGet(arg_k, 3);
  defer k.unref(data_k);
  const nw_k = k.listGet(arg_k, 4);
  defer k.unref(nw_k);
  const nh_k = k.listGet(arg_k, 5);
  defer k.unref(nh_k);

  const w: usize = @intCast(@max(0, k.kival(w_k)));
  const h: usize = @intCast(@max(0, k.kival(h_k)));
  const comp: usize = @intCast(@max(0, k.kival(comp_k)));
  const nw: usize = @intCast(@max(0, k.kival(nw_k)));
  const nh: usize = @intCast(@max(0, k.kival(nh_k)));
  const want = w * h * comp;
  if (want == 0 or @as(usize, @intCast(@max(0, k.kn(data_k)))) < want) return null;
  const dp = k.ip(data_k) orelse return null;

  const scaled = image.scale(alloc, w, h, comp, dp[0..want], nw, nh) catch return null;
  defer alloc.free(scaled);
  return k.ints(i32, scaled);
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  const kr: *const @import("kabi").KRegistry(*anyopaque) = @ptrCast(@alignCast(reg));
  kr.k_register("ImgSniff", @ptrCast(&ImgSniff), 1);
  kr.k_register("ImgScale", @ptrCast(&ImgScale), 1);
}
export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_image(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
