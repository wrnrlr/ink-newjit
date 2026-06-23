/// cvar — CVT Variations Table.
/// doc/otf/table-cvar.md
///
/// Provides variation data for 'cvt ' control values across the font's variation
/// space. It uses the same *tuple variation store* format as 'gvar' (see the
/// "OpenType Font Variations Common Table Formats" chapter), with three
/// differences: the embedded peak tuple is mandatory; packed point numbers index
/// CVT entries rather than outline points; and there is exactly one logical delta
/// per point number (no X/Y split). The shared decoders live in gvar.zig.
///
/// axisCount is taken from the sibling 'fvar' table (offset 8 = axisCount); if
/// 'fvar' is absent we cannot size tuple records and emit empty tuples.
///
/// Normalized to a dict:
///   version : F (version16dot16)
///   tuples  : L of tuple dicts:
///               peak             : F[axisCount]
///               intermediateStart: F[axisCount] (empty if no intermediate region)
///               intermediateEnd  : F[axisCount] (empty if none)
///               points           : I CVT indices the deltas apply to
///                                  (empty = "all CVT values")
///               deltas           : I per-point CVT deltas

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;
const gvar = @import("gvar.zig");

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

fn freeHeader(h: gvar.TupleHeader) void {
  if (h.peak) |p| k.unref(p);
  if (h.intermediateStart) |p| k.unref(p);
  if (h.intermediateEnd) |p| k.unref(p);
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

fn buildTuple(h: gvar.TupleHeader, points: ?k.K, deltas: ?k.K, axisCount: u16) ?k.K {
  const peak = h.peak orelse k.KF(axisCount);
  const iStart = h.intermediateStart orelse k.KF(0);
  const iEnd = h.intermediateEnd orelse k.KF(0);
  const pts = dupVec(points);
  const keys = [_][*:0]const u8{ "peak", "intermediateStart", "intermediateEnd", "points", "deltas" };
  const vals = [_]?k.K{ peak, iStart, iEnd, pts, deltas };
  return k.dict(&keys, &vals);
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  var r = Reader.init(data);
  const version = try r.version16dot16();
  const tvc = try r.uint16();
  const dataOffset = try r.uint16();
  const tupleCount: usize = tvc & gvar.COUNT_MASK;
  const hasSharedPoints = (tvc & gvar.SHARED_POINT_NUMBERS) != 0;

  // axisCount comes from 'fvar' (uint16 at offset 8); default 0 if absent.
  var axisCount: u16 = 0;
  if (ctx.slice(reader.tagFrom("fvar"))) |fvar| {
    if (fvar.len >= 10) axisCount = std.mem.readInt(u16, fvar[8..10], .big);
  }

  const verK = k.kf(version);
  if (tupleCount == 0 or axisCount == 0) {
    const keys = [_][*:0]const u8{ "version", "tuples" };
    const vals = [_]?k.K{ verK, k.KL(0) };
    return k.dict(&keys, &vals);
  }

  // Read all tuple headers (cvar has no shared-tuples array, so pass null —
  // every tuple must carry an embedded peak per the spec).
  const headers = alloc.alloc(gvar.TupleHeader, tupleCount) catch {
    const keys = [_][*:0]const u8{ "version", "tuples" };
    const vals = [_]?k.K{ verK, k.KL(0) };
    return k.dict(&keys, &vals);
  };
  defer alloc.free(headers);
  var t: usize = 0;
  while (t < tupleCount) : (t += 1) {
    headers[t] = gvar.readTupleHeader(&r, axisCount, null) catch {
      var f: usize = 0;
      while (f < t) : (f += 1) freeHeader(headers[f]);
      const keys = [_][*:0]const u8{ "version", "tuples" };
      const vals = [_]?k.K{ verK, k.KL(0) };
      return k.dict(&keys, &vals);
    };
  }

  var sr = Reader.at(data, dataOffset);

  var sharedPoints: ?k.K = null;
  defer if (sharedPoints) |sp| k.unref(sp);
  if (hasSharedPoints) {
    sharedPoints = gvar.readPackedPoints(&sr) catch null;
  }
  const sharedPointN: usize = blk: {
    const reg = k.reg orelse break :blk 0;
    break :blk @intCast(@max(0, reg.kn(sharedPoints)));
  };

  const tuples = k.KL(tupleCount) orelse {
    var f: usize = 0;
    while (f < tupleCount) : (f += 1) freeHeader(headers[f]);
    const keys = [_][*:0]const u8{ "version", "tuples" };
    const vals = [_]?k.K{ verK, k.KL(0) };
    return k.dict(&keys, &vals);
  };

  t = 0;
  while (t < tupleCount) : (t += 1) {
    const h = headers[t];
    const start = sr.pos;
    const end = @min(start + h.variationDataSize, data.len);
    var dr = Reader.at(data[0..end], start);

    var ownPoints = false;
    var points: ?k.K = sharedPoints;
    if ((h.tupleIndex & gvar.PRIVATE_POINT_NUMBERS) != 0) {
      points = gvar.readPackedPoints(&dr) catch sharedPoints;
      ownPoints = points != sharedPoints;
    }
    const reg = k.reg;
    const np: usize = blk: {
      const rg = reg orelse break :blk sharedPointN;
      const n: usize = @intCast(@max(0, rg.kn(points)));
      break :blk if (n > 0) n else sharedPointN;
    };

    // cvar: exactly one logical delta per point number.
    const deltas = gvar.readPackedDeltas(&dr, np) catch k.KI(0);

    const tk = buildTuple(h, points, deltas, axisCount);
    if (ownPoints) {
      if (points) |p| k.unref(p);
    }
    k.listSet(tuples, t, tk);

    sr.seek(end);
  }

  const keys = [_][*:0]const u8{ "version", "tuples" };
  const vals = [_]?k.K{ verK, tuples };
  return k.dict(&keys, &vals);
}
