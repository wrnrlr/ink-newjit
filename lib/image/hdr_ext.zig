/// libhdr — Radiance HDR image extension.  HdrRead "path" → image dict with an
/// F (float) `data column (3-channel linear RGB).
const std = @import("std");
const k = @import("kbuild.zig");
const common = @import("common.zig");
const hdr = @import("hdr.zig");
const alloc = std.heap.c_allocator;

export fn HdrRead(path_k: ?k.K) callconv(.c) ?k.K {
  const file = common.readFileK(alloc, path_k) orelse return null;
  defer alloc.free(file);
  const img = hdr.decode(alloc, file) catch return null;
  return common.imageDictF(alloc, img.w, img.h, img.comp, img.data);
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  const kr: *const @import("kabi").KRegistry(*anyopaque) = @ptrCast(@alignCast(reg));
  kr.k_register("HdrRead", @ptrCast(&HdrRead), 1);
}
export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_hdr(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
