const std = @import("std");
const ink = @import("ink");
const win_mod = @import("window");

pub fn main() !void {
  var gpa = std.heap.DebugAllocator(.{}){};
  defer _ = gpa.deinit();
  const alloc = gpa.allocator();

  const win = try win_mod.Window.init(alloc, .{
    .title  = "Hello & World!",
    .width  = 400,
    .height = 200,
  });
  defer win.deinit(alloc);

  _ = ink.createFont("sans", "/System/Library/Fonts/Helvetica.ttc");

  while (win.running()) {
    const frame = try win.beginFrame() orelse continue;
    ink.fontSize(64);
    ink.fillColor(ink.lch(0.95, 0.02, 200));
    _ = ink.text(50, 100, "Hello&World!");
    try win.endFrame(frame);
  }
}
