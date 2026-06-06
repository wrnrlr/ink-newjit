/// GPU immediate-mode extension for ink.
///
/// Provides direct access to the fill.wgsl triangle pipeline so K code can
/// draw pre-tessellated geometry without going through the high-level path API.
///
/// ── K API (once wired into the runtime) ──────────────────────────────────────
///
///   (gpu`tri) (verts; frag)
///     Draw triangles directly.
///     verts — Nx4 float matrix, each row [x, y, u, v]:
///               x, y  screen position (pixels, top-left origin)
///               u     0.5 for solid interior
///               v     1.0 full opacity, 0.0 AA fringe
///     frag  — 44 floats (11 vec4 rows matching FragUniforms in fill.wgsl)
///
///   (gpu`tess) pts
///     Tessellate a polygon to triangles.
///     pts    — Nx2 float matrix [x, y] polygon vertices
///     result — Mx4 float matrix triangle vertices (u=0.5, v=1.0)
///
/// ── Initialization ────────────────────────────────────────────────────────────
///
///   Called by the runtime (window.zig) before the first frame:
///     gpu_set_renderer(renderer_ptr, width, height)
///
/// ── FragUniforms quick reference ─────────────────────────────────────────────
///
///   Solid color at (r,g,b,a):
///     frag[0] = 1 0 0 0   ; scissor matrix identity col0
///     frag[1] = 0 1 0 0   ; col1
///     frag[2] = 0 0 1 0   ; col2
///     frag[3] = 1 0 0 0   ; paint matrix identity col0
///     frag[4] = 0 1 0 0   ; col1
///     frag[5] = 0 0 1 0   ; col2
///     frag[6] = r g b a   ; inner color
///     frag[7] = r g b a   ; outer color (same → solid)
///     frag[8] = 1e10 1e10 1 1  ; no scissor
///     frag[9] = 0 0 0 0   ; extent.x<0.5 → solid branch in shader
///     frag[10]= 0 0 0 0   ; type=0 (gradient path), texType=0
///
///   Linear gradient from (x0,y0) to (x1,y1), color c0→c1:
///     Build the 3x3 inverse paint matrix mapping screen→paint space,
///     set frag[6]=c0, frag[7]=c1, frag[9]=[half_len, 0, 0, feather].

const std = @import("std");
const Alloc = std.mem.Allocator;
const render = @import("render.zig");
const Renderer = render.Renderer;
const Vertex = render.Vertex;
const FragUniforms = render.FragUniforms;
const tri = @import("triangulate.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

var g_renderer: ?*Renderer = null;
var g_width: f32 = 800;
var g_height: f32 = 600;

// ── Runtime-facing init ───────────────────────────────────────────────────────

/// Called by the ink runtime after creating the Renderer.
/// `renderer` is a *Renderer cast to *anyopaque.
pub export fn gpu_set_renderer(renderer: *anyopaque, width: f32, height: f32) callconv(.C) void {
  g_renderer = @ptrCast(@alignCast(renderer));
  g_width = width;
  g_height = height;
}

/// Update viewport size (call on window resize).
pub export fn gpu_set_view(width: f32, height: f32) callconv(.C) void {
  g_width = width;
  g_height = height;
}

// ── K verbs ───────────────────────────────────────────────────────────────────

/// Draw pre-tessellated triangles.
///
/// verts     pointer to n_verts * 4 f32 values [x, y, u, v per vertex]
/// n_verts   vertex count (must be a multiple of 3)
/// frag      pointer to 44 f32 values (11 vec4 rows of FragUniforms)
///
/// Returns 0 on success, negative on error.
pub export fn gpu_tri(
  verts: [*]const f32,
  n_verts: usize,
  frag: [*]const f32,
) callconv(.C) i32 {
  const r = g_renderer orelse return -1;
  const alloc = gpa.allocator();

  const vbuf = alloc.alloc(Vertex, n_verts) catch return -2;
  defer alloc.free(vbuf);
  for (0..n_verts) |i| {
    vbuf[i] = .{
      .x = verts[i * 4 + 0],
      .y = verts[i * 4 + 1],
      .u = verts[i * 4 + 2],
      .v = verts[i * 4 + 3],
    };
  }

  var fu: FragUniforms = undefined;
  for (0..11) |i| {
    fu.frag[i] = .{
      frag[i * 4 + 0], frag[i * 4 + 1],
      frag[i * 4 + 2], frag[i * 4 + 3],
    };
  }

  r.draw(vbuf, fu) catch return -3;
  return 0;
}

/// Tessellate a single polygon contour to triangles (ear clipping).
///
/// pts       pointer to n_pts * 2 f32 values [x, y per point]
/// n_pts     polygon vertex count
/// out       output buffer for triangle vertices (Nx4 f32, u=0.5, v=1.0)
/// out_cap   capacity of `out` in number of vertices
///
/// Returns number of vertices written (multiple of 3), or -1 on error.
pub export fn gpu_tess(
  pts: [*]const f32,
  n_pts: usize,
  out: [*]f32,
  out_cap: usize,
) callconv(.C) i32 {
  const alloc = gpa.allocator();

  const contour = alloc.alloc(tri.Pt, n_pts) catch return -1;
  defer alloc.free(contour);
  for (0..n_pts) |i| {
    contour[i] = .{ .x = pts[i * 2], .y = pts[i * 2 + 1] };
  }

  var out_list = std.ArrayList(tri.Pt).init(alloc);
  defer out_list.deinit();

  const contours = [1]tri.Contour{.{ .pts = contour }};
  tri.triangulate(alloc, &contours, &out_list) catch return -1;

  const n_out = @min(out_list.items.len, out_cap);
  for (0..n_out) |i| {
    out[i * 4 + 0] = out_list.items[i].x;
    out[i * 4 + 1] = out_list.items[i].y;
    out[i * 4 + 2] = 0.5; // u: solid interior
    out[i * 4 + 3] = 1.0; // v: full opacity
  }
  return @intCast(n_out);
}

/// Tessellate multiple contours (with holes) to triangles.
///
/// pts_ptr   contiguous f32 buffer: [contour0_pt0_x, contour0_pt0_y, ...], contour1...
/// counts    array of n_contours point counts
/// out       output buffer for triangle vertices (Nx4 f32)
/// out_cap   capacity of `out` in vertices
///
/// Returns vertex count written, or -1 on error.
pub export fn gpu_tess_multi(
  pts_ptr: [*]const f32,
  counts: [*]const usize,
  n_contours: usize,
  out: [*]f32,
  out_cap: usize,
) callconv(.C) i32 {
  const alloc = gpa.allocator();

  var contour_list = std.ArrayList(tri.Contour).initCapacity(alloc, n_contours) catch return -1;
  defer {
    for (contour_list.items) |c| alloc.free(c.pts);
    contour_list.deinit();
  }

  var flat_offset: usize = 0;
  for (0..n_contours) |ci| {
    const n = counts[ci];
    const buf = alloc.alloc(tri.Pt, n) catch return -1;
    for (0..n) |i| {
      buf[i] = .{ .x = pts_ptr[(flat_offset + i) * 2], .y = pts_ptr[(flat_offset + i) * 2 + 1] };
    }
    flat_offset += n;
    contour_list.append(.{ .pts = buf }) catch return -1;
  }

  var out_list = std.ArrayList(tri.Pt).init(alloc);
  defer out_list.deinit();

  tri.triangulate(alloc, contour_list.items, &out_list) catch return -1;

  const n_out = @min(out_list.items.len, out_cap);
  for (0..n_out) |i| {
    out[i * 4 + 0] = out_list.items[i].x;
    out[i * 4 + 1] = out_list.items[i].y;
    out[i * 4 + 2] = 0.5;
    out[i * 4 + 3] = 1.0;
  }
  return @intCast(n_out);
}

// ── Extension entry point ─────────────────────────────────────────────────────

/// Called by ExtRegistry.load() when the extension .so is loaded.
/// Verb registration happens here once the runtime provides a hook.
pub export fn terse_init(reg: *anyopaque) callconv(.C) void {
  _ = reg;
  // TODO: register `gpu` namespace verbs via VM extension API
}
