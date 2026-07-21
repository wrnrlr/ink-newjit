/// Type 2 charstring interpreter — turns a CFF/CFF2 glyph charstring into a
/// flattened pixel outline (cubic Béziers subdivided to line segments), matching
/// the shape the K-side FontOutline produces for `glyf` glyphs: an L of flat F
/// contours [x,y,x,y,…], scaled to the pixel size and y-flipped (font y-up →
/// screen y-down). Hint operators are parsed only enough to skip their operands
/// (and hintmask bytes); they do not affect geometry.

const std = @import("std");
const k = @import("kbuild.zig");

const alloc = std.heap.c_allocator;
const Pt = [2]f32;
const CURVE_STEPS = 8; // cubic subdivision segments

fn bias(n: usize) i32 {
  return if (n < 1240) 107 else if (n < 33900) 1131 else 32768;
}

const Interp = struct {
  stack: [48]f64 = undefined,
  sp: usize = 0,
  x: f64 = 0,
  y: f64 = 0,
  sx: f64 = 0, // subpath start (for the closing quad in quads mode)
  sy: f64 = 0,
  quads: bool = false, // true → emit RAW quadratic control triples, not flattened lines
  gsubrs: [][]const u8,
  lsubrs: [][]const u8,
  gbias: i32,
  lbias: i32,
  scale: f64,
  nStems: u32 = 0,
  haveWidth: bool = false,
  open: bool = false,
  done: bool = false,
  contours: std.ArrayList(std.ArrayList(Pt)),
  cur: std.ArrayList(Pt),

  fn push(self: *Interp, v: f64) void {
    if (self.sp < self.stack.len) {
      self.stack[self.sp] = v;
      self.sp += 1;
    }
  }

  fn emit(self: *Interp, fx: f64, fy: f64) void {
    self.cur.append(alloc, .{ @floatCast(fx * self.scale), @floatCast(-fy * self.scale) }) catch {};
  }
  // A quadratic segment (on;ctrl;on) → three control points (scaled/flipped by emit).
  fn emitQuad(self: *Interp, x0: f64, y0: f64, cx: f64, cy: f64, x1: f64, y1: f64) void {
    self.emit(x0, y0);
    self.emit(cx, cy);
    self.emit(x1, y1);
  }

  fn flushContour(self: *Interp) void {
    // quads mode: close the contour with a final quad back to the subpath start.
    if (self.quads and self.open and self.cur.items.len > 0)
      self.emitQuad(self.x, self.y, 0.5 * (self.x + self.sx), 0.5 * (self.y + self.sy), self.sx, self.sy);
    if (self.cur.items.len > 0) {
      self.contours.append(alloc, self.cur) catch {};
      self.cur = .empty;
    } else {
      self.cur.clearRetainingCapacity();
    }
    self.open = false;
  }

  fn moveTo(self: *Interp, nx: f64, ny: f64) void {
    if (self.open) self.flushContour();
    self.x = nx;
    self.y = ny;
    self.sx = nx;
    self.sy = ny;
    self.open = true;
    if (!self.quads) self.emit(self.x, self.y); // quads mode: first quad starts at the next seg
  }

  fn lineTo(self: *Interp, nx: f64, ny: f64) void {
    if (self.quads) {
      self.emitQuad(self.x, self.y, 0.5 * (self.x + nx), 0.5 * (self.y + ny), nx, ny); // degenerate quad
    } else {
      self.emit(nx, ny);
    }
    self.x = nx;
    self.y = ny;
  }

  fn curveTo(self: *Interp, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) void {
    const x0 = self.x;
    const y0 = self.y;
    if (self.quads) {
      // cubic P0 C1 C2 P3 → two quadratics via one de Casteljau split at t=0.5.
      const ax = 0.5 * (x0 + x1);
      const ay = 0.5 * (y0 + y1);
      const bx = 0.5 * (x1 + x2);
      const by = 0.5 * (y1 + y2);
      const ex = 0.5 * (x2 + x3);
      const ey = 0.5 * (y2 + y3);
      const dx = 0.5 * (ax + bx);
      const dy = 0.5 * (ay + by);
      const gx = 0.5 * (bx + ex);
      const gy = 0.5 * (by + ey);
      const mx = 0.5 * (dx + gx);
      const my = 0.5 * (dy + gy);
      const qlx = 0.25 * (3 * (ax + dx) - x0 - mx);
      const qly = 0.25 * (3 * (ay + dy) - y0 - my);
      const qrx = 0.25 * (3 * (gx + ex) - mx - x3);
      const qry = 0.25 * (3 * (gy + ey) - my - y3);
      self.emitQuad(x0, y0, qlx, qly, mx, my);
      self.emitQuad(mx, my, qrx, qry, x3, y3);
    } else {
      var i: usize = 1;
      while (i <= CURVE_STEPS) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / CURVE_STEPS;
        const u = 1.0 - t;
        const bxx = u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3;
        const byy = u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3;
        self.emit(bxx, byy);
      }
    }
    self.x = x3;
    self.y = y3;
  }

  // Relative cubic from the current point.
  fn rcurve(self: *Interp, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) void {
    const x1 = self.x + dx1;
    const y1 = self.y + dy1;
    const x2 = x1 + dx2;
    const y2 = y1 + dy2;
    const x3 = x2 + dx3;
    const y3 = y2 + dy3;
    self.curveTo(x1, y1, x2, y2, x3, y3);
  }

  // The leading width: on the first stack-clearing operator, an extra operand
  // beyond what the operator consumes is the glyph width — drop it. `even` is
  // whether the operator's operand count should be even (stems) vs the explicit
  // expected count for moveto/endchar handled by the caller via `expected`.
  fn widthBase(self: *Interp, expected: usize) usize {
    var base: usize = 0;
    if (!self.haveWidth) {
      if (self.sp > expected) base = 1;
      self.haveWidth = true;
    }
    return base;
  }

  fn countStems(self: *Interp) void {
    var n = self.sp;
    if (!self.haveWidth and (n & 1) == 1) {
      n -= 1;
      self.haveWidth = true;
    } else {
      self.haveWidth = true;
    }
    self.nStems += @intCast(n / 2);
    self.sp = 0;
  }

  fn rmoveto(self: *Interp) void {
    const base = self.widthBase(2);
    self.moveTo(self.x + self.stack[base], self.y + self.stack[base + 1]);
    self.sp = 0;
  }
  fn hmoveto(self: *Interp) void {
    const base = self.widthBase(1);
    self.moveTo(self.x + self.stack[base], self.y);
    self.sp = 0;
  }
  fn vmoveto(self: *Interp) void {
    const base = self.widthBase(1);
    self.moveTo(self.x, self.y + self.stack[base]);
    self.sp = 0;
  }

  fn rlineto(self: *Interp) void {
    var i: usize = 0;
    while (i + 2 <= self.sp) : (i += 2) self.lineTo(self.x + self.stack[i], self.y + self.stack[i + 1]);
    self.sp = 0;
  }

  // hlineto/vlineto: alternating axis-aligned lines. `horiz` = first line is horizontal.
  fn altLineto(self: *Interp, horiz0: bool) void {
    var horiz = horiz0;
    var i: usize = 0;
    while (i < self.sp) : (i += 1) {
      if (horiz) self.lineTo(self.x + self.stack[i], self.y) else self.lineTo(self.x, self.y + self.stack[i]);
      horiz = !horiz;
    }
    self.sp = 0;
  }

  fn rrcurveto(self: *Interp) void {
    var i: usize = 0;
    while (i + 6 <= self.sp) : (i += 6)
      self.rcurve(self.stack[i], self.stack[i + 1], self.stack[i + 2], self.stack[i + 3], self.stack[i + 4], self.stack[i + 5]);
    self.sp = 0;
  }

  fn rcurveline(self: *Interp) void {
    var i: usize = 0;
    while (i + 6 <= self.sp - 2) : (i += 6)
      self.rcurve(self.stack[i], self.stack[i + 1], self.stack[i + 2], self.stack[i + 3], self.stack[i + 4], self.stack[i + 5]);
    if (i + 2 <= self.sp) self.lineTo(self.x + self.stack[i], self.y + self.stack[i + 1]);
    self.sp = 0;
  }

  fn rlinecurve(self: *Interp) void {
    var i: usize = 0;
    while (i + 2 <= self.sp - 6) : (i += 2) self.lineTo(self.x + self.stack[i], self.y + self.stack[i + 1]);
    if (i + 6 <= self.sp)
      self.rcurve(self.stack[i], self.stack[i + 1], self.stack[i + 2], self.stack[i + 3], self.stack[i + 4], self.stack[i + 5]);
    self.sp = 0;
  }

  fn vvcurveto(self: *Interp) void {
    var i: usize = 0;
    var dx1: f64 = 0;
    if ((self.sp & 1) == 1) {
      dx1 = self.stack[0];
      i = 1;
    }
    while (i + 4 <= self.sp) : (i += 4) {
      self.rcurve(dx1, self.stack[i], self.stack[i + 1], self.stack[i + 2], 0, self.stack[i + 3]);
      dx1 = 0;
    }
    self.sp = 0;
  }

  fn hhcurveto(self: *Interp) void {
    var i: usize = 0;
    var dy1: f64 = 0;
    if ((self.sp & 1) == 1) {
      dy1 = self.stack[0];
      i = 1;
    }
    while (i + 4 <= self.sp) : (i += 4) {
      self.rcurve(self.stack[i], dy1, self.stack[i + 1], self.stack[i + 2], self.stack[i + 3], 0);
      dy1 = 0;
    }
    self.sp = 0;
  }

  // hvcurveto/vhcurveto: alternating curves whose start/end tangents are axis-aligned.
  fn altCurveto(self: *Interp, horiz0: bool) void {
    var horiz = horiz0;
    var i: usize = 0;
    while (i + 4 <= self.sp) {
      const last = (self.sp - i) == 5;
      const df: f64 = if (last) self.stack[i + 4] else 0;
      if (horiz) {
        self.rcurve(self.stack[i], 0, self.stack[i + 1], self.stack[i + 2], df, self.stack[i + 3]);
      } else {
        self.rcurve(0, self.stack[i], self.stack[i + 1], self.stack[i + 2], self.stack[i + 3], df);
      }
      horiz = !horiz;
      i += 4;
    }
    self.sp = 0;
  }

  fn flex(self: *Interp) void {
    if (self.sp < 12) {
      self.sp = 0;
      return;
    }
    self.rcurve(self.stack[0], self.stack[1], self.stack[2], self.stack[3], self.stack[4], self.stack[5]);
    self.rcurve(self.stack[6], self.stack[7], self.stack[8], self.stack[9], self.stack[10], self.stack[11]);
    self.sp = 0;
  }

  fn hflex(self: *Interp) void {
    if (self.sp < 7) {
      self.sp = 0;
      return;
    }
    self.rcurve(self.stack[0], 0, self.stack[1], self.stack[2], self.stack[3], 0);
    self.rcurve(self.stack[4], 0, self.stack[5], -self.stack[2], self.stack[6], 0);
    self.sp = 0;
  }

  fn hflex1(self: *Interp) void {
    if (self.sp < 9) {
      self.sp = 0;
      return;
    }
    self.rcurve(self.stack[0], self.stack[1], self.stack[2], self.stack[3], self.stack[4], 0);
    self.rcurve(self.stack[5], 0, self.stack[6], self.stack[7], self.stack[8], -(self.stack[1] + self.stack[3] + self.stack[7]));
    self.sp = 0;
  }

  fn flex1(self: *Interp) void {
    if (self.sp < 11) {
      self.sp = 0;
      return;
    }
    const dx = self.stack[0] + self.stack[2] + self.stack[4] + self.stack[6] + self.stack[8];
    const dy = self.stack[1] + self.stack[3] + self.stack[5] + self.stack[7] + self.stack[9];
    self.rcurve(self.stack[0], self.stack[1], self.stack[2], self.stack[3], self.stack[4], self.stack[5]);
    if (@abs(dx) > @abs(dy)) {
      self.rcurve(self.stack[6], self.stack[7], self.stack[8], self.stack[9], self.stack[10], -dy);
    } else {
      self.rcurve(self.stack[6], self.stack[7], self.stack[8], self.stack[9], -dx, self.stack[10]);
    }
    self.sp = 0;
  }

  fn run(self: *Interp, code: []const u8, depth: u32) void {
    if (depth > 10) return;
    var i: usize = 0;
    while (i < code.len and !self.done) {
      const b = code[i];
      i += 1;
      if (b >= 32) {
        if (b <= 246) {
          self.push(@floatFromInt(@as(i32, b) - 139));
        } else if (b <= 250) {
          if (i >= code.len) break;
          const b1 = code[i];
          i += 1;
          self.push(@floatFromInt((@as(i32, b) - 247) * 256 + @as(i32, b1) + 108));
        } else if (b <= 254) {
          if (i >= code.len) break;
          const b1 = code[i];
          i += 1;
          self.push(@floatFromInt(-(@as(i32, b) - 251) * 256 - @as(i32, b1) - 108));
        } else { // 255: 16.16 fixed
          if (i + 4 > code.len) break;
          const v = std.mem.readInt(i32, code[i..][0..4], .big);
          i += 4;
          self.push(@as(f64, @floatFromInt(v)) / 65536.0);
        }
        continue;
      }
      if (b == 28) {
        if (i + 2 > code.len) break;
        const v = std.mem.readInt(i16, code[i..][0..2], .big);
        i += 2;
        self.push(@floatFromInt(v));
        continue;
      }
      switch (b) {
        1, 3, 18, 23 => self.countStems(),
        19, 20 => {
          self.countStems();
          i += (self.nStems + 7) / 8;
        },
        21 => self.rmoveto(),
        22 => self.hmoveto(),
        4 => self.vmoveto(),
        5 => self.rlineto(),
        6 => self.altLineto(true),
        7 => self.altLineto(false),
        8 => self.rrcurveto(),
        24 => self.rcurveline(),
        25 => self.rlinecurve(),
        26 => self.vvcurveto(),
        27 => self.hhcurveto(),
        30 => self.altCurveto(false),
        31 => self.altCurveto(true),
        10 => { // callsubr
          if (self.sp == 0) continue;
          self.sp -= 1;
          const idx = @as(i32, @intFromFloat(self.stack[self.sp])) + self.lbias;
          if (idx >= 0 and idx < self.lsubrs.len) self.run(self.lsubrs[@intCast(idx)], depth + 1);
        },
        29 => { // callgsubr
          if (self.sp == 0) continue;
          self.sp -= 1;
          const idx = @as(i32, @intFromFloat(self.stack[self.sp])) + self.gbias;
          if (idx >= 0 and idx < self.gsubrs.len) self.run(self.gsubrs[@intCast(idx)], depth + 1);
        },
        11 => return, // return
        14 => { // endchar
          _ = self.widthBase(0);
          self.done = true;
          return;
        },
        12 => {
          if (i >= code.len) break;
          const b2 = code[i];
          i += 1;
          switch (b2) {
            35 => self.flex(),
            34 => self.hflex(),
            36 => self.hflex1(),
            37 => self.flex1(),
            else => self.sp = 0,
          }
        },
        else => self.sp = 0,
      }
    }
  }
};

/// Interpret one glyph charstring → L of flat F contours (pixel, y-flipped).
/// `quads`=false: flattened polylines. `quads`=true: RAW quadratic control triples
/// [x0 y0 cx cy x1 y1 …] (cubics split to 2 quads, lines → degenerate quads) for the
/// analytic Slug renderer — same shape as font.glyf.quads.
pub fn outline(charstring: []const u8, gsubrs: [][]const u8, lsubrs: [][]const u8, scale: f64) ?k.K {
  return interp(charstring, gsubrs, lsubrs, scale, false);
}
pub fn outlineQuads(charstring: []const u8, gsubrs: [][]const u8, lsubrs: [][]const u8, scale: f64) ?k.K {
  return interp(charstring, gsubrs, lsubrs, scale, true);
}
fn interp(charstring: []const u8, gsubrs: [][]const u8, lsubrs: [][]const u8, scale: f64, quads: bool) ?k.K {
  var it = Interp{
    .gsubrs = gsubrs,
    .lsubrs = lsubrs,
    .gbias = bias(gsubrs.len),
    .lbias = bias(lsubrs.len),
    .scale = scale,
    .quads = quads,
    .contours = .empty,
    .cur = .empty,
  };
  defer {
    for (it.contours.items) |*c| c.deinit(alloc);
    it.contours.deinit(alloc);
    it.cur.deinit(alloc);
  }

  it.run(charstring, 0);
  if (it.open) it.flushContour();

  const list = k.KL(it.contours.items.len) orelse return null;
  for (it.contours.items, 0..) |c, ci| {
    const flat = k.KF(c.items.len * 2) orelse continue;
    if (k.fp(flat)) |p| {
      for (c.items, 0..) |pt, j| {
        p[j * 2] = pt[0];
        p[j * 2 + 1] = pt[1];
      }
    }
    k.listSet(list, ci, flat);
  }
  return list;
}
