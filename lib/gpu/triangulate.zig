const std = @import("std");
const Alloc = std.mem.Allocator;

pub const Pt = struct { x: f32, y: f32 };

/// Signed area (shoelace). Positive = CW in y-down screen space = outer contour.
/// Negative = CCW in y-down screen space = hole contour.
pub fn signedArea(pts: []const Pt) f32 {
  var area: f32 = 0;
  const n = pts.len;
  if (n < 2) return 0;
  var j = n - 1;
  for (0..n) |i| {
    area += (pts[j].x + pts[i].x) * (pts[j].y - pts[i].y);
    j = i;
  }
  return area * 0.5;
}

fn cross2d(ax: f32, ay: f32, bx: f32, by: f32) f32 {
  return ax * by - ay * bx;
}

fn ptInTriangle(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, px: f32, py: f32) bool {
  // Strict interior: boundary/edge points do NOT count as inside.
  // This prevents bezier-subdivided nearly-colinear points from falsely
  // rejecting valid ears.
  const d1 = cross2d(bx - ax, by - ay, px - ax, py - ay);
  const d2 = cross2d(cx - bx, cy - by, px - bx, py - by);
  const d3 = cross2d(ax - cx, ay - cy, px - cx, py - cy);
  return (d1 > 0 and d2 > 0 and d3 > 0) or (d1 < 0 and d2 < 0 and d3 < 0);
}

/// Find rightmost vertex index in pts
fn rightmostIndex(pts: []const Pt) usize {
  var best: usize = 0;
  for (1..pts.len) |i| {
    if (pts[i].x > pts[best].x or (pts[i].x == pts[best].x and pts[i].y < pts[best].y))
      best = i;
  }
  return best;
}

/// Find a "bridge" from hole's rightmost point into outer polygon.
/// Returns the index in `outer` to insert after.
fn findBridge(outer: []const Pt, hx: f32, hy: f32) usize {
  // Find the NEAREST edge intersection to the right of (hx, hy).
  // Using the farthest (max-ix) creates bridges that cross other edges
  // for non-convex outers (e.g. '@', '$'), corrupting the merged polygon.
  var best_ix: f32 = std.math.floatMax(f32);
  var best_edge_i: usize = 0;
  const n = outer.len;
  for (0..n) |i| {
    const j = (i + 1) % n;
    const ax = outer[i].x;
    const ay = outer[i].y;
    const bx = outer[j].x;
    const by = outer[j].y;
    // Check if the horizontal ray from (hx, hy) intersects edge (a,b)
    if ((ay <= hy and by > hy) or (by <= hy and ay > hy)) {
      const t = (hy - ay) / (by - ay);
      const ix = ax + t * (bx - ax);
      if (ix > hx and ix < best_ix) {
        best_ix = ix;
        best_edge_i = i;
      }
    }
  }
  // If no edge found (degenerate), just use rightmost outer vertex
  if (best_ix == std.math.floatMax(f32)) {
    return rightmostIndex(outer);
  }
  // From the nearest intersected edge, pick the vertex with the higher x.
  const j = (best_edge_i + 1) % n;
  var best_idx: usize = if (outer[best_edge_i].x >= outer[j].x) best_edge_i else j;

  // Refine: if any outer vertex lies inside the visibility triangle
  // (hx,hy)-(best_ix,hy)-(outer[best_idx]), prefer the one with the
  // smallest angle from horizontal. This avoids bridges that cross
  // concavities of the outer polygon (e.g. '$', 'S'-shaped outers).
  const mx = outer[best_idx].x;
  const my = outer[best_idx].y;
  var best_tan: f32 = if (mx > hx) @abs(my - hy) / (mx - hx) else std.math.floatMax(f32);
  for (0..n) |i| {
    const vx = outer[i].x;
    const vy = outer[i].y;
    if (vx <= hx or vx > best_ix) continue;
    if (!ptInTriangle(hx, hy, best_ix, hy, mx, my, vx, vy)) continue;
    const tan = @abs(vy - hy) / (vx - hx);
    if (tan < best_tan or (tan == best_tan and vx > outer[best_idx].x)) {
      best_tan = tan;
      best_idx = i;
    }
  }
  return best_idx;
}

/// Merge a hole into an outer polygon by inserting bridge duplicates.
/// Returns the merged polygon (caller owns memory).
fn mergeHole(allocator: Alloc, outer: []const Pt, hole: []const Pt) ![]Pt {
  const hi = rightmostIndex(hole);
  const oi = findBridge(outer, hole[hi].x, hole[hi].y);

  const merged = try allocator.alloc(Pt, outer.len + hole.len + 2);
  var idx: usize = 0;

  // outer up to and including bridge vertex
  for (0..oi + 1) |k| {
    merged[idx] = outer[k];
    idx += 1;
  }

  // hole starting from hi, going around
  for (0..hole.len) |k| {
    merged[idx] = hole[(hi + k) % hole.len];
    idx += 1;
  }

  // close hole back to hi
  merged[idx] = hole[hi];
  idx += 1;

  // rest of outer from bridge vertex
  for (oi..outer.len) |k| {
    merged[idx] = outer[k];
    idx += 1;
  }

  return merged[0..idx];
}

/// Ear-clip triangulate a simple polygon (no holes).
/// Appends triangle vertices (3 Pt per triangle) to `out`.
pub fn earClip(allocator: Alloc, pts: []const Pt, out: *std.ArrayList(Pt)) !void {
    const n = pts.len;
    if (n < 3) return;
    if (n == 3) {
        try out.appendSlice(allocator, pts);
        return;
    }

    const prev_a = try allocator.alloc(usize, n);
    defer allocator.free(prev_a);
    const next_a = try allocator.alloc(usize, n);
    defer allocator.free(next_a);
    const alive = try allocator.alloc(bool, n);
    defer allocator.free(alive);

    for (0..n) |i| {
        prev_a[i] = if (i == 0) n - 1 else i - 1;
        next_a[i] = if (i == n - 1) 0 else i + 1;
        alive[i] = true;
    }

    const area = signedArea(pts);
    const is_cw = area >= 0;

    var remaining: usize = n;
    var cur: usize = 0;
    var fail_count: usize = 0;

    while (remaining > 3) {
        if (!alive[cur]) {
            cur = next_a[cur];
            continue;
        }
        const a = prev_a[cur];
        const b = cur;
        const c = next_a[cur];

        if (isEar(pts, a, b, c, alive, is_cw)) {
            try out.append(allocator, pts[a]);
            try out.append(allocator, pts[b]);
            try out.append(allocator, pts[c]);
            alive[b] = false;
            next_a[a] = c;
            prev_a[c] = a;
            remaining -= 1;
            cur = c;
            fail_count = 0;
        } else {
            cur = next_a[cur];
            fail_count += 1;
            if (fail_count > n) break; // full pass with no ear found = degenerate
        }
    }

    // Emit remaining vertices as a fan (fallback for degenerate cases or last triangle).
    if (remaining >= 3) {
        var k: usize = 0;
        while (!alive[k]) k += 1;
        const fan_root = k;
        k = next_a[k];
        var prev_k = k;
        k = next_a[k];
        while (k != fan_root and alive[k]) {
            try out.append(allocator, pts[fan_root]);
            try out.append(allocator, pts[prev_k]);
            try out.append(allocator, pts[k]);
            prev_k = k;
            k = next_a[k];
        }
    }
}

fn isEar(pts: []const Pt, a: usize, b: usize, c: usize, alive: []const bool, is_cw: bool) bool {
    const ax = pts[a].x;
    const ay = pts[a].y;
    const bx = pts[b].x;
    const by = pts[b].y;
    const cx = pts[c].x;
    const cy = pts[c].y;

    // Check convexity
    const cr = cross2d(bx - ax, by - ay, cx - ax, cy - ay);
    if (is_cw) {
        if (cr > 0) return false;
    } else {
        if (cr < 0) return false;
    }

    // Check no other vertex inside triangle
    for (0..pts.len) |i| {
        if (i == a or i == b or i == c or !alive[i]) continue;
        if (ptInTriangle(ax, ay, bx, by, cx, cy, pts[i].x, pts[i].y)) return false;
    }
    return true;
}

pub const Contour = struct { pts: []const Pt };

/// Point-in-polygon test using ray casting (horizontal ray to the right).
fn pointInPolygon(pts: []const Pt, px: f32, py: f32) bool {
    var inside = false;
    const n = pts.len;
    var j = n - 1;
    for (0..n) |i| {
        const xi = pts[i].x;
        const yi = pts[i].y;
        const xj = pts[j].x;
        const yj = pts[j].y;
        if (((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi)) {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Triangulate a set of contours (some outer, some holes).
/// Outer contours: signedArea > 0 (CW in y-down).
/// Hole contours: signedArea < 0 (CCW in y-down).
/// Appends triangle vertices to `out` (flat, 3 Pt per triangle).
pub fn triangulate(allocator: Alloc, contours: []const Contour, out: *std.ArrayList(Pt)) !void {
    if (contours.len == 0) return;

    // The outer contour always has the largest absolute area.
    // Use it as the reference so we work correctly regardless of contour order
    // or font format (TrueType vs CFF have opposite winding conventions).
    var ref_idx: usize = 0;
    var ref_abs: f32 = 0;
    for (contours, 0..) |c, i| {
        if (c.pts.len < 3) continue;
        const a = @abs(signedArea(c.pts));
        if (a > ref_abs) { ref_abs = a; ref_idx = i; }
    }
    if (ref_abs == 0) return;

    const ref_area = signedArea(contours[ref_idx].pts);
    const ref_positive = ref_area >= 0;

    // Separate contours into outers and holes.
    var outers = try std.ArrayList([]Pt).initCapacity(allocator, 4);
    defer {
        for (outers.items) |o| allocator.free(o);
        outers.deinit(allocator);
    }
    var holes = try std.ArrayList([]const Pt).initCapacity(allocator, 4);
    defer holes.deinit(allocator);

    for (contours) |c| {
        if (c.pts.len < 3) continue;
        const area = signedArea(c.pts);
        if ((area >= 0) == ref_positive) {
            try outers.append(allocator, try allocator.dupe(Pt, c.pts));
        } else {
            try holes.append(allocator, c.pts);
        }
    }

    // Assign each hole to the smallest outer contour that contains it,
    // then merge it in. This ensures e.g. the counter of 'a' goes into 'a',
    // not into the largest glyph on the line.
    for (holes.items) |hole| {
        const hi = rightmostIndex(hole);
        const hx = hole[hi].x;
        const hy = hole[hi].y;

        var best_idx: usize = 0; // fallback: first outer
        var best_area: f32 = std.math.floatMax(f32);
        for (outers.items, 0..) |outer, oi| {
            if (pointInPolygon(outer, hx, hy)) {
                const a = @abs(signedArea(outer));
                if (a < best_area) {
                    best_area = a;
                    best_idx = oi;
                }
            }
        }

        const merged = try mergeHole(allocator, outers.items[best_idx], hole);
        allocator.free(outers.items[best_idx]);
        outers.items[best_idx] = merged;
    }

    // Triangulate each outer (now with its holes merged in).
    for (outers.items) |outer| {
      try earClip(allocator, outer, out);
    }
}
