# Graphics API
Cross platform graphics library in Zig.

```zig
const fonts = @import("ink/graphics/fonts.zig");
const color = @import("ink/graphics/color.zig");
const draw = @import("ink/graphics/draw.zig");
const hal = @import("ink/graphics/hal.zig");

fn main() void {
  var gpa = std.heap.DebugAllocator(.{}){};
  defer _ = gpa.deinit();
  const alloc = gpa.allocator();

  const win = try hal.Window.init(alloc,.{.title="Ink",.width=800,.height=600});
  defer win.deinit(alloc);

  _ = fonts.createFont("sans", "/System/Library/Fonts/Helvetica.ttc");
  // _ = ink.createFont("serif", "/System/Library/Fonts/Helvetica.ttc");

}
```
