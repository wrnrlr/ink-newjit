/// Font extension for ink.
///
/// Loads TrueType/OpenType fonts via tatfi and exposes metrics and glyph
/// outline data that K code can tessellate into triangles for rendering.
///
/// ── K API (once wired into the runtime) ──────────────────────────────────────
///
///   h: (font`load) "/path/to/font.ttf"
///     Load a font file.  Returns an integer handle, or -1 on failure.
///
///   m: (font`metrics) (h; size)
///     Font metrics at the given pixel size.
///     Returns a 3-element float list: (ascent; descent; line_gap)
///
///   ids: (font`shape) (h; text)
///     Map UTF-8 text to a list of glyph IDs (integers).
///     Basic codepoint→glyph mapping; no ligature shaping.
///
///   pts: (font`outline) (h; glyph_id; size)
///     Outline for one glyph at the given pixel size.
///     Returns a list of contours; each contour is an Nx2 float matrix [x,y].
///     Pass the result to (gpu`tess) to triangulate.
///
/// ── Example: render "Hi" at 48px ─────────────────────────────────────────────
///
///   h:    (font`load) "/System/Library/Fonts/Helvetica.ttc"
///   ids:  (font`shape) (h; "Hi")
///   tris: {(gpu`tess) x}'(font`outline)'[(h; ids; 48.)]
///   / Then draw tris with (gpu`tri) and a solidFrag

const std = @import("std");
const Alloc = std.mem.Allocator;
const tatfi = @import("tatfi");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// ── Font table ────────────────────────────────────────────────────────────────

const MAX_FONTS = 64;

const FontEntry = struct {
  face: tatfi.Face,
  data: []u8,
};

var fonts: [MAX_FONTS]?FontEntry = [_]?FontEntry{null} ** MAX_FONTS;
var n_fonts: usize = 0;

// ── C-ABI exports ─────────────────────────────────────────────────────────────

/// Load a font file.  `path` is a null-terminated UTF-8 path.
/// Returns a non-negative handle on success, -1 on failure.
pub export fn font_load(path: [*:0]const u8) callconv(.C) i32 {
  if (n_fonts >= MAX_FONTS) return -1;
  const alloc = gpa.allocator();

  const FILE = std.c.FILE;
  const fseek_fn: *const fn (*FILE, c_long, c_int) callconv(.c) c_int =
    @extern(*const fn (*FILE, c_long, c_int) callconv(.c) c_int, .{ .name = "fseek" });
  const ftell_fn: *const fn (*FILE) callconv(.c) c_long =
    @extern(*const fn (*FILE) callconv(.c) c_long, .{ .name = "ftell" });

  const cfile = std.c.fopen(path, "rb") orelse return -1;
  defer _ = std.c.fclose(cfile);
  _ = fseek_fn(cfile, 0, 2);
  const file_size: usize = @intCast(ftell_fn(cfile));
  _ = fseek_fn(cfile, 0, 0);
  if (file_size == 0) return -1;

  const data = alloc.alloc(u8, file_size) catch return -1;
  errdefer alloc.free(data);
  if (std.c.fread(data.ptr, 1, file_size, cfile) != file_size) {
    alloc.free(data);
    return -1;
  }

  const face = tatfi.Face.parse(data, 0) catch {
    alloc.free(data);
    return -1;
  };

  const handle: i32 = @intCast(n_fonts);
  fonts[n_fonts] = .{ .face = face, .data = data };
  n_fonts += 1;
  return handle;
}

/// Write font metrics at `size` pixels into `out[0..3]`:
///   out[0] = ascent  (positive, pixels above baseline)
///   out[1] = descent (negative, pixels below baseline)
///   out[2] = line_gap
/// Returns 0 on success, -1 on bad handle.
pub export fn font_metrics(handle: i32, size: f32, out: *[3]f32) callconv(.C) i32 {
  if (handle < 0 or handle >= @as(i32, @intCast(n_fonts))) return -1;
  const entry = fonts[@intCast(handle)] orelse return -1;
  const upm: f32 = @floatFromInt(entry.face.units_per_em());
  const scale = size / upm;
  out[0] = @as(f32, @floatFromInt(entry.face.ascender())) * scale;
  out[1] = @as(f32, @floatFromInt(entry.face.descender())) * scale;
  out[2] = @as(f32, @floatFromInt(entry.face.line_gap())) * scale;
  return 0;
}

/// Map UTF-8 text to glyph IDs using basic codepoint→glyph lookup (no shaping).
/// `text` points to `text_len` bytes of UTF-8.
/// Writes glyph IDs (u16) into `out`; returns glyph count, or -1 on error.
/// Missing glyphs map to glyph ID 0 (usually .notdef).
pub export fn font_shape(
  handle: i32,
  text: [*]const u8,
  text_len: usize,
  out: [*]u16,
  out_cap: usize,
) callconv(.C) i32 {
  if (handle < 0 or handle >= @as(i32, @intCast(n_fonts))) return -1;
  const entry = fonts[@intCast(handle)] orelse return -1;

  var count: usize = 0;
  const bytes = text[0..text_len];
  var i: usize = 0;
  while (i < bytes.len and count < out_cap) {
    const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
      i += 1;
      continue;
    };
    if (i + len > bytes.len) break;
    const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
      i += len;
      continue;
    };
    const gid = entry.face.glyph_index(@intCast(cp));
    out[count] = if (gid) |g| g.@"0" else 0;
    count += 1;
    i += len;
  }
  return @intCast(count);
}

// ── Glyph outline collection ──────────────────────────────────────────────────

const OutlineCollector = struct {
  alloc: Alloc,
  contours: std.ArrayList(std.ArrayList([2]f32)),
  current: std.ArrayList([2]f32),
  scale: f32,

  fn lastPt(self: *OutlineCollector) [2]f32 {
    if (self.current.items.len > 0)
      return self.current.items[self.current.items.len - 1];
    return .{ 0, 0 };
  }

  fn flushCurrent(self: *OutlineCollector) void {
    if (self.current.items.len > 0) {
      self.contours.append(self.current) catch {};
      self.current = std.ArrayList([2]f32).init(self.alloc);
    }
  }

  fn moveTo(ptr: *anyopaque, x: f32, y: f32) void {
    const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
    self.flushCurrent();
    self.current.append(.{ x * self.scale, -y * self.scale }) catch {};
  }
  fn lineTo(ptr: *anyopaque, x: f32, y: f32) void {
    const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
    self.current.append(.{ x * self.scale, -y * self.scale }) catch {};
  }
  fn quadTo(ptr: *anyopaque, x1: f32, y1: f32, x: f32, y: f32) void {
    const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
    const p0 = self.lastPt();
    // Elevate quad to cubic then subdivide
    const cx1 = (p0[0] + 2 * x1 * self.scale) / 3;
    const cy1 = (p0[1] + 2 * (-y1 * self.scale)) / 3;
    const cx2 = (2 * x1 * self.scale + x * self.scale) / 3;
    const cy2 = (2 * (-y1 * self.scale) + (-y * self.scale)) / 3;
    self.subdivideCubic(p0[0], p0[1], cx1, cy1, cx2, cy2, x * self.scale, -y * self.scale, 0);
  }
  fn curveTo(ptr: *anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void {
    const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
    const p0 = self.lastPt();
    self.subdivideCubic(
      p0[0], p0[1],
      x1 * self.scale, -y1 * self.scale,
      x2 * self.scale, -y2 * self.scale,
      x  * self.scale, -y  * self.scale, 0,
    );
  }
  fn close(ptr: *anyopaque) void {
    const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
    self.flushCurrent();
  }

  fn subdivideCubic(
    self: *OutlineCollector,
    x1: f32, y1: f32, x2: f32, y2: f32,
    x3: f32, y3: f32, x4: f32, y4: f32,
    level: u32,
  ) void {
    if (level > 5) {
      self.current.append(.{ x4, y4 }) catch {};
      return;
    }
    const tol: f32 = 0.25;
    const dx = x4 - x1;
    const dy = y4 - y1;
    const d2 = @abs((x2 - x4) * dy - (y2 - y4) * dx);
    const d3 = @abs((x3 - x4) * dy - (y3 - y4) * dx);
    if ((d2 + d3) * (d2 + d3) < tol * (dx * dx + dy * dy)) {
      self.current.append(.{ x4, y4 }) catch {};
      return;
    }
    const x12   = (x1 + x2) * 0.5;  const y12   = (y1 + y2) * 0.5;
    const x23   = (x2 + x3) * 0.5;  const y23   = (y2 + y3) * 0.5;
    const x34   = (x3 + x4) * 0.5;  const y34   = (y3 + y4) * 0.5;
    const x123  = (x12 + x23) * 0.5; const y123  = (y12 + y23) * 0.5;
    const x234  = (x23 + x34) * 0.5; const y234  = (y23 + y34) * 0.5;
    const x1234 = (x123+x234) * 0.5; const y1234 = (y123+y234) * 0.5;
    self.subdivideCubic(x1, y1, x12, y12, x123, y123, x1234, y1234, level + 1);
    self.subdivideCubic(x1234, y1234, x234, y234, x34, y34, x4, y4, level + 1);
  }

  fn builder(self: *OutlineCollector) tatfi.OutlineBuilder {
    return .{
      .ptr    = self,
      .vtable = .{
        .move_to  = moveTo,
        .line_to  = lineTo,
        .quad_to  = quadTo,
        .curve_to = curveTo,
        .close    = close,
      },
    };
  }
};

/// Get the outline of a single glyph as flat interleaved [x, y, x, y, ...] arrays.
///
/// Pass out_pts=null to query total point count (return value = total points).
/// Otherwise, writes interleaved x/y pairs into out_pts; out_counts[i] gives
/// the number of points in contour i.
///
/// `out_n_contours` is always set (even in query mode).
/// Returns total points written, or -1 on error.
pub export fn font_glyph_outline(
  handle: i32,
  glyph_id: u16,
  size: f32,
  out_pts: ?[*]f32,     // x0 y0 x1 y1 ... (all contours concatenated)
  out_counts: ?[*]u32,  // point count per contour
  out_n_contours: *u32,
  pts_cap: usize,       // capacity of out_pts in number of [x,y] pairs
) callconv(.C) i32 {
  if (handle < 0 or handle >= @as(i32, @intCast(n_fonts))) return -1;
  const entry = fonts[@intCast(handle)] orelse return -1;
  const alloc = gpa.allocator();

  const upm: f32 = @floatFromInt(entry.face.units_per_em());
  var collector = OutlineCollector{
    .alloc    = alloc,
    .contours = std.ArrayList(std.ArrayList([2]f32)).init(alloc),
    .current  = std.ArrayList([2]f32).init(alloc),
    .scale    = size / upm,
  };
  defer {
    for (collector.contours.items) |*c| c.deinit();
    collector.contours.deinit();
    collector.current.deinit();
  }

  _ = entry.face.outline_glyph(alloc, .{glyph_id}, collector.builder());

  collector.flushCurrent();

  out_n_contours.* = @intCast(collector.contours.items.len);

  if (out_pts == null) {
    var total: i32 = 0;
    for (collector.contours.items) |c| total += @intCast(c.items.len);
    return total;
  }

  var written: usize = 0;
  for (collector.contours.items, 0..) |c, ci| {
    if (out_counts) |oc| oc[ci] = @intCast(c.items.len);
    for (c.items) |pt| {
      if (written >= pts_cap) break;
      out_pts.?[written * 2 + 0] = pt[0];
      out_pts.?[written * 2 + 1] = pt[1];
      written += 1;
    }
  }
  return @intCast(written);
}

// ── Extension entry point ─────────────────────────────────────────────────────

pub export fn terse_init(reg: *anyopaque) callconv(.C) void {
  _ = reg;
  // TODO: register `font` namespace verbs via VM extension API
}
