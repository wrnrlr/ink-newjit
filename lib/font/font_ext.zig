/// Font extension for ink — core C-ABI layer.
///
/// Loads TrueType/OpenType/TTC fonts via tatfi and exposes glyph outline data.
/// All metadata (metrics, names, advances) is exposed via pub Zig functions
/// called by lib/font/src/main.zig to build K dicts.

const std = @import("std");
const tatfi = @import("tatfi");

const alloc = std.heap.c_allocator;

// ── Font table ────────────────────────────────────────────────────────────────

const MAX_FONTS = 64;

const FontEntry = struct {
  face: tatfi.Face,
  data: []u8,
};

var fonts: [MAX_FONTS]?FontEntry = [_]?FontEntry{null} ** MAX_FONTS;
var n_fonts: usize = 0;

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Read an entire file into a heap-allocated slice (c_allocator). Caller frees.
pub fn readFileData(path: [*:0]const u8) ![]u8 {
  const io = std.Io.Threaded.global_single_threaded.io();
  return std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(path), alloc,
    std.Io.Limit.limited(256 << 20));
}

/// How many faces are in raw font data (>1 only for TTC collections).
pub fn faceCount(data: []const u8) u32 {
  return tatfi.fonts_in_collection(data) orelse 1;
}

/// Parse a face from data and register it; return the handle.
pub fn storeFace(data: []u8, face_index: u32) !i32 {
  if (n_fonts >= MAX_FONTS) return error.TooManyFonts;
  const face = try tatfi.Face.parse(data, face_index);
  const handle: i32 = @intCast(n_fonts);
  fonts[n_fonts] = .{ .face = face, .data = data };
  n_fonts += 1;
  return handle;
}

fn getEntry(handle: i32) ?*FontEntry {
  if (handle < 0 or handle >= @as(i32, @intCast(n_fonts))) return null;
  return if (fonts[@intCast(handle)]) |*e| e else null;
}

// ── Metadata accessors (called by src/main.zig) ───────────────────────────────

pub fn faceUnitsPerEm(handle: i32) i32 {
  const e = getEntry(handle) orelse return 0;
  return @intCast(e.face.units_per_em());
}

pub fn faceNumGlyphs(handle: i32) i32 {
  const e = getEntry(handle) orelse return 0;
  return @intCast(e.face.number_of_glyphs());
}

pub fn faceAscender(handle: i32) i32 {
  const e = getEntry(handle) orelse return 0;
  return @intCast(e.face.ascender());
}

pub fn faceDescender(handle: i32) i32 {
  const e = getEntry(handle) orelse return 0;
  return @intCast(e.face.descender());
}

pub fn faceLineGap(handle: i32) i32 {
  const e = getEntry(handle) orelse return 0;
  return @intCast(e.face.line_gap());
}

pub fn faceXHeight(handle: i32) i32 {
  const e = getEntry(handle) orelse return 0;
  return @intCast(e.face.x_height() orelse 0);
}

pub fn faceCapHeight(handle: i32) i32 {
  const e = getEntry(handle) orelse return 0;
  return @intCast(e.face.capital_height() orelse 0);
}

pub fn faceWeight(handle: i32) i32 {
  const e = getEntry(handle) orelse return 400;
  return @intCast(e.face.weight().to_number());
}

pub fn faceWidth(handle: i32) i32 {
  const e = getEntry(handle) orelse return 5;
  return @intCast(e.face.width().to_number());
}

/// Returns flags: bit0=bold, bit1=italic, bit2=monospaced, bit3=variable
pub fn faceFlags(handle: i32) i32 {
  const e = getEntry(handle) orelse return 0;
  var f: i32 = 0;
  if (e.face.is_bold())       f |= 1;
  if (e.face.is_italic())     f |= 2;
  if (e.face.is_monospaced()) f |= 4;
  if (e.face.is_variable())   f |= 8;
  return f;
}

/// Get a name string from the name table. Writes UTF-8 into buf; returns slice.
/// Prefers typographic name (id 16/17) over basic name (id 1/2).
pub fn faceName(
  handle: i32,
  basic_id: tatfi.tables.name.NameId,
  typo_id: tatfi.tables.name.NameId,
  buf: []u8,
) []u8 {
  const e = getEntry(handle) orelse return buf[0..0];
  const ns = e.face.names();

  var best: []const u8 = &.{};
  var best_is_unicode = false;

  var it = ns.iterator();
  while (it.next()) |rec| {
    const match = rec.name_id == basic_id or rec.name_id == typo_id;
    if (!match) continue;
    const prefer = rec.name_id == typo_id;
    const is_uni = rec.is_unicode();
    if (best.len > 0 and !prefer and best_is_unicode == is_uni) continue;
    if (best.len > 0 and !prefer and best_is_unicode) continue;
    best = rec.name;
    best_is_unicode = is_uni;
    if (prefer and is_uni) break; // can't do better
  }

  if (best.len == 0) return buf[0..0];

  if (best_is_unicode) {
    // UTF-16BE: decode BMP codepoints into UTF-8
    var j: usize = 0;
    var i: usize = 0;
    while (i + 1 < best.len) : (i += 2) {
      const hi: u16 = best[i];
      const lo: u16 = best[i + 1];
      const cp: u21 = @intCast((hi << 8) | lo);
      if (cp < 0x80) {
        if (j < buf.len) { buf[j] = @intCast(cp); j += 1; }
      } else if (cp < 0x800) {
        if (j + 1 < buf.len) {
          buf[j]   = @intCast(0xC0 | (cp >> 6));
          buf[j+1] = @intCast(0x80 | (cp & 0x3F));
          j += 2;
        }
      } else {
        if (j + 2 < buf.len) {
          buf[j]   = @intCast(0xE0 | (cp >> 12));
          buf[j+1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
          buf[j+2] = @intCast(0x80 | (cp & 0x3F));
          j += 3;
        }
      }
    }
    return buf[0..j];
  } else {
    // Latin-1 / ASCII
    const n = @min(best.len, buf.len);
    @memcpy(buf[0..n], best[0..n]);
    return buf[0..n];
  }
}

/// Horizontal advance for a glyph (in em units). Returns 0 for missing.
pub fn glyphAdvance(handle: i32, glyph_id: u16) i32 {
  const e = getEntry(handle) orelse return 0;
  return @intCast(e.face.glyph_hor_advance(alloc, .{glyph_id}) orelse 0);
}

/// Left side bearing for a glyph (in em units). Returns 0 for missing.
pub fn glyphLsb(handle: i32, glyph_id: u16) i32 {
  const e = getEntry(handle) orelse return 0;
  return @intCast(e.face.glyph_hor_side_bearing(.{glyph_id}) orelse 0);
}

// ── C-ABI exports ─────────────────────────────────────────────────────────────

/// Load all faces from a font file in one pass.
/// Writes handles into out[0..nfaces]. Returns face count or -1 on failure.
pub export fn font_load_all_faces(path: [*:0]const u8, out: [*]i32, out_cap: u32) i32 {
  const data = readFileData(path) catch return -1;
  const n = faceCount(data);
  if (n > out_cap) { alloc.free(data); return -1; }
  // All faces share the same data buffer; only the first handle owns the data.
  for (0..n) |fi| {
    // storeFace takes ownership of data for face 0; subsequent faces get a ref but
    // we keep one data slice alive per entry so free it on failure.
    const face = tatfi.Face.parse(data, @intCast(fi)) catch {
      alloc.free(data);
      return -1;
    };
    if (n_fonts >= MAX_FONTS) { alloc.free(data); return -1; }
    fonts[n_fonts] = .{ .face = face, .data = if (fi == 0) data else &.{} };
    out[fi] = @intCast(n_fonts);
    n_fonts += 1;
  }
  return @intCast(n);
}

/// Load face 0 from a font file. Returns handle or -1 on failure.
pub export fn font_load(path: [*:0]const u8) i32 {
  var h: [1]i32 = .{0};
  return if (font_load_all_faces(path, &h, 1) > 0) h[0] else -1;
}

/// Load a specific face from a font file. Returns handle or -1 on failure.
pub export fn font_load_face(path: [*:0]const u8, face_index: u32) i32 {
  const data = readFileData(path) catch return -1;
  return storeFace(data, face_index) catch { alloc.free(data); return -1; };
}

/// Write font metrics at `size` pixels into `out[0..3]`:
///   out[0] = ascent, out[1] = descent, out[2] = line_gap
pub export fn font_metrics(handle: i32, size: f32, out: *[3]f32) i32 {
  const e = getEntry(handle) orelse return -1;
  const upm: f32 = @floatFromInt(e.face.units_per_em());
  const scale = size / upm;
  out[0] = @as(f32, @floatFromInt(e.face.ascender())) * scale;
  out[1] = @as(f32, @floatFromInt(e.face.descender())) * scale;
  out[2] = @as(f32, @floatFromInt(e.face.line_gap())) * scale;
  return 0;
}

/// Map UTF-8 text to glyph IDs (basic codepoint→glyph, no ligature shaping).
/// Returns glyph count or -1 on error.
pub export fn font_shape(
  handle: i32,
  text: [*]const u8,
  text_len: usize,
  out: [*]u16,
  out_cap: usize,
) i32 {
  const e = getEntry(handle) orelse return -1;

  var count: usize = 0;
  const bytes = text[0..text_len];
  var i: usize = 0;
  while (i < bytes.len and count < out_cap) {
    const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch { i += 1; continue; };
    if (i + len > bytes.len) break;
    const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch { i += len; continue; };
    const gid = e.face.glyph_index(@intCast(cp));
    out[count] = if (gid) |g| g.@"0" else 0;
    count += 1;
    i += len;
  }
  return @intCast(count);
}

// ── Glyph outline collection ──────────────────────────────────────────────────

const OutlineCollector = struct {
  alloc: std.mem.Allocator,
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
      self.contours.append(self.alloc, self.current) catch {};
      self.current = .{ .items = &.{}, .capacity = 0 };
    }
  }

  fn moveTo(ptr: *anyopaque, x: f32, y: f32) void {
    const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
    self.flushCurrent();
    self.current.append(self.alloc, .{ x * self.scale, -y * self.scale }) catch {};
  }
  fn lineTo(ptr: *anyopaque, x: f32, y: f32) void {
    const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
    self.current.append(self.alloc, .{ x * self.scale, -y * self.scale }) catch {};
  }
  fn quadTo(ptr: *anyopaque, x1: f32, y1: f32, x: f32, y: f32) void {
    const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
    const p0 = self.lastPt();
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
      self.current.append(self.alloc, .{ x4, y4 }) catch {};
      return;
    }
    const tol: f32 = 0.25;
    const dx = x4 - x1;
    const dy = y4 - y1;
    const d2 = @abs((x2 - x4) * dy - (y2 - y4) * dx);
    const d3 = @abs((x3 - x4) * dy - (y3 - y4) * dx);
    if ((d2 + d3) * (d2 + d3) < tol * (dx * dx + dy * dy)) {
      self.current.append(self.alloc, .{ x4, y4 }) catch {};
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
  out_pts: ?[*]f32,
  out_counts: ?[*]u32,
  out_n_contours: *u32,
  pts_cap: usize,
) i32 {
  const e = getEntry(handle) orelse return -1;

  const upm: f32 = @floatFromInt(e.face.units_per_em());
  var contours_init = std.ArrayList(std.ArrayList([2]f32)).initCapacity(alloc, 4) catch return -1;
  const current_init = std.ArrayList([2]f32).initCapacity(alloc, 32) catch {
    contours_init.deinit(alloc); return -1;
  };
  var collector = OutlineCollector{
    .alloc    = alloc,
    .contours = contours_init,
    .current  = current_init,
    .scale    = size / upm,
  };
  defer {
    for (collector.contours.items) |*c| c.deinit(alloc);
    collector.contours.deinit(alloc);
    collector.current.deinit(alloc);
  }

  _ = e.face.outline_glyph(alloc, .{glyph_id}, collector.builder());
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
