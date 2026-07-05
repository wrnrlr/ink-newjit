/// libpic — Softimage PIC image extension.  PicRead "path" → image dict.
const std = @import("std");
const k = @import("kbuild.zig");
const common = @import("common.zig");
const pic = @import("pic.zig");
const alloc = std.heap.c_allocator;

export fn PicRead(path_k: ?k.K) callconv(.c) ?k.K {
  const file = common.readFileK(alloc, path_k) orelse return null;
  defer alloc.free(file);
  var img = pic.decode(alloc, file) catch return null;
  return common.imageDict(&img);
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  const kr: *const @import("kabi").KRegistry(*anyopaque) = @ptrCast(@alignCast(reg));
  kr.k_register("PicRead", @ptrCast(&PicRead), 1);
}
export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_pic(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
