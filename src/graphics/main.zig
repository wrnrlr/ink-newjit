const std = @import("std");
const ink = @import("ink");
const win_mod = @import("window");

pub fn main() !void {
  var gpa = std.heap.DebugAllocator(.{}){};
  defer _ = gpa.deinit();
  const alloc = gpa.allocator();

  const win = try win_mod.Window.init(alloc, .{
    .title  = "Ink - Nanovg WGSL Port",
    .width  = 800,
    .height = 600,
  });
  defer win.deinit(alloc);

  _ = ink.createFont("sans", "/System/Library/Fonts/Helvetica.ttc");

  while (win.running()) {
    const frame = try win.beginFrame() orelse continue;

    // Normal fill
    ink.beginPath();
    ink.roundedRect(50, 50, 200, 200, 20);
    ink.fillColor(ink.lch(0.6, 0.15, 200));
    ink.fill();

    // Linear gradient: blue → transparent red
    ink.beginPath();
    ink.roundedRect(270, 50, 200, 100, 10);
    ink.fillPaint(ink.linearGradient(270, 50, 470, 50,
      ink.Blue500,
      .{ .l = ink.Red400.l, .c = ink.Red400.c, .h = ink.Red400.h, .a = 0 },
    ));
    ink.fill();

    // Radial gradient: white centre → purple edge
    ink.beginPath();
    ink.circle(370, 230, 70);
    ink.fillPaint(ink.radialGradient(370, 230, 10, 70, ink.White, ink.Purple600));
    ink.fill();

    // Text rendering
    const font_size: f32 = 72;
    ink.fontSize(font_size);
    ink.fillColor(ink.lch(0.95, 0.02, 200));
    const line_h = font_size * 1.3;
    _ = ink.text(30, 60,               "1234567890-=");
    _ = ink.text(30, 60 + line_h,      "qwertyuiop[]");
    _ = ink.text(30, 60 + line_h * 2,  "asdfghjkl;'\\");
    _ = ink.text(30, 60 + line_h * 3,  "`zxcvbnm,./");
    _ = ink.text(30, 60 + line_h * 4,  "!@#$%^&*()_+");
    _ = ink.text(30, 60 + line_h * 5,  "QWERTYUIOP{}");
    _ = ink.text(30, 60 + line_h * 6,  "ASDFGHJKL:\"|");
    _ = ink.text(30, 60 + line_h * 7,  "~ZXCVBNM<>?");

    try win.endFrame(frame);
  }
}
