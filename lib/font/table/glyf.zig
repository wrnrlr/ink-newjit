/// glyf — Glyph Data (TrueType outlines).
/// doc/otf/table-glyf.md
///
/// Materialized to an L of length numGlyphs (one element per glyph id), using
/// the offsets in ctx.loca. Each element is a dict:
///
///   simple glyph    : `bbox`(I[4] xMin,yMin,xMax,yMax), `ends`(I endpoint
///                     indices, one per contour), `x`(I), `y`(I), `on`(I 0/1)
///                     — points are ABSOLUTE font-unit coords (deltas already
///                     accumulated), concatenated across contours and split by
///                     `ends`. Quadratic off-curve points are kept (on=0);
///                     flattening is a rendering concern, done later.
///   composite glyph : `bbox`(I[4]), `parts` — a column dict over components:
///                     `glyph`(I child gid), `dx`(I), `dy`(I) offset (when the
///                     component uses xy args), and the 2×2 transform `xx`,`xy`,
///                     `yx`,`yy`(F). A child point (x,y) maps to
///                     (xx*x + yx*y + dx, xy*x + yy*y + dy).
///   empty glyph     : a simple dict with empty ends/x/y/on and zero bbox.
///
/// Detect composites with `\`parts in !g`.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

// Simple glyph flag bits.
const ON_CURVE: u8 = 0x01;
const X_SHORT: u8 = 0x02;
const Y_SHORT: u8 = 0x04;
const REPEAT: u8 = 0x08;
const X_SAME: u8 = 0x10; // X_IS_SAME_OR_POSITIVE_X_SHORT_VECTOR
const Y_SAME: u8 = 0x20;

// Composite component flag bits.
const ARG_WORDS: u16 = 0x0001;
const SCALE: u16 = 0x0008;
const MORE: u16 = 0x0020;
const XY_SCALE: u16 = 0x0040;
const TWO_BY_TWO: u16 = 0x0080;

fn emptyGlyph() ?k.K {
  const zero = [_]i16{ 0, 0, 0, 0 };
  const keys = [_][*:0]const u8{ "bbox", "ends", "x", "y", "on" };
  const vals = [_]?k.K{ k.ints(i16, zero[0..]), k.KI(0), k.KI(0), k.KI(0), k.KI(0) };
  return k.dict(&keys, &vals);
}

fn parseSimple(r: *Reader, numContours: usize, bboxK: ?k.K) reader.Error!?k.K {
  const ends = k.KI(numContours) orelse return null;
  const ep = k.ip(ends) orelse return null;
  var numPoints: usize = 0;
  var i: usize = 0;
  while (i < numContours) : (i += 1) {
    const e = try r.uint16();
    ep[i] = e;
    numPoints = @as(usize, e) + 1;
  }
  if (numPoints > 200_000) return null; // guard against corrupt endpoints

  const instrLen = try r.uint16();
  r.skip(instrLen);

  const flags = alloc.alloc(u8, numPoints) catch return null;
  defer alloc.free(flags);
  i = 0;
  while (i < numPoints) {
    const f = try r.uint8();
    flags[i] = f;
    i += 1;
    if (f & REPEAT != 0) {
      var rep = try r.uint8();
      while (rep > 0 and i < numPoints) : (rep -= 1) {
        flags[i] = f;
        i += 1;
      }
    }
  }

  const xk = k.KI(numPoints) orelse return null;
  const xp = k.ip(xk) orelse return null;
  var xacc: i32 = 0;
  i = 0;
  while (i < numPoints) : (i += 1) {
    const f = flags[i];
    if (f & X_SHORT != 0) {
      const d: i32 = try r.uint8();
      xacc += if (f & X_SAME != 0) d else -d;
    } else if (f & X_SAME == 0) {
      xacc += try r.int16();
    }
    xp[i] = xacc;
  }

  const yk = k.KI(numPoints) orelse return null;
  const yp = k.ip(yk) orelse return null;
  var yacc: i32 = 0;
  i = 0;
  while (i < numPoints) : (i += 1) {
    const f = flags[i];
    if (f & Y_SHORT != 0) {
      const d: i32 = try r.uint8();
      yacc += if (f & Y_SAME != 0) d else -d;
    } else if (f & Y_SAME == 0) {
      yacc += try r.int16();
    }
    yp[i] = yacc;
  }

  const onk = k.KI(numPoints) orelse return null;
  const onp = k.ip(onk) orelse return null;
  i = 0;
  while (i < numPoints) : (i += 1) onp[i] = if (flags[i] & ON_CURVE != 0) 1 else 0;

  const keys = [_][*:0]const u8{ "bbox", "ends", "x", "y", "on" };
  const vals = [_]?k.K{ bboxK, ends, xk, yk, onk };
  return k.dict(&keys, &vals);
}

fn parseComposite(r: *Reader, bboxK: ?k.K) reader.Error!?k.K {
  var glyphs: std.ArrayList(i32) = .empty;
  var dxs: std.ArrayList(i32) = .empty;
  var dys: std.ArrayList(i32) = .empty;
  var xxs: std.ArrayList(f32) = .empty;
  var xys: std.ArrayList(f32) = .empty;
  var yxs: std.ArrayList(f32) = .empty;
  var yys: std.ArrayList(f32) = .empty;
  defer glyphs.deinit(alloc);
  defer dxs.deinit(alloc);
  defer dys.deinit(alloc);
  defer xxs.deinit(alloc);
  defer xys.deinit(alloc);
  defer yxs.deinit(alloc);
  defer yys.deinit(alloc);

  while (true) {
    const flags = try r.uint16();
    const glyphIndex = try r.uint16();
    var a1: i32 = undefined;
    var a2: i32 = undefined;
    if (flags & ARG_WORDS != 0) {
      a1 = try r.int16();
      a2 = try r.int16();
    } else {
      a1 = try r.int8();
      a2 = try r.int8();
    }
    var xx: f32 = 1;
    var xy: f32 = 0;
    var yx: f32 = 0;
    var yy: f32 = 1;
    if (flags & SCALE != 0) {
      xx = try r.f2dot14();
      yy = xx;
    } else if (flags & XY_SCALE != 0) {
      xx = try r.f2dot14();
      yy = try r.f2dot14();
    } else if (flags & TWO_BY_TWO != 0) {
      xx = try r.f2dot14(); // xscale
      xy = try r.f2dot14(); // scale01
      yx = try r.f2dot14(); // scale10
      yy = try r.f2dot14(); // yscale
    }
    glyphs.append(alloc, glyphIndex) catch return null;
    dxs.append(alloc, a1) catch return null;
    dys.append(alloc, a2) catch return null;
    xxs.append(alloc, xx) catch return null;
    xys.append(alloc, xy) catch return null;
    yxs.append(alloc, yx) catch return null;
    yys.append(alloc, yy) catch return null;
    if (flags & MORE == 0) break;
  }

  const pkeys = [_][*:0]const u8{ "glyph", "dx", "dy", "xx", "xy", "yx", "yy" };
  const pvals = [_]?k.K{
    k.ints(i32, glyphs.items), k.ints(i32, dxs.items), k.ints(i32, dys.items),
    k.floats(f32, xxs.items),  k.floats(f32, xys.items), k.floats(f32, yxs.items),
    k.floats(f32, yys.items),
  };
  const parts = k.dict(&pkeys, &pvals);

  const keys = [_][*:0]const u8{ "bbox", "parts" };
  const vals = [_]?k.K{ bboxK, parts };
  return k.dict(&keys, &vals);
}

fn parseGlyph(gd: []const u8) reader.Error!?k.K {
  var r = Reader.init(gd);
  const nc = try r.int16();
  const bbox = [_]i16{ try r.int16(), try r.int16(), try r.int16(), try r.int16() };
  const bboxK = k.ints(i16, bbox[0..]);
  if (nc >= 0) return parseSimple(&r, @intCast(nc), bboxK);
  return parseComposite(&r, bboxK);
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  const ng: usize = ctx.numGlyphs;
  if (ng == 0 or ctx.loca.len < ng + 1) return null;

  const list = k.KL(ng) orelse return null;
  var gi: usize = 0;
  while (gi < ng) : (gi += 1) {
    const lo: usize = ctx.loca[gi];
    const hi: usize = ctx.loca[gi + 1];
    var g: ?k.K = null;
    if (hi > lo and hi <= data.len) {
      g = parseGlyph(data[lo..hi]) catch null;
    }
    if (g == null) g = emptyGlyph();
    k.listSet(list, gi, g);
  }
  return list;
}
