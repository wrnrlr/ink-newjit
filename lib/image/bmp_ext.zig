/// libbmp — the BMP image extension for ink.
///
///   BmpRead  "path"                    → image dict `width`height`comp`data
///   BmpWrite (path; w; h; comp; data)  → 1b on success

const std = @import("std");
const k = @import("kbuild.zig");
const common = @import("common.zig");
const bmp = @import("bmp.zig");

const alloc = std.heap.c_allocator;

export fn BmpRead(path_k: ?k.K) callconv(.c) ?k.K {
  const file = common.readFileK(alloc, path_k) orelse return null;
  defer alloc.free(file);
  var img = bmp.decode(alloc, file) catch return null;
  return common.imageDict(&img);
}

export fn BmpWrite(arg_k: ?k.K) callconv(.c) ?k.K {
  const wa = common.parseWriteArgs(alloc, arg_k) orelse return k.kb(false);
  defer alloc.free(wa.pixels);
  defer k.unref(wa.path_k);
  const file = bmp.encode(alloc, wa.w, wa.h, wa.comp, wa.pixels) catch return k.kb(false);
  defer alloc.free(file);
  return k.kb(common.writeFileK(wa.path_k, file));
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  const kr: *const @import("kabi").KRegistry(*anyopaque) = @ptrCast(@alignCast(reg));
  kr.k_register("BmpRead", @ptrCast(&BmpRead), 1);
  kr.k_register("BmpWrite", @ptrCast(&BmpWrite), 1);
}
export fn terse_init(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
export fn ink_ext_init_bmp(reg: *anyopaque) callconv(.c) void {
  inkInit(reg);
}
