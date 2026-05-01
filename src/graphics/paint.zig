const std = @import("std");
const ink = @import("draw.zig");
const colors = @import("color.zig");
const render = @import("render.zig");
const shape = @import("shape.zig");
const impl = @import("font.zig");
const tatfi = @import("tatfi");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const triangulate = @import("triangulate.zig");

pub const Paint = ink.Paint;
pub const Scissor = ink.Scissor;
pub const Renderer = render.Renderer;
pub const DrawKind = render.DrawKind;
pub const ViewUniforms = render.ViewUniforms;
pub const FragUniforms = render.FragUniforms;
pub const DrawCall = render.DrawCall;
const Vertex = render.Vertex;

const PointFlags = packed struct(u8) {
  corner: bool = false,
  left: bool = false,
  bevel: bool = false,
  innerbevel: bool = false,
  _padding: u4 = 0,
};

const Point = struct {
  x: f32, y: f32, dx: f32, dy: f32,
  len: f32, dmx: f32, dmy: f32,
  flags: PointFlags,
};

pub const State = struct {
  fill: Paint,
  stroke: Paint,
  stroke_width: f32,
  miter_limit: f32,
  line_join: ink.LineJoin,
  line_cap: ink.LineCap,
  alpha: f32,
  xform: [6]f32,
  scissor: Scissor,
  font_size: f32,
  letter_spacing: f32,
  line_height: f32,
  font_blur: f32,
  text_align: ink.TextAlign,
  font_id: i32 = -1,

  pub fn init(dpr: f32) State {
    return .{
      .fill = .{},
      .stroke = .{},
      .stroke_width = 1.0,
      .miter_limit = 10.0,
      .line_join = .miter,
      .line_cap = .butt,
      .alpha = 1.0,
      .xform = .{ dpr, 0, 0, dpr, 0, 0 },
      .scissor = .{ .xform = .{ 0, 0, 0, 0, 0, 0 }, .extent = .{ -1, -1 } },
      .font_size = 16.0,
      .letter_spacing = 0,
      .line_height = 1.0,
      .font_blur = 0,
      .text_align = .{},
    };
  }
};

pub fn xformIdentity(xform: *[6]f32) void {
  xform[0] = 1.0; xform[1] = 0.0;
  xform[2] = 0.0; xform[3] = 1.0;
  xform[4] = 0.0; xform[5] = 0.0;
}

pub fn xformTranslate(xform: *[6]f32, tx: f32, ty: f32) void {
  xform[0] = 1.0; xform[1] = 0.0;
  xform[2] = 0.0; xform[3] = 1.0;
  xform[4] = tx;  xform[5] = ty;
}

pub fn xformScale(xform: *[6]f32, sx: f32, sy: f32) void {
  xform[0] = sx;  xform[1] = 0.0;
  xform[2] = 0.0; xform[3] = sy;
  xform[4] = 0.0; xform[5] = 0.0;
}

pub fn xformRotate(xform: *[6]f32, a: f32) void {
  const cs = @cos(a);
  const sn = @sin(a);
  xform[0] = cs;  xform[1] = sn;
  xform[2] = -sn; xform[3] = cs;
  xform[4] = 0.0; xform[5] = 0.0;
}

pub fn xformInverse(inv: *[6]f32, t: [6]f32) bool {
  const det = @as(f64, t[0]) * t[3] - @as(f64, t[2]) * t[1];
  if (det > -1e-6 and det < 1e-6) {
    xformIdentity(inv);
    return false;
  }
  const invDet = 1.0 / det;
  inv[0] = @floatCast(t[3] * invDet);
  inv[1] = @floatCast(-t[1] * invDet);
  inv[2] = @floatCast(-t[2] * invDet);
  inv[3] = @floatCast(t[0] * invDet);
  inv[4] = @floatCast((@as(f64, t[2]) * t[5] - @as(f64, t[3]) * t[4]) * invDet);
  inv[5] = @floatCast((@as(f64, t[1]) * t[4] - @as(f64, t[0]) * t[5]) * invDet);
  return true;
}

pub fn xformMultiply(res: *[6]f32, t: [6]f32) void {
  const t0 = res[0] * t[0] + res[1] * t[2];
  const t1 = res[0] * t[1] + res[1] * t[3];
  const t2 = res[2] * t[0] + res[3] * t[2];
  const t3 = res[2] * t[1] + res[3] * t[3];
  const t4 = res[4] * t[0] + res[5] * t[2] + t[4];
  const t5 = res[4] * t[1] + res[5] * t[3] + t[5];
  res[0] = t0; res[1] = t1;
  res[2] = t2; res[3] = t3;
  res[4] = t4; res[5] = t5;
}

pub const Cmd = enum(i32) {
  move = 0,
  line = 1,
  bezier = 2,
  close = 3,
  winding = 4,
};

pub const Gx = struct {
  allocator: Alloc,
  renderer: ?*Renderer = null,
  shape_ctx: *shape.ShapeContext,
  commands: ArrayList(f32),
  commandx: f32 = 0,
  commandy: f32 = 0,
  states: ArrayList(State),
  cache: PathCache,
  glyph_verts: std.AutoHashMap(GlyphKey, []Vertex),
  shape_cache: std.AutoHashMap(ShapeKey, []ShapedGlyph),
  line_verts: std.AutoHashMap(LineKey, []Vertex),
  tess_tol: f32 = 0.25,
  dist_tol: f32 = 0.01,
  dpr: f32 = 1,

  pub fn init(allocator: Alloc) !Gx {
    var states = try ArrayList(State).initCapacity(allocator, 0);
    try states.append(allocator, State.init(1.0));
    return .{
      .allocator = allocator,
      .renderer = null,
      .commands = try ArrayList(f32).initCapacity(allocator, 0),
      .states = states,
      .cache = try PathCache.init(allocator),
      .glyph_verts = std.AutoHashMap(GlyphKey, []Vertex).init(allocator),
      .shape_cache = std.AutoHashMap(ShapeKey, []ShapedGlyph).init(allocator),
      .line_verts = std.AutoHashMap(LineKey, []Vertex).init(allocator),
      .shape_ctx = impl.createContext(null, null) orelse return error.ShapeContextFailed,
    };
  }

  pub fn setRenderer(self: *Gx, renderer: *Renderer) void {
    self.renderer = renderer;
  }

  pub fn setDpr(self: *Gx, dpr: f32) void {
    self.dpr = dpr;
    self.getState().xform[0] = dpr;
    self.getState().xform[3] = dpr;
  }

  pub fn deinit(self: *Gx) void {
    impl.destroyContext(self.shape_ctx);
    self.commands.deinit(self.allocator);
    self.states.deinit(self.allocator);
    self.cache.deinit(self.allocator);
    var it = self.glyph_verts.iterator();
    while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
    self.glyph_verts.deinit();
    var sc_it = self.shape_cache.iterator();
    while (sc_it.next()) |entry| self.allocator.free(entry.value_ptr.*);
    self.shape_cache.deinit();
    var lv_it = self.line_verts.iterator();
    while (lv_it.next()) |entry| self.allocator.free(entry.value_ptr.*);
    self.line_verts.deinit();
  }

  pub fn getState(self: *Gx) *State {
    return &self.states.items[self.states.items.len - 1];
  }

  pub fn save(self: *Gx) !void {
    try self.states.append(self.allocator, self.getState().*);
  }

  pub fn restore(self: *Gx) void {
    if (self.states.items.len > 1) {
      _ = self.states.pop();
    }
  }

  pub fn reset(self: *Gx) void {
    self.states.clearRetainingCapacity();
    self.states.append(self.allocator, State.init(self.dpr)) catch unreachable;
    self.commands.clearRetainingCapacity();
    self.commandx = 0;
    self.commandy = 0;
  }

  // --- Path API ---

  pub fn beginPath(self: *Gx) void {
    self.commands.clearRetainingCapacity();
    self.commandx = 0;
    self.commandy = 0;
  }

  pub fn moveTo(self: *Gx, x: f32, y: f32) !void {
    try self.commands.append(self.allocator, @floatFromInt(@intFromEnum(Cmd.move)));
    try self.commands.append(self.allocator, x);
    try self.commands.append(self.allocator, y);
    self.commandx = x;
    self.commandy = y;
  }

  pub fn lineTo(self: *Gx, x: f32, y: f32) !void {
    try self.commands.append(self.allocator, @floatFromInt(@intFromEnum(Cmd.line)));
    try self.commands.append(self.allocator, x);
    try self.commands.append(self.allocator, y);
    self.commandx = x;
    self.commandy = y;
  }

  pub fn bezierTo(self: *Gx, cp1x: f32, cp1y: f32, cp2x: f32, cp2y: f32, x: f32, y: f32) !void {
    try self.commands.append(self.allocator, @floatFromInt(@intFromEnum(Cmd.bezier)));
    try self.commands.append(self.allocator, cp1x);
    try self.commands.append(self.allocator, cp1y);
    try self.commands.append(self.allocator, cp2x);
    try self.commands.append(self.allocator, cp2y);
    try self.commands.append(self.allocator, x);
    try self.commands.append(self.allocator, y);
    self.commandx = x;
    self.commandy = y;
  }

  pub fn quadTo(self: *Gx, cpx: f32, cpy: f32, x: f32, y: f32) !void {
    const x0 = self.commandx;
    const y0 = self.commandy;
    try self.bezierTo(
      x0 + 2.0 / 3.0 * (cpx - x0),
      y0 + 2.0 / 3.0 * (cpy - y0),
      x + 2.0 / 3.0 * (cpx - x),
      y + 2.0 / 3.0 * (cpy - y),
      x,
      y,
    );
  }

  pub fn closePath(self: *Gx) !void {
    try self.commands.append(self.allocator, @floatFromInt(@intFromEnum(Cmd.close)));
  }

  pub fn pathWinding(self: *Gx, winding: ink.Winding) !void {
    try self.commands.append(self.allocator, @floatFromInt(@intFromEnum(Cmd.winding)));
    try self.commands.append(self.allocator, @floatFromInt(@intFromEnum(winding)));
  }

  pub fn rect(self: *Gx, x: f32, y: f32, w: f32, h: f32) !void {
    try self.moveTo(x, y);
    try self.lineTo(x, y + h);
    try self.lineTo(x + w, y + h);
    try self.lineTo(x + w, y);
    try self.closePath();
  }

  pub fn roundedRect(self: *Gx, x: f32, y: f32, w: f32, h: f32, r: f32) !void {
    if (r <= 0) {
      try self.rect(x, y, w, h);
    } else {
      const rad = @min(r, @min(w, h) * 0.5);
      try self.moveTo(x, y + rad);
      try self.lineTo(x, y + h - rad);
      try self.quadTo(x, y + h, x + rad, y + h);
      try self.lineTo(x + w - rad, y + h);
      try self.quadTo(x + w, y + h, x + w, y + h - rad);
      try self.lineTo(x + w, y + rad);
      try self.quadTo(x + w, y, x + w - rad, y);
      try self.lineTo(x + rad, y);
      try self.quadTo(x, y, x, y + rad);
      try self.closePath();
    }
  }

  pub fn circle(self: *Gx, cx: f32, cy: f32, r: f32) !void {
    const k: f32 = 0.5522847498;
    try self.moveTo(cx + r, cy);
    try self.bezierTo(cx + r, cy + k * r, cx + k * r, cy + r, cx, cy + r);
    try self.bezierTo(cx - k * r, cy + r, cx - r, cy + k * r, cx - r, cy);
    try self.bezierTo(cx - r, cy - k * r, cx - k * r, cy - r, cx, cy - r);
    try self.bezierTo(cx + k * r, cy - r, cx + r, cy - k * r, cx + r, cy);
    try self.closePath();
  }

  pub fn ellipse(self: *Gx, cx: f32, cy: f32, rx: f32, ry: f32) !void {
    const k: f32 = 0.5522847498;
    try self.moveTo(cx + rx, cy);
    try self.bezierTo(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry);
    try self.bezierTo(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy);
    try self.bezierTo(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry);
    try self.bezierTo(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy);
    try self.closePath();
  }

  // --- State Setup ---

  pub fn fillColor(self: *Gx, color: colors.Lch) void {
    var state = self.getState();
    state.fill.inner = color;
    state.fill.outer = color;
    state.fill.image = .{ .handle = 0 };
  }

  pub fn fillPaint(self: *Gx, paint: Paint) void {
    var state = self.getState();
    state.fill = paint;
  }

  pub fn strokeColor(self: *Gx, color: colors.Lch) void {
    var state = self.getState();
    state.stroke.inner = color;
    state.stroke.outer = color;
    state.stroke.image = .{ .handle = 0 };
  }

  pub fn strokeWidth(self: *Gx, width: f32) void {
    self.getState().stroke_width = width;
  }

  pub fn translate(self: *Gx, x: f32, y: f32) void {
    var t = [_]f32{0} ** 6;
    xformTranslate(&t, x * self.dpr, y * self.dpr);
    xformMultiply(&self.getState().xform, t);
  }

  pub fn scale(self: *Gx, x: f32, y: f32) void {
    var t = [_]f32{0} ** 6;
    xformScale(&t, x, y);
    xformMultiply(&self.getState().xform, t);
  }

  pub fn rotate(self: *Gx, angle: f32) void {
    var t = [_]f32{0} ** 6;
    xformRotate(&t, angle);
    xformMultiply(&self.getState().xform, t);
  }

  pub fn linearGradient(self: *Gx, sx: f32, sy: f32, ex: f32, ey: f32, icol: colors.Lch, ocol: colors.Lch) ink.Paint {
    const large: f32 = 1e5;
    var p = ink.Paint{};
    const dx = ex - sx;
    const dy = ey - sy;
    const d = @sqrt(dx * dx + dy * dy);
    var xf = [_]f32{0} ** 6;

    const dx_n = if (d > 0.0001) dx / d else 0.0;
    const dy_n = if (d > 0.0001) dy / d else 1.0;

    // Gradient runs along v axis (second column). Use large offset so sdroundrect
    // gives -d/2 at start and +d/2 at end, blending correctly with feather=d.
    xf[0] = dy_n;  xf[1] = -dx_n;
    xf[2] = dx_n;  xf[3] = dy_n;
    xf[4] = (sx - dx_n * large) * self.dpr;
    xf[5] = (sy - dy_n * large) * self.dpr;

    p.xform = xf;
    p.extent[0] = large;
    p.extent[1] = large + d * 0.5;
    p.radius = 0.0;
    p.feather = @max(1.0, d);
    p.inner = icol;
    p.outer = ocol;
    return p;
  }

  pub fn radialGradient(self: *Gx, cx: f32, cy: f32, inr: f32, outr: f32, icol: colors.Lch, ocol: colors.Lch) ink.Paint {
    var p = ink.Paint{};
    const r = (inr + outr) * 0.5;
    const f = outr - inr;
    xformIdentity(&p.xform);
    p.xform[4] = cx * self.dpr;
    p.xform[5] = cy * self.dpr;
    p.extent[0] = r;
    p.extent[1] = r;
    p.radius = r;
    p.feather = @max(1.0, f);
    p.inner = icol;
    p.outer = ocol;
    return p;
  }

  pub fn boxGradient(self: *Gx, x: f32, y: f32, w: f32, h: f32, r: f32, f: f32, icol: colors.Lch, ocol: colors.Lch) ink.Paint {
    var p = ink.Paint{};
    xformIdentity(&p.xform);
    p.xform[4] = (x + w * 0.5) * self.dpr;
    p.xform[5] = (y + h * 0.5) * self.dpr;
    p.extent[0] = w * 0.5;
    p.extent[1] = h * 0.5;
    p.radius = r;
    p.feather = f;
    p.inner = icol;
    p.outer = ocol;
    return p;
  }

  pub fn imagePattern(self: *Gx, cx: f32, cy: f32, w: f32, h: f32, angle: f32, image: ink.Img, alpha: f32) ink.Paint {
    var p = ink.Paint{};
    var rot = [_]f32{0} ** 6;
    xformRotate(&rot, angle);
    xformIdentity(&p.xform);
    xformMultiply(&p.xform, rot);
    p.xform[4] = cx;
    p.xform[5] = cy;
    p.extent[0] = w;
    p.extent[1] = h;
    p.image = image;
    p.inner = .{ .l = alpha, .c = alpha, .h = alpha };
    p.outer = .{ .l = alpha, .c = alpha, .h = alpha };
    _ = self;
    return p;
  }

  pub fn createShader(self: *Gx, source: []const u8) i32 {
    if (self.renderer) |r| {
      return r.createShader(source) catch -1;
    }
    return -1;
  }

  pub fn createFont(self: *Gx, name: []const u8, filename: [*:0]const u8) i32 {
    _ = name;
    if (impl.shapePushFontFromFile(self.shape_ctx, filename, 0) != null) {
      return 0; // For now just return 0, we'll need a real ID system later
    }
    return -1;
  }

  pub fn fontSize(self: *Gx, size: f32) void {
    self.getState().font_size = size;
  }

  pub fn fontFace(self: *Gx, font: []const u8) void {
    _ = self;
    _ = font;
    // self.getState().font_id = ...
  }

  pub fn textAlign(self: *Gx, align_flags: ink.TextAlign) void {
    self.getState().text_align = align_flags;
  }

  fn shapeSetup(self: *Gx, string: []const u8) void {
    impl.shapeBegin(self.shape_ctx, .dont_know, .dont_know);
    impl.shapeUtf8(self.shape_ctx, string.ptr, @intCast(string.len), .codepoint_index);
    impl.shapeEnd(self.shape_ctx);
  }

  fn glyphAdvanceWidth(self: *Gx, font_size: f32) f32 {
    var total: f32 = 0;
    var run: shape.Run = undefined;
    while (impl.shapeRun(self.shape_ctx, &run) != 0) {
      const font = run.font orelse continue;
      const tf: *impl.TatfiFont = @ptrCast(@alignCast(font.user_data orelse continue));
      const fscale = font_size / @as(f32, @floatFromInt(tf.face.units_per_em()));
      var glyph: ?*shape.Glyph = null;
      while (impl.glyphIteratorNext(&run.glyphs, &glyph) != 0)
        total += @as(f32, @floatFromInt(glyph.?.advance_x)) * fscale;
    }
    return total;
  }

  // Returns cached fill+fringe vertices for a glyph in local DPR-scaled space (origin at 0,0).
  fn getOrCacheGlyph(self: *Gx, glyph_id: u16, tf: *impl.TatfiFont, fscale: f32) ![]const Vertex {
    const key = GlyphKey{
      .glyph_id = glyph_id,
      .scale_bits = @bitCast(fscale * self.dpr),
      .face = @intFromPtr(tf),
    };
    if (self.glyph_verts.get(key)) |cached| return cached;

    // Generate verts with glyph origin at (0,0), stripping state translation.
    self.commands.clearRetainingCapacity();
    self.commandx = 0;
    self.commandy = 0;
    var ctx = OutlineCtx{ .gx = self, .gx_ = 0, .gy_ = 0, .scale = fscale };
    const state = self.getState();
    const saved_tx = state.xform[4];
    const saved_ty = state.xform[5];
    state.xform[4] = 0;
    state.xform[5] = 0;
    _ = tf.face.outline_glyph(self.allocator, .{glyph_id}, ctx.builder());

    var tmp = try ArrayList(Vertex).initCapacity(self.allocator, 0);
    defer tmp.deinit(self.allocator);
    try self.appendFillVerts(&tmp);  // flattenPath → addPoint uses xform[4]=0, xform[5]=0

    state.xform[4] = saved_tx;
    state.xform[5] = saved_ty;

    const owned = try self.allocator.dupe(Vertex, tmp.items);
    try self.glyph_verts.put(key, owned);
    return owned;
  }

  pub fn text(self: *Gx, x: f32, y: f32, string: []const u8) !f32 {
    const state = self.getState();
    const dpr = self.dpr;
    const tx = state.xform[4];
    const ty = state.xform[5];

    // Shape cache: avoids HarfBuzz reshaping for unchanged strings
    const shape_key = ShapeKey{
      .str_hash = std.hash.Wyhash.hash(0, string),
      .font_size_bits = @bitCast(state.font_size),
      .font_id = state.font_id,
    };
    const shaped: []ShapedGlyph = if (self.shape_cache.get(shape_key)) |hit| hit else blk: {
      self.shapeSetup(string);
      var tmp = try ArrayList(ShapedGlyph).initCapacity(self.allocator, 0);
      defer tmp.deinit(self.allocator);
      var run: shape.Run = undefined;
      while (impl.shapeRun(self.shape_ctx, &run) != 0) {
        const font = run.font orelse continue;
        const tf: *impl.TatfiFont = @ptrCast(@alignCast(font.user_data orelse continue));
        const fscale = state.font_size / @as(f32, @floatFromInt(tf.face.units_per_em()));
        var glyph: ?*shape.Glyph = null;
        while (impl.glyphIteratorNext(&run.glyphs, &glyph) != 0) {
          const g = glyph.?;
          try tmp.append(self.allocator, .{
            .id = g.id, .tf = tf, .fscale = fscale,
            .offset_x = g.offset_x, .offset_y = g.offset_y, .advance_x = g.advance_x,
          });
        }
      }
      const owned = try self.allocator.dupe(ShapedGlyph, tmp.items);
      try self.shape_cache.put(shape_key, owned);
      break :blk owned;
    };

    // Compute total advance for alignment
    var total_advance: f32 = 0;
    for (shaped) |g| total_advance += @as(f32, @floatFromInt(g.advance_x)) * g.fscale;
    const start_x: f32 = switch (state.text_align.horizontal) {
      .left   => x,
      .center => x - total_advance / 2,
      .right  => x - total_advance,
    };

    // Line vertex cache: stores baked vertices with tx=ty=0 so only a uniform
    // translation needs to be applied each frame (avoids per-glyph lookup + per-vertex append).
    const line_key = LineKey{
      .str_hash = shape_key.str_hash,
      .x_bits = @bitCast(start_x),
      .y_bits = @bitCast(y),
      .font_size_bits = shape_key.font_size_bits,
      .font_id = shape_key.font_id,
      .dpr_bits = @bitCast(dpr),
    };

    const offset = self.cache.verts.items.len;
    if (self.line_verts.get(line_key)) |base_verts| {
      // Fast path: one alloc + vectorizable loop to apply scroll translation
      const dst = try self.cache.verts.addManyAsSlice(self.allocator, base_verts.len);
      for (dst, base_verts) |*d, s| {
        d.* = .{ .x = s.x + tx, .y = s.y + ty, .u = s.u, .v = s.v };
      }
    } else {
      // Slow path: compute vertices with tx=ty=0, cache them, then apply translation in-place
      const base_start = self.cache.verts.items.len;
      var cursor_x = start_x;
      for (shaped) |g| {
        const glyph_verts = try self.getOrCacheGlyph(g.id, g.tf, g.fscale);
        const ox = (cursor_x + @as(f32, @floatFromInt(g.offset_x)) * g.fscale) * dpr;
        const oy = (y - @as(f32, @floatFromInt(g.offset_y)) * g.fscale) * dpr;
        const dst = try self.cache.verts.addManyAsSlice(self.allocator, glyph_verts.len);
        for (dst, glyph_verts) |*d, s| {
          d.* = .{ .x = s.x + ox, .y = s.y + oy, .u = s.u, .v = s.v };
        }
        cursor_x += @as(f32, @floatFromInt(g.advance_x)) * g.fscale;
      }
      // Cache the base vertices (tx=ty=0) and apply translation in-place
      const base_verts_slice = self.cache.verts.items[base_start..];
      if (base_verts_slice.len > 0) {
        const owned = try self.allocator.dupe(Vertex, base_verts_slice);
        try self.line_verts.put(line_key, owned);
        for (base_verts_slice) |*v| {
          v.x += tx;
          v.y += ty;
        }
      }
    }

    const count = self.cache.verts.items.len - offset;
    if (count > 0) {
      if (self.renderer) |r| try r.draw(self, .fill, offset, count, state.fill);
    }
    return total_advance;
  }

  pub fn textLineHeight(self: *Gx, lh: f32) void {
    self.getState().line_height = lh;
  }

  pub fn fontFaceId(self: *Gx, id: i32) void {
    _ = self; _ = id; // no-op in ink
  }

  // Sets the scissor rectangle in current (local) coordinates
  pub fn scissor(self: *Gx, x: f32, y: f32, w: f32, h: f32) void {
    const state = self.getState();
    const wc = @max(0, w);
    const hc = @max(0, h);
    var t = [6]f32{ 1, 0, 0, 1, x + wc * 0.5, y + hc * 0.5 };
    xformMultiply(&t, state.xform);
    state.scissor.xform = t;
    state.scissor.extent = .{ wc * 0.5, hc * 0.5 };
  }

  // Intersects current scissor with a new rect in current (local) coordinates
  pub fn intersectScissor(self: *Gx, x: f32, y: f32, w: f32, h: f32) void {
    const state = self.getState();
    if (state.scissor.extent[0] < 0) {
      self.scissor(x, y, w, h);
      return;
    }
    var pxform = state.scissor.xform;
    const ex = state.scissor.extent[0];
    const ey = state.scissor.extent[1];
    var invxorm = [_]f32{0} ** 6;
    _ = xformInverse(&invxorm, state.xform);
    xformMultiply(&pxform, invxorm);
    const tex = ex * @abs(pxform[0]) + ey * @abs(pxform[2]);
    const tey = ex * @abs(pxform[1]) + ey * @abs(pxform[3]);
    // Intersect rect [pxform[4]-tex, pxform[5]-tey, tex*2, tey*2] with [x, y, w, h]
    const ax = pxform[4] - tex;
    const ay = pxform[5] - tey;
    const aw = tex * 2;
    const ah = tey * 2;
    const minx = @max(ax, x);
    const miny = @max(ay, y);
    const maxx = @min(ax + aw, x + w);
    const maxy = @min(ay + ah, y + h);
    self.scissor(minx, miny, @max(0, maxx - minx), @max(0, maxy - miny));
  }

  // Returns advance width; fills bounds[4] = [x, approx_top, x+adv, approx_bot]
  pub fn textBounds(self: *Gx, x: f32, y: f32, string: []const u8, bounds: ?*[4]f32) f32 {
    _ = y;
    const state = self.getState();
    self.shapeSetup(string);
    const advance = self.glyphAdvanceWidth(state.font_size);
    if (bounds) |b| {
      b[0] = x;
      b[1] = -(state.font_size * 0.8);
      b[2] = x + advance;
      b[3] = state.font_size * 0.2;
    }
    return advance;
  }

  // Fills positions[] with per-glyph x positions; returns count
  pub fn textGlyphPositions(self: *Gx, x: f32, y: f32, string: []const u8, positions: []ink.GlyphPosition) i32 {
    _ = y;
    const state = self.getState();
    self.shapeSetup(string);
    var cursor_x = x;
    var count: usize = 0;
    var run: shape.Run = undefined;
    while (impl.shapeRun(self.shape_ctx, &run) != 0) {
      const font = run.font orelse continue;
      const tf: *impl.TatfiFont = @ptrCast(@alignCast(font.user_data orelse continue));
      const fscale = state.font_size / @as(f32, @floatFromInt(tf.face.units_per_em()));
      var glyph: ?*shape.Glyph = null;
      while (impl.glyphIteratorNext(&run.glyphs, &glyph) != 0) {
        if (count >= positions.len) break;
        const g = glyph.?;
        const advance = @as(f32, @floatFromInt(g.advance_x)) * fscale;
        const cp_idx = @as(usize, @intCast(@max(0, g.user_id_or_codepoint_index)));
        positions[count] = .{
          .str = string.ptr + @min(cp_idx, string.len),
          .x = cursor_x,
          .minx = cursor_x,
          .maxx = cursor_x + advance,
        };
        cursor_x += advance;
        count += 1;
      }
    }
    return @intCast(count);
  }

  // Word-wrap helper: builds line boundary list; caller must free
  fn wrapLines(self: *Gx, alloc: std.mem.Allocator, string: []const u8, break_w: f32) ![][2]usize {
    const state = self.getState();
    var lines = try std.ArrayList([2]usize).initCapacity(alloc, 0);
    errdefer lines.deinit(alloc);
    var pos: usize = 0;
    var row_start: usize = 0;
    while (pos <= string.len) {
      const at_end = pos == string.len;
      if (at_end or string[pos] == '\n') {
        try lines.append(alloc, .{ row_start, pos });
        row_start = pos + 1;
        pos = row_start;
        continue;
      }
      self.shapeSetup(string[row_start .. pos + 1]);
      const w = self.glyphAdvanceWidth(state.font_size);
      if (w > break_w and pos > row_start) {
        var bp = pos;
        while (bp > row_start and string[bp] != ' ') : (bp -= 1) {}
        if (string[bp] == ' ') {
          try lines.append(alloc, .{ row_start, bp });
          row_start = bp + 1;
        } else {
          try lines.append(alloc, .{ row_start, pos });
          row_start = pos;
        }
        pos = row_start;
        continue;
      }
      pos += 1;
    }
    return lines.toOwnedSlice(alloc);
  }

  // Draws word-wrapped text
  pub fn textBox(self: *Gx, x: f32, y: f32, break_row_width: f32, string: []const u8) !void {
    const state = self.getState();
    const line_h = state.font_size * state.line_height;
    const lines = try self.wrapLines(self.allocator, string, break_row_width);
    defer self.allocator.free(lines);
    for (lines, 0..) |ln, i| {
      try self.text(x, y + @as(f32, @floatFromInt(i)) * line_h, string[ln[0]..ln[1]]);
    }
  }

  // Measures word-wrapped text bounding box; fills bounds[4]
  pub fn textBoxBounds(self: *Gx, x: f32, y: f32, break_row_width: f32, string: []const u8, bounds: *[4]f32) void {
    const state = self.getState();
    const line_h = state.font_size * state.line_height;
    const lines = self.wrapLines(self.allocator, string, break_row_width) catch {
      bounds.* = .{ x, 0, x, 0 };
      return;
    };
    defer self.allocator.free(lines);
    const n: f32 = @floatFromInt(@max(1, lines.len));
    const top = -(state.font_size * 0.8);
    bounds[0] = x;
    bounds[1] = top;
    bounds[2] = x + break_row_width;
    bounds[3] = y + (n - 1.0) * line_h + state.font_size * 0.2;
  }

  const OutlineCtx = struct {
    gx: *Gx,
    gx_: f32,
    gy_: f32,
    scale: f32,

    fn sx(self: *const OutlineCtx, v: f32) f32 { return self.gx_ + v * self.scale; }
    fn sy(self: *const OutlineCtx, v: f32) f32 { return self.gy_ - v * self.scale; }

    fn move_to(ptr: *anyopaque, fx: f32, fy: f32) void {
      const c: *OutlineCtx = @ptrCast(@alignCast(ptr));
      c.gx.moveTo(c.sx(fx), c.sy(fy)) catch {};
    }
    fn line_to(ptr: *anyopaque, fx: f32, fy: f32) void {
      const c: *OutlineCtx = @ptrCast(@alignCast(ptr));
      c.gx.lineTo(c.sx(fx), c.sy(fy)) catch {};
    }
    fn quad_to(ptr: *anyopaque, x1: f32, y1: f32, fx: f32, fy: f32) void {
      const c: *OutlineCtx = @ptrCast(@alignCast(ptr));
      c.gx.quadTo(c.sx(x1), c.sy(y1), c.sx(fx), c.sy(fy)) catch {};
    }
    fn curve_to(ptr: *anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, fx: f32, fy: f32) void {
      const c: *OutlineCtx = @ptrCast(@alignCast(ptr));
      c.gx.bezierTo(c.sx(x1), c.sy(y1), c.sx(x2), c.sy(y2), c.sx(fx), c.sy(fy)) catch {};
    }
    fn close(ptr: *anyopaque) void {
      const c: *OutlineCtx = @ptrCast(@alignCast(ptr));
      c.gx.closePath() catch {};
    }

    fn builder(self: *OutlineCtx) tatfi.OutlineBuilder {
      return .{
        .ptr = self,
        .vtable = .{
          .move_to = move_to,
          .line_to = line_to,
          .quad_to = quad_to,
          .curve_to = curve_to,
          .close = close,
        },
      };
    }
  };

  // --- Path Flattening ---

  fn addPath(self: *Gx) !void {
    try self.cache.paths.append(self.allocator, .{
      .first = self.cache.points.items.len,
      .count = 0,
      .closed = false,
      .nbevel = 0,
    });
  }

  fn addPoint(self: *Gx, x: f32, y: f32, flags: u8) !void {
    if (self.cache.paths.items.len == 0) return;
    const state = self.getState();
    const px = x * state.xform[0] + y * state.xform[2] + state.xform[4];
    const py = x * state.xform[1] + y * state.xform[3] + state.xform[5];

    var path = &self.cache.paths.items[self.cache.paths.items.len - 1];
    if (path.count > 0) {
      const last = self.cache.points.items[self.cache.points.items.len - 1];
      if (std.math.approxEqAbs(f32, px, last.x, self.dist_tol) and std.math.approxEqAbs(f32, py, last.y, self.dist_tol)) {
        self.cache.points.items[self.cache.points.items.len - 1].flags.corner = true;
        return;
      }
    }
    try self.cache.points.append(self.allocator, .{
      .x = px, .y = py,
      .dx = 0, .dy = 0,
      .len = 0, .dmx = 0, .dmy = 0,
      .flags = @bitCast(flags),
    });
    path.count += 1;
  }

  fn flattenBezier(self: *Gx, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, x4: f32, y4: f32, level: i32) !void {
    if (level > 10) return;
    const x12 = (x1 + x2) * 0.5;
    const y12 = (y1 + y2) * 0.5;
    const x23 = (x2 + x3) * 0.5;
    const y23 = (y2 + y3) * 0.5;
    const x34 = (x3 + x4) * 0.5;
    const y34 = (y3 + y4) * 0.5;
    const x123 = (x12 + x23) * 0.5;
    const y123 = (y12 + y23) * 0.5;
    const x234 = (x23 + x34) * 0.5;
    const y234 = (y23 + y34) * 0.5;
    const x1234 = (x123 + x234) * 0.5;
    const y1234 = (y123 + y234) * 0.5;

    const dx = x4 - x1;
    const dy = y4 - y1;
    const d2 = @abs((x2 - x4) * dy - (y2 - y4) * dx);
    const d3 = @abs((x3 - x4) * dy - (y3 - y4) * dx);

    if ((d2 + d3) * (d2 + d3) < self.tess_tol * (dx * dx + dy * dy)) {
      try self.addPoint(x4, y4, 0);
    } else {
      try self.flattenBezier(x1, y1, x12, y12, x123, y123, x1234, y1234, level + 1);
      try self.flattenBezier(x1234, y1234, x234, y234, x34, y34, x4, y4, level + 1);
    }
  }

  fn flattenPath(self: *Gx) !void {
    self.cache.paths.clearRetainingCapacity();
    self.cache.points.clearRetainingCapacity();
    var i: usize = 0;
    var last_x: f32 = 0;
    var last_y: f32 = 0;
    while (i < self.commands.items.len) {
      const cmd = @as(Cmd, @enumFromInt(@as(i32, @intFromFloat(self.commands.items[i]))));
      i += 1;
      switch (cmd) {
        .move => {
          last_x = self.commands.items[i];
          last_y = self.commands.items[i+1];
          try self.addPath();
          try self.addPoint(last_x, last_y, 0);
          i += 2;
        },
        .line => {
          last_x = self.commands.items[i];
          last_y = self.commands.items[i+1];
          try self.addPoint(last_x, last_y, 0);
          i += 2;
        },
        .bezier => {
          try self.flattenBezier(last_x, last_y, self.commands.items[i], self.commands.items[i+1], self.commands.items[i+2], self.commands.items[i+3], self.commands.items[i+4], self.commands.items[i+5], 0);
          last_x = self.commands.items[i+4];
          last_y = self.commands.items[i+5];
          i += 6;
        },
        .close => {
          if (self.cache.paths.items.len > 0) {
            var path = &self.cache.paths.items[self.cache.paths.items.len - 1];
            path.closed = true;
            // Font outlines close back to their start point, so the last
            // commanded endpoint equals the first move_to point. addPoint
            // only deduplicates against the *previous* point, so P0 gets
            // appended twice. Remove the duplicate to avoid a zero-length
            // closing edge that leaves a chip in the triangulation.
            if (path.count >= 2) {
              const first = self.cache.points.items[path.first];
              const last = self.cache.points.items[path.first + path.count - 1];
              if (std.math.approxEqAbs(f32, first.x, last.x, self.dist_tol) and
                  std.math.approxEqAbs(f32, first.y, last.y, self.dist_tol))
              {
                self.cache.points.shrinkRetainingCapacity(self.cache.points.items.len - 1);
                path.count -= 1;
              }
            }
          }
        },
        .winding => {
          const w = @as(ink.Winding, @enumFromInt(@as(i32, @intFromFloat(self.commands.items[i]))));
          if (self.cache.paths.items.len > 0) {
            self.cache.paths.items[self.cache.paths.items.len - 1].winding = w;
          }
          i += 1;
        },
      }
    }
  }

  // --- Triangulation / Rendering ---

  // Runs flattenPath + triangulation + AA fringe, appending resulting vertices to `out`.
  fn appendFillVerts(self: *Gx, out: *ArrayList(Vertex)) !void {
    try self.flattenPath();

    // Build contours from flattened paths
    var contours = try ArrayList(triangulate.Contour).initCapacity(self.allocator, self.cache.paths.items.len);
    defer contours.deinit(self.allocator);

    var pt_bufs = try ArrayList([]triangulate.Pt).initCapacity(self.allocator, self.cache.paths.items.len);
    defer {
      for (pt_bufs.items) |buf| self.allocator.free(buf);
      pt_bufs.deinit(self.allocator);
    }

    for (self.cache.paths.items) |path| {
      if (path.count < 3) continue;
      const pts = try self.allocator.alloc(triangulate.Pt, path.count);
      for (0..path.count) |k| {
        pts[k] = .{
          .x = self.cache.points.items[path.first + k].x,
          .y = self.cache.points.items[path.first + k].y,
        };
      }
      try pt_bufs.append(self.allocator, pts);
      try contours.append(self.allocator, .{ .pts = pts });
    }

    var tri_pts = try ArrayList(triangulate.Pt).initCapacity(self.allocator, 0);
    defer tri_pts.deinit(self.allocator);
    try triangulate.triangulate(self.allocator, contours.items, &tri_pts);

    for (tri_pts.items) |pt| {
      try out.append(self.allocator, .{ .x = pt.x, .y = pt.y, .u = 0.5, .v = 1.0 });
    }

    const fringe: f32 = 1.0;

    var ref_sign: f32 = 1.0;
    {
      var ref_abs: f32 = 0;
      for (self.cache.paths.items) |p| {
        if (p.count < 2) continue;
        const sl = self.cache.points.items[p.first .. p.first + p.count];
        var a: f32 = 0;
        var jj = sl.len - 1;
        for (0..sl.len) |ii| {
          a += (sl[jj].x + sl[ii].x) * (sl[jj].y - sl[ii].y);
          jj = ii;
        }
        if (@abs(a) > ref_abs) {
          ref_abs = @abs(a);
          ref_sign = if (a >= 0) 1.0 else -1.0;
        }
      }
    }

    for (self.cache.paths.items) |path| {
      if (path.count < 2) continue;
      const pts_slice = self.cache.points.items[path.first .. path.first + path.count];
      const n = pts_slice.len;

      var area: f32 = 0;
      {
        var jj = n - 1;
        for (0..n) |ii| {
          area += (pts_slice[jj].x + pts_slice[ii].x) * (pts_slice[jj].y - pts_slice[ii].y);
          jj = ii;
        }
      }
      const path_sign: f32 = if (area >= 0) 1.0 else -1.0;
      const is_hole = path_sign != ref_sign;
      const normal_sign: f32 = if (is_hole) -path_sign else path_sign;

      const tangents = try self.allocator.alloc([2]f32, n);
      defer self.allocator.free(tangents);
      for (0..n) |i| {
        const j = (i + 1) % n;
        var dx = pts_slice[j].x - pts_slice[i].x;
        var dy = pts_slice[j].y - pts_slice[i].y;
        const len = @sqrt(dx * dx + dy * dy);
        if (len > 0.001) { dx /= len; dy /= len; }
        tangents[i] = .{ dx, dy };
      }

      const miters = try self.allocator.alloc([2]f32, n);
      defer self.allocator.free(miters);
      for (0..n) |i| {
        const prev = (i + n - 1) % n;
        const t0 = tangents[prev];
        const t1 = tangents[i];
        var mx = (-t0[1] + -t1[1]) * 0.5 * normal_sign;
        var my = ( t0[0] +  t1[0]) * 0.5 * normal_sign;
        const dmr2 = mx * mx + my * my;
        if (dmr2 > 0.000001) {
          var mscale = 1.0 / dmr2;
          if (mscale > 100.0) mscale = 100.0;
          mx *= mscale;
          my *= mscale;
        }
        miters[i] = .{ mx, my };
      }

      for (0..n) |i| {
        const j = (i + 1) % n;
        const x0 = pts_slice[i].x;  const y0 = pts_slice[i].y;
        const x1 = pts_slice[j].x;  const y1 = pts_slice[j].y;
        const ox0 = x0 + miters[i][0] * fringe;
        const oy0 = y0 + miters[i][1] * fringe;
        const ox1 = x1 + miters[j][0] * fringe;
        const oy1 = y1 + miters[j][1] * fringe;

        try out.append(self.allocator, .{ .x = x0,  .y = y0,  .u = 0.5, .v = 1.0 });
        try out.append(self.allocator, .{ .x = x1,  .y = y1,  .u = 0.5, .v = 1.0 });
        try out.append(self.allocator, .{ .x = ox0, .y = oy0, .u = 0.5, .v = 0.0 });
        try out.append(self.allocator, .{ .x = x1,  .y = y1,  .u = 0.5, .v = 1.0 });
        try out.append(self.allocator, .{ .x = ox1, .y = oy1, .u = 0.5, .v = 0.0 });
        try out.append(self.allocator, .{ .x = ox0, .y = oy0, .u = 0.5, .v = 0.0 });
      }
    }
  }

  pub fn fill(self: *Gx) !void {
    const state = self.getState();
    const offset = self.cache.verts.items.len;
    try self.appendFillVerts(&self.cache.verts);
    const count = self.cache.verts.items.len - offset;
    if (self.renderer) |r| {
      try r.draw(self, .fill, offset, count, state.fill);
    }
  }

  pub fn stroke(self: *Gx) !void {
    try self.flattenPath();
    const state = self.getState();
    const offset = self.cache.verts.items.len;
    const hw = state.stroke_width * 0.5;
    const aa: f32 = 1.0;
    const iw = hw - aa * 0.5; // inner half-width (opaque edge)
    const ow = hw + aa * 0.5; // outer half-width (transparent AA edge)

    for (self.cache.paths.items) |path| {
      if (path.count < 2) continue;
      const pts = self.cache.points.items[path.first .. path.first + path.count];
      const n = pts.len;
      const seg_count = if (path.closed) n else n - 1;

      for (0..seg_count) |i| {
        const j = (i + 1) % n;
        const p0 = pts[i];
        const p1 = pts[j];
        var dx = p1.x - p0.x;
        var dy = p1.y - p0.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 0.001) continue;
        dx /= len;
        dy /= len;
        // Left normal
        const nx = -dy;
        const ny =  dx;

        // Emit 3 quads across the stroke width (outer-aa, inner, outer-aa)
        // left outer → left inner
        try self.cache.verts.append(self.allocator, .{ .x = p0.x + nx * ow, .y = p0.y + ny * ow, .u = 0.5, .v = 0.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p1.x + nx * ow, .y = p1.y + ny * ow, .u = 0.5, .v = 0.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p0.x + nx * iw, .y = p0.y + ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p1.x + nx * ow, .y = p1.y + ny * ow, .u = 0.5, .v = 0.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p1.x + nx * iw, .y = p1.y + ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p0.x + nx * iw, .y = p0.y + ny * iw, .u = 0.5, .v = 1.0 });
        // inner fill
        try self.cache.verts.append(self.allocator, .{ .x = p0.x + nx * iw, .y = p0.y + ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p1.x + nx * iw, .y = p1.y + ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p0.x - nx * iw, .y = p0.y - ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p1.x + nx * iw, .y = p1.y + ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p1.x - nx * iw, .y = p1.y - ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p0.x - nx * iw, .y = p0.y - ny * iw, .u = 0.5, .v = 1.0 });
        // right inner → right outer
        try self.cache.verts.append(self.allocator, .{ .x = p0.x - nx * iw, .y = p0.y - ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p1.x - nx * iw, .y = p1.y - ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p0.x - nx * ow, .y = p0.y - ny * ow, .u = 0.5, .v = 0.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p1.x - nx * iw, .y = p1.y - ny * iw, .u = 0.5, .v = 1.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p1.x - nx * ow, .y = p1.y - ny * ow, .u = 0.5, .v = 0.0 });
        try self.cache.verts.append(self.allocator, .{ .x = p0.x - nx * ow, .y = p0.y - ny * ow, .u = 0.5, .v = 0.0 });
      }
    }

    if (self.renderer) |r| {
      try r.draw(self, .stroke, offset, self.cache.verts.items.len - offset, state.stroke);
    }
  }
};

const PathCache = struct {
  points: ArrayList(Point),
  paths: ArrayList(PathPart),
  verts: ArrayList(Vertex),

  pub fn init(allocator: Alloc) !PathCache {
    return .{
      .points = try ArrayList(Point).initCapacity(allocator, 0),
      .paths = try ArrayList(PathPart).initCapacity(allocator, 0),
      .verts = try ArrayList(Vertex).initCapacity(allocator, 0),
    };
  }

  pub fn deinit(self: *PathCache, allocator: Alloc) void {
    self.points.deinit(allocator);
    self.paths.deinit(allocator);
    self.verts.deinit(allocator);
  }
};

const PathPart = struct {
  first: usize,
  count: usize,
  closed: bool,
  nbevel: usize,
  winding: ink.Winding = .ccw,
};

const GlyphKey = struct {
  glyph_id: u16,
  scale_bits: u32, // @bitCast(fscale * dpr)
  face: usize,     // @intFromPtr(tf)
};

const ShapeKey = struct {
  str_hash: u64,
  font_size_bits: u32,
  font_id: i32,
};

const ShapedGlyph = struct {
  id: u16,
  tf: *impl.TatfiFont,
  fscale: f32,
  offset_x: i32,
  offset_y: i32,
  advance_x: i32,
};

// Key for per-text-call vertex cache (stores verts with tx=ty=0)
const LineKey = struct {
  str_hash: u64,
  x_bits: u32,    // @bitCast(start_x)
  y_bits: u32,    // @bitCast(y)
  font_size_bits: u32,
  font_id: i32,
  dpr_bits: u32,  // @bitCast(dpr)
};
