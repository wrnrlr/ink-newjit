const std = @import("std");
const Alloc = std.mem.Allocator;

pub const colors = @import("color.zig");
pub const Lch = colors.Lch;
pub const Gx = @import("gx.zig").Gx;
pub const Renderer = @import("gx.zig").Renderer;

// pub const Lab = struct { l: f32 = 0, a: f32 = 0, b: f32 = 0 };
// pub const Lch = struct { l: f32 = 0, c: f32 = 0, h: f32 = 0, a: f32 = 1.0 };

pub const Op = enum(u8) { move, line, quad, bezier, close };
pub const Path = struct { ops: []const Op, points: []const f32 };
pub const Winding = enum(i32) { ccw = 1, cw = 2, direct = 3 };
pub const Solidity = enum(u2) { solid = 1, hole = 2 };

pub const LineCap = enum(u2) { butt, round, square };
pub const LineJoin = enum(u2) { miter, round, bevel };

pub const CompositeOperation = enum(u8) {
  source_over, source_in, source_out, atop,
  destination_over, destination_in, destination_out, destination_atop,
  lighter, copy, xor,
};

pub const CompositeOperationState = struct {
  src_factor: u32,
  dst_factor: u32,
  src_factor_alpha: u32,
  dst_factor_alpha: u32,
};

pub const Img = struct { handle: i32 = 0 };

pub const Paint = struct {
  xform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
  extent: [2]f32 = .{ 0, 0 },
  radius: f32 = 0,
  feather: f32 = 0,
  blur: [2]f32 = .{ 0, 0 },
  inner: Lch = .{},
  outer: Lch = .{},
  image: Img = .{},
  colormap: Img = .{},
};

pub const Scissor = struct {
  xform: [6]f32 = .{ 0, 0, 0, 0, 0, 0 },
  extent: [2]f32 = .{ -1, -1 },
};

pub const GlyphPosition = struct {
  str: [*]const u8,
  x: f32, minx: f32, maxx: f32,
};

pub const TextRow = struct {
  text: []const u8, next: []const u8,
  width: f32, minx: f32, maxx: f32,
};

pub const TextAlign = struct {
  horizontal: enum { left, center, right } = .left,
  vertical: enum { top, middle, bottom, baseline } = .baseline,
};

pub const Ui = struct { x: f32, y: f32, w: f32, h: f32, base: f32 };
pub const Pt = struct { x: f32, y: f32 };
pub const Rect = struct { a: Pt, b: Pt };

pub const Widget = struct {
  w: *const anyopaque,
  draw: *const fn (*const anyopaque, *Gx) Ui,
};

pub const Alignment = enum { start, middle, end, baseline };

pub fn lch(l: f32, c: f32, h: f32) Lch {
  return .{ .l = l, .c = c, .h = h };
}

var g_gx: *Gx = undefined;

pub fn setContext(ctx: *Gx) void {
  g_gx = ctx;
}

pub fn beginPath() void { g_gx.beginPath(); }
pub fn moveTo(x: f32, y: f32) void { g_gx.moveTo(x, y) catch {}; }
pub fn lineTo(x: f32, y: f32) void { g_gx.lineTo(x, y) catch {}; }
pub fn bezierTo(cp1x: f32, cp1y: f32, cp2x: f32, cp2y: f32, x: f32, y: f32) void { g_gx.bezierTo(cp1x, cp1y, cp2x, cp2y, x, y) catch {}; }
pub fn quadTo(cpx: f32, cpy: f32, x: f32, y: f32) void { g_gx.quadTo(cpx, cpy, x, y) catch {}; }
pub fn closePath() void { g_gx.closePath() catch {}; }
pub fn rect(x: f32, y: f32, w: f32, h: f32) void { g_gx.rect(x, y, w, h) catch {}; }
pub fn roundedRect(x: f32, y: f32, w: f32, h: f32, r: f32) void { g_gx.roundedRect(x, y, w, h, r) catch {}; }
pub fn circle(cx: f32, cy: f32, r: f32) void { g_gx.circle(cx, cy, r) catch {}; }
pub fn ellipse(cx: f32, cy: f32, rx: f32, ry: f32) void { g_gx.ellipse(cx, cy, rx, ry) catch {}; }
pub fn fill() void { g_gx.fill() catch {}; }
pub fn stroke() void { g_gx.stroke() catch {}; }
pub fn fillColor(color: Lch) void { g_gx.fillColor(color); }
pub fn fillPaint(paint: Paint) void { g_gx.fillPaint(paint); }
pub fn strokeColor(color: Lch) void { g_gx.strokeColor(color); }
pub fn strokeWidth(width: f32) void { g_gx.strokeWidth(width); }
pub fn save() void { g_gx.save() catch {}; }
pub fn restore() void { g_gx.restore(); }

pub fn translate(x: f32, y: f32) void { g_gx.translate(x, y); }
pub fn scale(x: f32, y: f32) void { g_gx.scale(x, y); }
pub fn rotate(angle: f32) void { g_gx.rotate(angle); }
pub fn setDpr(dpr: f32) void { g_gx.setDpr(dpr); }

pub fn imagePattern(ox: f32, oy: f32, ex: f32, ey: f32, angle: f32, image: Img, alpha: f32) Paint {
  return g_gx.imagePattern(ox, oy, ex, ey, angle, image, alpha);
}

pub fn linearGradient(sx: f32, sy: f32, ex: f32, ey: f32, icol: Lch, ocol: Lch) Paint {
  return g_gx.linearGradient(sx, sy, ex, ey, icol, ocol);
}

pub fn boxGradient(x: f32, y: f32, w: f32, h: f32, r: f32, f: f32, icol: Lch, ocol: Lch) Paint {
  return g_gx.boxGradient(x, y, w, h, r, f, icol, ocol);
}

pub fn radialGradient(cx: f32, cy: f32, inr: f32, outr: f32, icol: Lch, ocol: Lch) Paint {
  return g_gx.radialGradient(cx, cy, inr, outr, icol, ocol);
}

pub fn createFont(name: []const u8, filename: [*:0]const u8) i32 {
  return g_gx.createFont(name, filename);
}

pub fn fontSize(size: f32) void {
  g_gx.fontSize(size);
}

pub fn fontFace(font: []const u8) void {
  g_gx.fontFace(font);
}

pub fn textAlign(align_flags: TextAlign) void {
  g_gx.textAlign(align_flags);
}

pub fn text(x: f32, y: f32, string: []const u8) f32 {
  return g_gx.text(x, y, string) catch 0;
}
pub fn textBounds(x: f32, y: f32, string: []const u8, bounds: ?*[4]f32) f32 {
  return g_gx.textBounds(x, y, string, bounds);
}
pub fn textGlyphPositions(x: f32, y: f32, string: []const u8, positions: []GlyphPosition) i32 {
  return g_gx.textGlyphPositions(x, y, string, positions);
}
pub fn textLineHeight(lh: f32) void { g_gx.textLineHeight(lh); }
pub fn fontFaceId(id: i32) void { g_gx.fontFaceId(id); }
pub fn scissor(x: f32, y: f32, w: f32, h: f32) void { g_gx.scissor(x, y, w, h); }
pub fn intersectScissor(x: f32, y: f32, w: f32, h: f32) void { g_gx.intersectScissor(x, y, w, h); }
pub fn textBox(x: f32, y: f32, break_row_width: f32, string: []const u8) void {
  g_gx.textBox(x, y, break_row_width, string) catch {};
}
pub fn textBoxBounds(x: f32, y: f32, break_row_width: f32, string: []const u8, bounds: *[4]f32) void {
  g_gx.textBoxBounds(x, y, break_row_width, string, bounds);
}

pub fn createImage(filename: [*:0]const u8, image_flags: i32) Img {
  _ = filename; _ = image_flags;
  return .{ .handle = 0 };
}

pub fn createShader(source: []const u8) i32 {
  return g_gx.createShader(source);
}

pub fn shaderPattern(shader: i32) Paint {
  return .{ .image = .{ .handle = -shader } };
}
