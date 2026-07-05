/// libtga — TGA image extension.  TgaRead "path" → image dict.
const std = @import("std");
const k = @import("kbuild.zig");
const common = @import("common.zig");
const tga = @import("tga.zig");
const alloc = std.heap.c_allocator;

export fn TgaRead(path_k: ?k.K) callconv(.c) ?k.K {
  const file = common.readFileK(alloc, path_k) orelse return null;
  defer alloc.free(file);
  var img = tga.decode(alloc, file) catch return null;
  return common.imageDict(&img);
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  const kr: *const @import("kabi").KRegistry(*anyopaque) = @ptrCast(@alignCast(reg));
  kr.k_register("TgaRead", @ptrCast(&TgaRead), 1);
}
export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_tga(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
