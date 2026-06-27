/// .shp geometry parser → a flat, GPU-friendly CSR dict.
///
/// Output (symbol-keyed dict):
///   type   s   shape-type name (polygon, polyline, point, …)
///   box    F   file bounding box [xmin ymin xmax ymax]
///   x      F   every point's X, all features concatenated  ← upload as-is
///   y      F   every point's Y
///   z      F   (Z types only) per-point Z, aligned with x/y
///   m      F   (Z/M types only) per-point measure, aligned with x/y
///   part   I   ring/part start indices into x/y; CSR with trailing sentinel #x
///   shape  I   per-feature start indices into `part`; CSR, trailing sentinel
///
/// nfeatures = (#shape)-1.  Feature i owns parts shape[i]..shape[i+1].
/// Part j owns points part[j]..part[j+1] in x/y/z/m.  Point/MultiPoint records
/// are normalised to one synthetic part so every type shares this schema.

const std = @import("std");
const k = @import("kbuild.zig");
const Cursor = @import("read.zig").Cursor;

const Alloc = std.mem.Allocator;
const F = std.ArrayList(f64);
const I = std.ArrayList(i32);

fn typeName(t: i32) [*:0]const u8 {
  return switch (t) {
    0 => "null",
    1 => "point",
    3 => "polyline",
    5 => "polygon",
    8 => "multipoint",
    11 => "pointz",
    13 => "polylinez",
    15 => "polygonz",
    18 => "multipointz",
    21 => "pointm",
    23 => "polylinem",
    25 => "polygonm",
    28 => "multipointm",
    31 => "multipatch",
    else => "unknown",
  };
}

fn hasZ(t: i32) bool {
  return t == 11 or t == 13 or t == 15 or t == 18 or t == 31;
}
fn hasM(t: i32) bool {
  return hasZ(t) or t == 21 or t == 23 or t == 25 or t == 28;
}
fn isPoint(t: i32) bool {
  return t == 1 or t == 11 or t == 21;
}
fn isMultiPoint(t: i32) bool {
  return t == 8 or t == 18 or t == 28;
}
fn isPoly(t: i32) bool {
  return t == 3 or t == 5 or t == 13 or t == 15 or t == 23 or t == 25 or t == 31;
}

const Geom = struct {
  xs: F = .empty,
  ys: F = .empty,
  zs: F = .empty,
  ms: F = .empty,
  part: I = .empty, // point-start index of each ring (then sentinel #x)
  shape: I = .empty, // part-start index of each feature (then sentinel #parts)
  ftype: i32, // file-level shape type
  alloc: Alloc,

  fn z(g: *Geom) bool {
    return hasZ(g.ftype);
  }
  fn m(g: *Geom) bool {
    return hasM(g.ftype);
  }

  // Begin a part at the current point count.
  fn openPart(g: *Geom) !void {
    try g.part.append(g.alloc, @intCast(g.xs.items.len));
  }

  fn addPoint(g: *Geom, px: f64, py: f64) !void {
    try g.xs.append(g.alloc, px);
    try g.ys.append(g.alloc, py);
  }
};

/// Parse a single record's content (after the 8-byte record header).
fn parseRecord(g: *Geom, c: *Cursor) !void {
  // Feature begins at the current part count.
  try g.shape.append(g.alloc, @intCast(g.part.items.len));

  const rt = c.i32le();
  if (rt == 0) return; // null shape: zero parts

  if (isPoint(rt)) {
    try g.openPart();
    const px = c.f64le();
    const py = c.f64le();
    try g.addPoint(px, py);
    if (g.z()) try g.zs.append(g.alloc, c.f64le());
    if (g.m()) try g.ms.append(g.alloc, c.f64le());
    return;
  }

  // MultiPoint / PolyLine / Polygon: box(4 f64) then counts.
  c.skip(32); // per-record bbox (recomputable from coords)

  var numParts: usize = 1;
  var numPoints: usize = 0;

  if (isMultiPoint(rt)) {
    numPoints = @intCast(@max(0, c.i32le()));
  } else { // poly
    numParts = @intCast(@max(0, c.i32le()));
    numPoints = @intCast(@max(0, c.i32le()));
  }

  // Read part offsets (poly only). For MultiPoint we synthesise one part.
  var offs: []i32 = &.{};
  if (isPoly(rt)) {
    offs = try g.alloc.alloc(i32, numParts + 1);
    for (0..numParts) |i| offs[i] = c.i32le();
    offs[numParts] = @intCast(numPoints);
  }
  defer if (offs.len > 0) g.alloc.free(offs);

  const base: usize = g.xs.items.len; // first global point index of this record

  // X/Y points.
  if (isPoly(rt)) {
    for (0..numParts) |pi| {
      try g.openPart();
      const lo: usize = @intCast(@max(0, offs[pi]));
      const hi: usize = @intCast(@max(0, offs[pi + 1]));
      var pp = lo;
      while (pp < hi) : (pp += 1) {
        const px = c.f64le();
        const py = c.f64le();
        try g.addPoint(px, py);
      }
    }
  } else { // multipoint → single part
    try g.openPart();
    for (0..numPoints) |_| {
      const px = c.f64le();
      const py = c.f64le();
      try g.addPoint(px, py);
    }
  }

  // Poly/MultiPoint Z & M values trail the point block, so grow the (point-
  // aligned) z/m arrays to match xs, then fill by index.
  if (g.z()) try g.zs.resize(g.alloc, g.xs.items.len);
  if (g.m()) try g.ms.resize(g.alloc, g.xs.items.len);

  // Z block: [zmin zmax] then one f64 per point. Bounds-guarded — some writers
  // omit the optional M block (and rarely Z) when the record is short.
  if (g.z()) {
    if (c.remaining() >= 16 + numPoints * 8) {
      c.skip(16); // z range
      for (0..numPoints) |i| g.zs.items[base + i] = c.f64le();
    } else {
      for (0..numPoints) |i| g.zs.items[base + i] = 0;
    }
  }
  if (g.m()) {
    if (c.remaining() >= 16 + numPoints * 8) {
      c.skip(16); // m range
      for (0..numPoints) |i| g.ms.items[base + i] = c.f64le();
    } else {
      for (0..numPoints) |i| g.ms.items[base + i] = std.math.nan(f64);
    }
  }
}

pub fn parse(alloc: Alloc, buf: []const u8) !?k.K {
  if (buf.len < 100) return null;
  var hc = Cursor.init(buf);
  const fileCode = hc.i32be();
  if (fileCode != 9994) return null;
  hc.seek(32);
  const ftype = hc.i32le();
  const box = [4]f64{ hc.f64le(), hc.f64le(), hc.f64le(), hc.f64le() };

  var g = Geom{ .ftype = ftype, .alloc = alloc };

  var c = Cursor.init(buf);
  c.seek(100);
  while (c.remaining() >= 8) {
    _ = c.i32be(); // record number (1-based, ignored)
    const contentWords = c.i32be();
    if (contentWords <= 0) break;
    const contentBytes: usize = @intCast(@as(usize, @intCast(contentWords)) * 2);
    if (c.remaining() < contentBytes) break;
    const start = c.pos;
    try parseRecord(&g, &c);
    c.seek(start + contentBytes); // robust to optional trailing blocks
  }

  // CSR sentinels.
  try g.part.append(alloc, @intCast(g.xs.items.len));
  try g.shape.append(alloc, @intCast(g.part.items.len - 1));

  // Build the dict. Keys vary by type (z/m only when present).
  var keys: [8][*:0]const u8 = undefined;
  var vals: [8]?k.K = undefined;
  var n: usize = 0;
  const push = struct {
    fn f(kk: *[8][*:0]const u8, vv: *[8]?k.K, nn: *usize, key: [*:0]const u8, v: ?k.K) void {
      kk[nn.*] = key;
      vv[nn.*] = v;
      nn.* += 1;
    }
  }.f;

  push(&keys, &vals, &n, "type", k.reg.?.ks(typeName(ftype)));
  push(&keys, &vals, &n, "box", k.floats(&box));
  push(&keys, &vals, &n, "x", k.floats(g.xs.items));
  push(&keys, &vals, &n, "y", k.floats(g.ys.items));
  if (hasZ(ftype)) push(&keys, &vals, &n, "z", k.floats(g.zs.items));
  if (hasM(ftype)) push(&keys, &vals, &n, "m", k.floats(g.ms.items));
  push(&keys, &vals, &n, "part", k.ints(g.part.items));
  push(&keys, &vals, &n, "shape", k.ints(g.shape.items));

  return k.dict(keys[0..n], vals[0..n]);
}
