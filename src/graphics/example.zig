const std = @import("std");

const shape = @import("shape.zig");
const impl = @import("impl.zig");

fn handleText(ctx: *shape.ShapeContext, text: []const u8, lang: shape.Language) void {
  impl.shapeBegin(ctx, .dont_know, lang);
  impl.shapeUtf8(ctx, text.ptr, @intCast(text.len), .codepoint_index);
  impl.shapeEnd(ctx);

  var run: shape.Run = undefined;
  var cursor_x: i32 = 0;
  while (impl.shapeRun(ctx, &run) != 0) {
    if (run.flags & shape.BreakFlags.line_hard != 0) {
      std.debug.print("\n--- new line ---\n", .{});
      cursor_x = 0;
    }
    var glyph: ?*shape.Glyph = null;
    while (impl.glyphIteratorNext(&run.glyphs, &glyph) != 0) {
      const g = glyph.?;
      std.debug.print("  glyph id={d:>4}  advance=({d:>5},{d:>5})  offset=({d:>4},{d:>4})  x={d}\n", .{
        g.id, g.advance_x, g.advance_y, g.offset_x, g.offset_y, cursor_x,
      });
      cursor_x += g.advance_x;
    }
  }
}

pub fn main() !void {
  const ctx = impl.createContext(null, null) orelse {
    std.debug.print("error: failed to create shape context\n", .{});
    return error.ShapeContextFailed;
  };
  defer impl.destroyContext(ctx);

  // Push fonts — use macOS system fonts; adjust paths as needed
  const font_paths = [_][*:0]const u8{
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
  };
  var loaded: usize = 0;
  for (font_paths) |path| {
    if (impl.shapePushFontFromFile(ctx, path, 0) != null) {
      std.debug.print("loaded font: {s}\n", .{path});
      loaded += 1;
    }
  }
  if (loaded == 0) {
    std.debug.print("warning: no fonts loaded, glyphs will have id=0\n", .{});
  }

  std.debug.print("\n=== Latin: \"Hello, world!\" ===\n", .{});
  handleText(ctx, "Hello, world!", .dont_know);

  std.debug.print("\n=== Arabic + Myanmar: mixed script ===\n", .{});
  handleText(ctx, "یکအမည်မရှိیک", .arabic);

  std.debug.print("\n=== Newline handling ===\n", .{});
  handleText(ctx, "line one\nline two\n", .dont_know);
}
