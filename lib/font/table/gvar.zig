/// gvar — Glyph Variations Table.
/// doc/otf/table-gvar.md
///
/// The 'gvar' table stores how TrueType glyph outline points move across the
/// font's variation space. It is a specific variant of the *tuple variation
/// store* format (see the "OpenType Font Variations Common Table Formats"
/// chapter); the 'cvar' table uses a closely-related variant and reuses the
/// packed-point-number / packed-delta / tuple-record decoders defined here.
///
/// Normalized to a dict:
///   axisCount    : I
///   sharedTuples : L of F[axisCount] peak-coordinate vectors (the shared
///                  tuples array, sharedTupleCount entries)
///   glyphs       : L of length numGlyphs. Element g is the glyph's variation
///                  data, an L of tuple dicts:
///                    peak             : F[axisCount]
///                    intermediateStart: F[axisCount] (empty if no intermediate
///                                       region)
///                    intermediateEnd  : F[axisCount] (empty if none)
///                    points           : I point numbers the deltas apply to
///                                       (empty = "all points")
///                    deltaX           : I per-point X deltas
///                    deltaY           : I per-point Y deltas
///                  An empty glyph (offset[g] == offset[g+1]) is an empty L.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

// ── Shared tuple-variation-store helpers (reused by cvar.zig) ──────────────────

// GlyphVariationData / cvar header flag (high bits of tupleVariationCount).
pub const SHARED_POINT_NUMBERS: u16 = 0x8000;
pub const COUNT_MASK: u16 = 0x0FFF;

// TupleVariationHeader tupleIndex flags.
pub const EMBEDDED_PEAK_TUPLE: u16 = 0x8000;
pub const INTERMEDIATE_REGION: u16 = 0x4000;
pub const PRIVATE_POINT_NUMBERS: u16 = 0x2000;
pub const TUPLE_INDEX_MASK: u16 = 0x0FFF;

// Packed point-number run flags.
pub const POINTS_ARE_WORDS: u8 = 0x80;
pub const POINT_RUN_COUNT_MASK: u8 = 0x7F;

// Packed delta run flags.
pub const DELTAS_ARE_ZERO: u8 = 0x80;
pub const DELTAS_ARE_WORDS: u8 = 0x40;
pub const DELTA_RUN_COUNT_MASK: u8 = 0x3F;

/// A decoded tuple-variation header (before its serialized data is read).
pub const TupleHeader = struct {
  variationDataSize: u16,
  tupleIndex: u16,
  /// peak coordinates (axisCount), resolved from shared tuples or embedded.
  peak: ?k.K,
  intermediateStart: ?k.K, // null → emit empty F vector downstream
  intermediateEnd: ?k.K,

  fn hasPrivatePoints(self: TupleHeader) bool {
    return (self.tupleIndex & PRIVATE_POINT_NUMBERS) != 0;
  }
};

/// Read one TupleVariationHeader. `r` is positioned at the header; on return it
/// points just past the header (at the next header or the serialized data).
/// `sharedTuples` is the parsed shared-tuples list (gvar) or null (cvar).
pub fn readTupleHeader(r: *Reader, axisCount: u16, sharedTuples: ?k.K) reader.Error!TupleHeader {
  const variationDataSize = try r.uint16();
  const tupleIndex = try r.uint16();

  var peak: ?k.K = null;
  if ((tupleIndex & EMBEDDED_PEAK_TUPLE) != 0) {
    peak = try readTuple(r, axisCount);
  } else if (sharedTuples) |st| {
    // Reference a shared tuple by index; copy it so ownership stays simple.
    const idx: usize = tupleIndex & TUPLE_INDEX_MASK;
    peak = copyFloatVec(st, idx, axisCount);
  }

  var intermediateStart: ?k.K = null;
  var intermediateEnd: ?k.K = null;
  if ((tupleIndex & INTERMEDIATE_REGION) != 0) {
    intermediateStart = try readTuple(r, axisCount);
    intermediateEnd = try readTuple(r, axisCount);
  }

  return .{
    .variationDataSize = variationDataSize,
    .tupleIndex = tupleIndex,
    .peak = peak,
    .intermediateStart = intermediateStart,
    .intermediateEnd = intermediateEnd,
  };
}

/// Read a Tuple record: axisCount F2Dot14 coordinates → F vector.
pub fn readTuple(r: *Reader, axisCount: u16) reader.Error!?k.K {
  const v = k.KF(axisCount) orelse return null;
  if (k.fp(v)) |p| {
    var a: usize = 0;
    while (a < axisCount) : (a += 1) p[a] = try r.f2dot14();
  }
  return v;
}

/// Copy element `idx` of an L of F vectors into a fresh F[axisCount]. Returns an
/// empty/zeroed vector if the index is out of range.
fn copyFloatVec(list: ?k.K, idx: usize, axisCount: u16) ?k.K {
  const out = k.KF(axisCount) orelse return null;
  const op = k.fp(out) orelse return out;
  const reg = k.reg orelse return out;
  const n: usize = @intCast(@max(0, reg.kn(list)));
  if (idx >= n) return out;
  const lp = reg.klp(list) orelse return out;
  const src = lp[idx];
  const m: usize = @intCast(@max(0, reg.kn(src)));
  const sp = reg.kfp(src) orelse return out;
  var a: usize = 0;
  while (a < axisCount and a < m) : (a += 1) op[a] = sp[a];
  return out;
}

/// Decode packed "point numbers". Returns the list of point numbers (cumulative
/// deltas already accumulated). An empty count (first byte == 0) means "points
/// apply to all entries" — we signal that by returning an empty list. On a short
/// read it returns whatever was decoded so far.
pub fn readPackedPoints(r: *Reader) reader.Error!?k.K {
  var out: std.ArrayList(i32) = .empty;
  defer out.deinit(alloc);

  var count: usize = try r.uint8();
  if (count & 0x80 != 0) {
    const lo = try r.uint8();
    count = ((count & 0x7F) << 8) | lo;
  }
  if (count == 0) return k.KI(0); // empty → "all points"

  var acc: i32 = 0;
  while (out.items.len < count) {
    const control = r.uint8() catch break;
    const words = (control & POINTS_ARE_WORDS) != 0;
    const runLen: usize = @as(usize, control & POINT_RUN_COUNT_MASK) + 1;
    var i: usize = 0;
    while (i < runLen and out.items.len < count) : (i += 1) {
      const d: i32 = if (words) (r.uint16() catch break) else (r.uint8() catch break);
      acc += d;
      out.append(alloc, acc) catch break;
    }
  }
  return k.ints(i32, out.items);
}

/// Decode `count` packed deltas (signed). Stops gracefully on a short read,
/// zero-filling any deltas it could not read so the result stays `count` long.
pub fn readPackedDeltas(r: *Reader, count: usize) reader.Error!?k.K {
  const out = k.KI(count) orelse return null;
  const op = k.ip(out) orelse return out;
  var i: usize = 0;
  while (i < count) {
    const control = r.uint8() catch break;
    const runLen: usize = @as(usize, control & DELTA_RUN_COUNT_MASK) + 1;
    if ((control & DELTAS_ARE_ZERO) != 0) {
      var j: usize = 0;
      while (j < runLen and i < count) : (j += 1) {
        op[i] = 0;
        i += 1;
      }
    } else if ((control & DELTAS_ARE_WORDS) != 0) {
      var j: usize = 0;
      while (j < runLen and i < count) : (j += 1) {
        op[i] = r.int16() catch break;
        i += 1;
      }
    } else {
      var j: usize = 0;
      while (j < runLen and i < count) : (j += 1) {
        op[i] = r.int8() catch break;
        i += 1;
      }
    }
  }
  // Zero-fill any tail we could not decode.
  while (i < count) : (i += 1) op[i] = 0;
  return out;
}

/// Number of point entries a tuple has, given its (decoded) `points` vector and
/// the shared-point fallback. An empty `points` list means "all points"; here we
/// don't know the glyph's point count, so callers that need an X+Y pairing use
/// the actual length of the resolved point list.
fn pointCount(points: ?k.K, sharedCount: usize) usize {
  const reg = k.reg orelse return 0;
  const n: usize = @intCast(@max(0, reg.kn(points)));
  return if (n > 0) n else sharedCount;
}

// ── gvar ──────────────────────────────────────────────────────────────────────

/// Decode a single glyph's GlyphVariationData → L of tuple dicts. `gd` is the
/// glyph's slice; `sharedTuples` the gvar shared-tuples list.
fn parseGlyphVariation(gd: []const u8, axisCount: u16, sharedTuples: ?k.K) ?k.K {
  var r = Reader.init(gd);
  const tvc = r.uint16() catch return k.KL(0);
  const dataOffset = r.uint16() catch return k.KL(0);
  const tupleCount: usize = tvc & COUNT_MASK;
  const hasSharedPoints = (tvc & SHARED_POINT_NUMBERS) != 0;
  if (tupleCount == 0) return k.KL(0);

  // Read all tuple headers (positioned right after the GlyphVariationData
  // header). variationDataSize tells us where each tuple's serialized data ends.
  const headers = alloc.alloc(TupleHeader, tupleCount) catch return k.KL(0);
  defer alloc.free(headers);
  var t: usize = 0;
  while (t < tupleCount) : (t += 1) {
    headers[t] = readTupleHeader(&r, axisCount, sharedTuples) catch {
      // Free any peak/intermediate values already built for this entry's peers.
      var f: usize = 0;
      while (f < t) : (f += 1) freeHeader(headers[f]);
      return k.KL(0);
    };
  }

  // Serialized data begins at dataOffset (relative to the glyph slice).
  var sr = Reader.at(gd, dataOffset);

  // Optional shared point numbers, consumed first.
  var sharedPoints: ?k.K = null;
  defer if (sharedPoints) |sp| k.unref(sp);
  if (hasSharedPoints) {
    sharedPoints = readPackedPoints(&sr) catch null;
  }
  const sharedPointN: usize = blk: {
    const reg = k.reg orelse break :blk 0;
    break :blk @intCast(@max(0, reg.kn(sharedPoints)));
  };

  const list = k.KL(tupleCount) orelse {
    var f: usize = 0;
    while (f < tupleCount) : (f += 1) freeHeader(headers[f]);
    return null;
  };

  t = 0;
  while (t < tupleCount) : (t += 1) {
    const h = headers[t];
    // Each tuple's serialized data is variationDataSize bytes; decode within it.
    const start = sr.pos;
    const end = @min(start + h.variationDataSize, gd.len);
    var dr = Reader.at(gd[0..end], start);

    // Private point numbers override the shared list for this tuple.
    var ownPoints = false;
    var points: ?k.K = sharedPoints;
    if (h.hasPrivatePoints()) {
      points = readPackedPoints(&dr) catch sharedPoints;
      ownPoints = points != sharedPoints;
    }
    const np = pointCount(points, sharedPointN);

    // gvar: two logical deltas per point (X then Y).
    const deltaX = readPackedDeltas(&dr, np) catch k.KI(0);
    const deltaY = readPackedDeltas(&dr, np) catch k.KI(0);

    const tk = buildTuple(h, points, deltaX, deltaY, axisCount);
    if (ownPoints) {
      if (points) |p| k.unref(p);
    }
    k.listSet(list, t, tk);

    // Advance to the next tuple's serialized data regardless of how much we read.
    sr.seek(end);
  }
  return list;
}

/// Build one gvar tuple dict. Consumes (via the dict builder) peak/intermediate/
/// deltaX/deltaY and a *copy* of points (the original is managed by the caller).
fn buildTuple(h: TupleHeader, points: ?k.K, deltaX: ?k.K, deltaY: ?k.K, axisCount: u16) ?k.K {
  const peak = h.peak orelse k.KF(axisCount);
  const iStart = h.intermediateStart orelse k.KF(0);
  const iEnd = h.intermediateEnd orelse k.KF(0);
  const pts = dupVec(points);
  const keys = [_][*:0]const u8{ "peak", "intermediateStart", "intermediateEnd", "points", "deltaX", "deltaY" };
  const vals = [_]?k.K{ peak, iStart, iEnd, pts, deltaX, deltaY };
  return k.dict(&keys, &vals);
}

/// Duplicate an I vector (the dict builder takes ownership, but `points` may be
/// the shared list referenced by several tuples).
fn dupVec(v: ?k.K) ?k.K {
  const reg = k.reg orelse return k.KI(0);
  const n: usize = @intCast(@max(0, reg.kn(v)));
  const out = k.KI(n) orelse return null;
  if (n == 0) return out;
  const op = k.ip(out) orelse return out;
  const sp = reg.kip(v) orelse return out;
  var i: usize = 0;
  while (i < n) : (i += 1) op[i] = sp[i];
  return out;
}

/// Release any K values a header held but that were not handed to a dict.
fn freeHeader(h: TupleHeader) void {
  if (h.peak) |p| k.unref(p);
  if (h.intermediateStart) |p| k.unref(p);
  if (h.intermediateEnd) |p| k.unref(p);
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  var r = Reader.init(data);
  _ = try r.uint16(); // majorVersion
  _ = try r.uint16(); // minorVersion
  const axisCount = try r.uint16();
  const sharedTupleCount = try r.uint16();
  const sharedTuplesOffset = try r.uint32();
  _ = try r.uint16(); // glyphCount (use ctx.numGlyphs)
  const flags = try r.uint16();
  const arrayOffset = try r.uint32();

  const numGlyphs: usize = ctx.numGlyphs;
  if (axisCount == 0) return null;

  // Shared tuples: an L of F[axisCount] peak vectors.
  const sharedTuples = k.KL(sharedTupleCount) orelse return null;
  {
    var sr = Reader.at(data, sharedTuplesOffset);
    var i: usize = 0;
    while (i < sharedTupleCount) : (i += 1) {
      const tup = readTuple(&sr, axisCount) catch k.KF(axisCount);
      k.listSet(sharedTuples, i, tup);
    }
  }

  // glyphVariationDataOffsets[numGlyphs + 1]; short offsets are stored ×2.
  const longOffsets = (flags & 0x0001) != 0;
  const offsets = alloc.alloc(u32, numGlyphs + 1) catch {
    k.unref(sharedTuples);
    return null;
  };
  defer alloc.free(offsets);
  {
    var i: usize = 0;
    while (i < numGlyphs + 1) : (i += 1) {
      offsets[i] = if (longOffsets)
        (r.uint32() catch 0)
      else
        (@as(u32, r.uint16() catch 0) * 2);
    }
  }

  const glyphs = k.KL(numGlyphs) orelse {
    k.unref(sharedTuples);
    return null;
  };
  var gi: usize = 0;
  while (gi < numGlyphs) : (gi += 1) {
    const lo: usize = arrayOffset + offsets[gi];
    const hi: usize = arrayOffset + offsets[gi + 1];
    var g: ?k.K = null;
    if (offsets[gi + 1] > offsets[gi] and hi <= data.len and lo < hi) {
      g = parseGlyphVariation(data[lo..hi], axisCount, sharedTuples);
    }
    if (g == null) g = k.KL(0);
    k.listSet(glyphs, gi, g);
  }

  const keys = [_][*:0]const u8{ "axisCount", "sharedTuples", "glyphs" };
  const vals = [_]?k.K{ k.ki(axisCount), sharedTuples, glyphs };
  return k.dict(&keys, &vals);
}
