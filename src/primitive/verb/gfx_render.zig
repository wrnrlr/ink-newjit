/// Shared NanoVG/ink rendering logic for the `9:` graphics command set.
/// Used by both the standalone runner (runner.zig) and the inline notebook widget.
const std = @import("std");
const ink = @import("ink");
const color = ink.colors;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const V = value.V;

// ── Color helpers ─────────────────────────────────────────────────────────────

fn srgbToLinear(x: f32) f32 {
  return if (x <= 0.04045) x / 12.92
         else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

fn rgbToLch(r: f32, g: f32, b: f32) ink.Lch {
  const rl = srgbToLinear(r);
  const gl = srgbToLinear(g);
  const bl = srgbToLinear(b);
  const lm = std.math.cbrt(0.4122214708 * rl + 0.5363325363 * gl + 0.0514459929 * bl);
  const mm = std.math.cbrt(0.2119034982 * rl + 0.6806995451 * gl + 0.1073969566 * bl);
  const sm = std.math.cbrt(0.0883024619 * rl + 0.2817188376 * gl + 0.6299787005 * bl);
  const L  = 0.2104542553 * lm + 0.7936177850 * mm - 0.0040720468 * sm;
  const a  = 1.9779984951 * lm - 2.4285922050 * mm + 0.4505937099 * sm;
  const bv = 0.0259040371 * lm + 0.7827717662 * mm - 0.8086757660 * sm;
  const c  = @sqrt(a * a + bv * bv);
  const h  = std.math.atan2(bv, a) * (180.0 / std.math.pi);
  return .{ .l = L, .c = c, .h = if (h < 0) h + 360.0 else h };
}

fn resolveColorName(name: []const u8) ?ink.Lch {
  if (std.mem.eql(u8, name, "white") or std.mem.eql(u8, name, "White")) return color.White;
  if (std.mem.eql(u8, name, "black") or std.mem.eql(u8, name, "Black")) return color.Black;
  if (std.mem.eql(u8, name, "transparent") or std.mem.eql(u8, name, "Transparent")) return .{ .l = 0, .c = 0, .h = 0, .a = 0 };
  inline for (@typeInfo(ink).@"struct".decls) |decl| {
    if (@TypeOf(@field(ink, decl.name)) == ink.Lch)
      if (std.mem.eql(u8, name, decl.name)) return @field(ink, decl.name);
  }
  return null;
}

pub fn resolveColorV(vm: *VM, v: V) ?ink.Lch {
  return switch (v.tag()) {
    .s => resolveColorName(vm.getSymbol(v.s)),
    .I => blk: {
      const sl = v.I.slice();
      if (sl.len < 3) break :blk null;
      var col = rgbToLch(
        @as(f32, @floatFromInt(sl[0])) / 255.0,
        @as(f32, @floatFromInt(sl[1])) / 255.0,
        @as(f32, @floatFromInt(sl[2])) / 255.0,
      );
      if (sl.len >= 4) col.a = @as(f32, @floatFromInt(sl[3])) / 255.0;
      break :blk col;
    },
    .F => blk: {
      const sl = v.F.slice();
      if (sl.len < 3) break :blk null;
      var col = rgbToLch(@floatCast(sl[0]), @floatCast(sl[1]), @floatCast(sl[2]));
      if (sl.len >= 4) col.a = @floatCast(sl[3]);
      break :blk col;
    },
    else => null,
  };
}

fn resolveGradient(vm: *VM, v: V) ?ink.Paint {
  if (v.tag() != .m) return null;
  const keys = v.m.av();
  const vals = v.m.bv();
  if (keys.tag() == .s) {
    const sym_arr = [1]u32{ keys.s };
    const val_arr = [1]V{ vals };
    return resolveGradientKV(vm, &sym_arr, &val_arr);
  }
  if (keys.tag() == .L and vals.tag() == .L) {
    const ks_slice = keys.L.slice();
    const vs_slice = vals.L.slice();
    if (ks_slice.len != vs_slice.len) return null;
    var sym_ids: [16]u32 = undefined;
    const n = @min(ks_slice.len, sym_ids.len);
    for (0..n) |i| {
      if (ks_slice[i].tag() != .s) return null;
      sym_ids[i] = ks_slice[i].s;
    }
    return resolveGradientKV(vm, sym_ids[0..n], vs_slice[0..n]);
  }
  if (keys.tag() != .S or vals.tag() != .L) return null;
  return resolveGradientKV(vm, keys.S.slice(), vals.L.slice());
}

fn resolveGradientKV(vm: *VM, ks: []const u32, vs: []const V) ?ink.Paint {
  for (ks, 0..) |sym, i| {
    const kname = vm.getSymbol(sym);
    const val = vs[i];
    if (val.tag() != .L) continue;
    const sl = val.L.slice();
    if (sl.len < 3) continue;
    const c0 = resolveColorV(vm, sl[1]) orelse color.Black;
    const c1 = resolveColorV(vm, sl[2]) orelse color.White;
    if (std.mem.eql(u8, kname, "linear")) {
      var coords: [4]f32 = .{ 0, 0, 100, 0 };
      _ = extractFloats(sl[0], &coords);
      return ink.linearGradient(coords[0], coords[1], coords[2], coords[3], c0, c1);
    } else if (std.mem.eql(u8, kname, "radial")) {
      var coords: [4]f32 = .{ 0, 0, 0, 100 };
      _ = extractFloats(sl[0], &coords);
      return ink.radialGradient(coords[0], coords[1], coords[2], coords[3], c0, c1);
    } else if (std.mem.eql(u8, kname, "box")) {
      var coords: [6]f32 = .{ 0, 0, 100, 100, 5, 10 };
      _ = extractFloats(sl[0], &coords);
      return ink.boxGradient(coords[0], coords[1], coords[2], coords[3], coords[4], coords[5], c0, c1);
    }
  }
  return null;
}

pub fn extractFloats(v: V, buf: []f32) usize {
  var n: usize = 0;
  switch (v.tag()) {
    .b => { if (n < buf.len) { buf[n] = if (v.b) 1.0 else 0.0; n += 1; } },
    .i => { if (n < buf.len) { buf[n] = @floatFromInt(v.i);     n += 1; } },
    .f => { if (n < buf.len) { buf[n] = @floatCast(v.f);        n += 1; } },
    .I => for (v.I.slice()) |x| { if (n >= buf.len) break; buf[n] = @floatFromInt(x); n += 1; },
    .F => for (v.F.slice()) |x| { if (n >= buf.len) break; buf[n] = @floatCast(x);   n += 1; },
    .L => for (v.L.slice()) |item| { if (n >= buf.len) break; n += extractFloats(item, buf[n..]); },
    else => {},
  }
  return n;
}

fn hasClosedShape(ks: []const u32, vm: *VM) bool {
  for (ks) |sym| {
    const n = vm.getSymbol(sym);
    if (std.mem.eql(u8, n, "rect") or std.mem.eql(u8, n, "rrect") or
        std.mem.eql(u8, n, "circle") or std.mem.eql(u8, n, "ellipse")) return true;
  }
  return false;
}

// ── Command rendering ─────────────────────────────────────────────────────────

pub fn renderDict(vm: *VM, d: V) void {
  if (d.tag() != .m) return;
  const keys = d.m.av();
  const vals = d.m.bv();

  if (keys.tag() == .s) {
    const sym_arr = [1]u32{ keys.s };
    const val_arr = [1]V{ vals };
    renderDictKV(vm, &sym_arr, &val_arr);
    return;
  }

  if (keys.tag() == .L and vals.tag() == .L) {
    const ks_slice = keys.L.slice();
    const vs_slice = vals.L.slice();
    if (ks_slice.len != vs_slice.len) return;
    var sym_ids: [16]u32 = undefined;
    const n = @min(ks_slice.len, sym_ids.len);
    for (0..n) |i| {
      if (ks_slice[i].tag() != .s) return;
      sym_ids[i] = ks_slice[i].s;
    }
    renderDictKV(vm, sym_ids[0..n], vs_slice[0..n]);
    return;
  }
  if (keys.tag() != .S or vals.tag() != .L) return;
  renderDictKV(vm, keys.S.slice(), vals.L.slice());
}

fn renderDictKV(vm: *VM, ks: []const u32, vs: []const V) void {
  const auto_path = hasClosedShape(ks, vm);
  var fill_set = false;
  var stroke_set = false;
  var has_text = false;
  var text_str: []const u8 = "";
  var text_x: f32 = 0;
  var text_y: f32 = 0;
  var text_size: f32 = 0;

  if (auto_path) ink.beginPath();

  for (ks, 0..) |sym, i| {
    const kname = vm.getSymbol(sym);
    const val = vs[i];
    var buf: [8]f32 = undefined;
    const n = extractFloats(val, &buf);

    if (std.mem.eql(u8, kname, "move") or std.mem.eql(u8, kname, "m")) {
      if (n >= 2) ink.moveTo(buf[0], buf[1]);
    } else if (std.mem.eql(u8, kname, "line") or std.mem.eql(u8, kname, "l")) {
      switch (val.tag()) {
        .L => for (val.L.slice()) |item| {
          var pair: [2]f32 = undefined;
          if (extractFloats(item, &pair) >= 2) ink.lineTo(pair[0], pair[1]);
        },
        .I => {
          const slice = val.I.slice();
          var j: usize = 0;
          while (j + 1 < slice.len) : (j += 2)
            ink.lineTo(@floatFromInt(slice[j]), @floatFromInt(slice[j + 1]));
        },
        .F => {
          const slice = val.F.slice();
          var j: usize = 0;
          while (j + 1 < slice.len) : (j += 2)
            ink.lineTo(@floatCast(slice[j]), @floatCast(slice[j + 1]));
        },
        else => if (n >= 2) ink.lineTo(buf[0], buf[1]),
      }
    } else if (std.mem.eql(u8, kname, "bezier") or std.mem.eql(u8, kname, "b")) {
      if (n >= 6) ink.bezierTo(buf[0], buf[1], buf[2], buf[3], buf[4], buf[5]);
    } else if (std.mem.eql(u8, kname, "quad") or std.mem.eql(u8, kname, "q")) {
      if (n >= 4) ink.quadTo(buf[0], buf[1], buf[2], buf[3]);
    } else if (std.mem.eql(u8, kname, "rect")) {
      if (n >= 4) ink.rect(buf[0], buf[1], buf[2], buf[3]);
    } else if (std.mem.eql(u8, kname, "rrect")) {
      if (n >= 5) ink.roundedRect(buf[0], buf[1], buf[2], buf[3], buf[4]);
    } else if (std.mem.eql(u8, kname, "circle")) {
      if (n >= 3) ink.circle(buf[0], buf[1], buf[2]);
    } else if (std.mem.eql(u8, kname, "ellipse")) {
      if (n >= 4) ink.ellipse(buf[0], buf[1], buf[2], buf[3]);
    } else if (std.mem.eql(u8, kname, "fill")) {
      if (resolveGradient(vm, val)) |paint| ink.fillPaint(paint)
      else if (resolveColorV(vm, val)) |c| ink.fillColor(c);
      fill_set = true;
    } else if (std.mem.eql(u8, kname, "stroke")) {
      if (resolveColorV(vm, val)) |c| ink.strokeColor(c);
      stroke_set = true;
    } else if (std.mem.eql(u8, kname, "width") or std.mem.eql(u8, kname, "w")) {
      if (n >= 1) ink.strokeWidth(buf[0]);
    } else if (std.mem.eql(u8, kname, "translate")) {
      if (n >= 2) ink.translate(buf[0], buf[1]);
    } else if (std.mem.eql(u8, kname, "rotate")) {
      if (n >= 1) ink.rotate(buf[0]);
    } else if (std.mem.eql(u8, kname, "scale")) {
      if (n >= 2) ink.scale(buf[0], buf[1]) else if (n >= 1) ink.scale(buf[0], buf[0]);
    } else if (std.mem.eql(u8, kname, "save")) {
      ink.save();
    } else if (std.mem.eql(u8, kname, "restore")) {
      ink.restore();
    } else if (std.mem.eql(u8, kname, "text")) {
      has_text = true;
      if (val.tag() == .C) text_str = val.C.slice();
    } else if (std.mem.eql(u8, kname, "at")) {
      if (n >= 2) { text_x = buf[0]; text_y = buf[1]; }
    } else if (std.mem.eql(u8, kname, "size")) {
      if (n >= 1) text_size = buf[0];
    } else if (std.mem.eql(u8, kname, "align")) {
      if (val.tag() == .s) {
        const aname = vm.getSymbol(val.s);
        const h: @FieldType(ink.TextAlign, "horizontal") =
          if (std.mem.eql(u8, aname, "center")) .center
          else if (std.mem.eql(u8, aname, "end") or std.mem.eql(u8, aname, "right")) .right
          else .left;
        ink.textAlign(.{ .horizontal = h });
      }
    }
  }

  if (auto_path) {
    if (fill_set) ink.fill();
    if (stroke_set) ink.stroke();
  }
  if (has_text and text_str.len > 0) {
    if (text_size > 0) ink.fontSize(text_size);
    _ = ink.text(text_x, text_y, text_str);
  }
}

fn renderTable(vm: *VM, d: V) void {
  if (d.tag() != .M) return;
  const keys = d.M.av();
  const cols_v = d.M.bv();
  if (keys.tag() != .S or cols_v.tag() != .L) return;
  const ks = keys.S.slice();
  const cols = cols_v.L.slice();
  if (ks.len != cols.len or cols.len == 0) return;
  const n = d.len();
  const ncols = @min(ks.len, 16);
  var row_vals: [16]V = undefined;
  for (0..n) |i| {
    for (0..ncols) |j| row_vals[j] = cols[j].at(i);
    renderDictKV(vm, ks[0..ncols], row_vals[0..ncols]);
  }
}

/// Render a single command. `animate` is set to true when an `animate` symbol
/// is encountered; pass null to ignore it (e.g. in static notebook output).
pub fn renderCmd(vm: *VM, cmd: V, animate: ?*bool) void {
  switch (cmd.tag()) {
    .s => {
      const name = vm.getSymbol(cmd.s);
      if      (std.mem.eql(u8, name, "path") or std.mem.eql(u8, name, "Path")) ink.beginPath()
      else if (std.mem.eql(u8, name, "close"))   ink.closePath()
      else if (std.mem.eql(u8, name, "fill"))    ink.fill()
      else if (std.mem.eql(u8, name, "stroke"))  ink.stroke()
      else if (std.mem.eql(u8, name, "save"))    ink.save()
      else if (std.mem.eql(u8, name, "restore")) ink.restore()
      else if (std.mem.eql(u8, name, "animate")) { if (animate) |a| a.* = true; }
    },
    .m => renderDict(vm, cmd),
    .M => renderTable(vm, cmd),
    .L => {
      const sl = cmd.L.slice();
      // 2-element [attrs_dict; children_list] — scoped group
      if (sl.len == 2 and sl[0].tag() == .m and sl[1].tag() == .L) {
        ink.save();
        renderDict(vm, sl[0]);
        renderCmds(vm, sl[1], animate);
        ink.restore();
      } else {
        renderCmds(vm, cmd, animate);
      }
    },
    else => {},
  }
}

pub fn renderCmds(vm: *VM, cmds: V, animate: ?*bool) void {
  switch (cmds.tag()) {
    .L => for (cmds.L.slice()) |cmd| renderCmd(vm, cmd, animate),
    else => renderCmd(vm, cmds, animate),
  }
}

// ── Bounds computation ────────────────────────────────────────────────────────

/// Compute the maximum y-extent of all geometry in a command list.
/// Used by the notebook to auto-size inline graphics cells.
pub fn computeMaxY(vm: *VM, cmds: V) f32 {
  var max_y: f32 = 0;
  maxYCmd(vm, cmds, &max_y);
  return max_y;
}

fn maxYCmd(vm: *VM, cmd: V, max_y: *f32) void {
  switch (cmd.tag()) {
    .m => maxYDict(vm, cmd, max_y),
    .M => {
      const keys = cmd.M.av();
      const cols_v = cmd.M.bv();
      if (keys.tag() == .S and cols_v.tag() == .L) {
        const ks = keys.S.slice();
        const cols = cols_v.L.slice();
        const ncols = @min(ks.len, 16);
        if (ks.len == cols.len and cols.len > 0) {
          const n = cmd.len();
          var row_vals: [16]V = undefined;
          for (0..n) |i| {
            for (0..ncols) |j| row_vals[j] = cols[j].at(i);
            maxYDictKV(vm, ks[0..ncols], row_vals[0..ncols], max_y);
          }
        }
      }
    },
    .L => {
      const sl = cmd.L.slice();
      // 2-element [attrs_dict; children_list] — scoped group
      if (sl.len == 2 and sl[0].tag() == .m and sl[1].tag() == .L) {
        maxYDict(vm, sl[0], max_y);
        maxYCmd(vm, sl[1], max_y);
      } else {
        for (sl) |c| maxYCmd(vm, c, max_y);
      }
    },
    else => {},
  }
}

fn maxYDict(vm: *VM, d: V, max_y: *f32) void {
  if (d.tag() != .m) return;
  const keys = d.m.av();
  const vals = d.m.bv();
  if (keys.tag() == .s) {
    maxYDictKV(vm, &[1]u32{keys.s}, &[1]V{vals}, max_y);
  } else if (keys.tag() == .L and vals.tag() == .L) {
    const ks_slice = keys.L.slice();
    const vs_slice = vals.L.slice();
    if (ks_slice.len != vs_slice.len) return;
    var sym_ids: [16]u32 = undefined;
    const n = @min(ks_slice.len, sym_ids.len);
    for (0..n) |i| {
      if (ks_slice[i].tag() != .s) return;
      sym_ids[i] = ks_slice[i].s;
    }
    maxYDictKV(vm, sym_ids[0..n], vs_slice[0..n], max_y);
  } else if (keys.tag() == .S and vals.tag() == .L) {
    maxYDictKV(vm, keys.S.slice(), vals.L.slice(), max_y);
  }
}

fn maxYDictKV(vm: *VM, ks: []const u32, vs: []const V, max_y: *f32) void {
  var text_y: f32 = 0;
  var text_size: f32 = 0;
  var has_text = false;

  for (ks, 0..) |sym, i| {
    const kname = vm.getSymbol(sym);
    const val = vs[i];
    var buf: [8]f32 = undefined;
    const n = extractFloats(val, &buf);

    if (std.mem.eql(u8, kname, "rect") or std.mem.eql(u8, kname, "rrect")) {
      // rect: x y w h  →  y + h
      if (n >= 4) max_y.* = @max(max_y.*, buf[1] + buf[3]);
    } else if (std.mem.eql(u8, kname, "circle")) {
      // circle: cx cy r  →  cy + r
      if (n >= 3) max_y.* = @max(max_y.*, buf[1] + buf[2]);
    } else if (std.mem.eql(u8, kname, "ellipse")) {
      // ellipse: cx cy rx ry  →  cy + ry
      if (n >= 4) max_y.* = @max(max_y.*, buf[1] + buf[3]);
    } else if (std.mem.eql(u8, kname, "move") or std.mem.eql(u8, kname, "m")) {
      if (n >= 2) max_y.* = @max(max_y.*, buf[1]);
    } else if (std.mem.eql(u8, kname, "line") or std.mem.eql(u8, kname, "l")) {
      switch (val.tag()) {
        .L => for (val.L.slice()) |item| {
          var pair: [2]f32 = undefined;
          if (extractFloats(item, &pair) >= 2) max_y.* = @max(max_y.*, pair[1]);
        },
        .I => {
          const sl = val.I.slice();
          var j: usize = 1;
          while (j < sl.len) : (j += 2) max_y.* = @max(max_y.*, @as(f32, @floatFromInt(sl[j])));
        },
        .F => {
          const sl = val.F.slice();
          var j: usize = 1;
          while (j < sl.len) : (j += 2) max_y.* = @max(max_y.*, @as(f32, @floatCast(sl[j])));
        },
        else => { if (n >= 2) max_y.* = @max(max_y.*, buf[1]); },
      }
    } else if (std.mem.eql(u8, kname, "bezier") or std.mem.eql(u8, kname, "b")) {
      // bezier: x1 y1 x2 y2 x3 y3
      if (n >= 6) max_y.* = @max(max_y.*, @max(buf[1], @max(buf[3], buf[5])));
    } else if (std.mem.eql(u8, kname, "quad") or std.mem.eql(u8, kname, "q")) {
      // quad: x1 y1 x2 y2
      if (n >= 4) max_y.* = @max(max_y.*, @max(buf[1], buf[3]));
    } else if (std.mem.eql(u8, kname, "at")) {
      if (n >= 2) text_y = buf[1];
    } else if (std.mem.eql(u8, kname, "text")) {
      has_text = true;
    } else if (std.mem.eql(u8, kname, "size")) {
      if (n >= 1) text_size = buf[0];
    }
  }

  if (has_text) max_y.* = @max(max_y.*, text_y + text_size);
}

/// Parse a `{render:'gfx; cmds:L}` dict and execute the draw commands.
/// Returns true if the dict was a valid gfx render dict.
pub fn dispatchGfx(vm: *VM, result: V, animate: ?*bool) bool {
  if (result.tag() != .m) return false;
  const keys = result.m.av();
  const vals = result.m.bv();
  if (keys.tag() != .S or vals.tag() != .L) return false;

  var render_is_gfx = false;
  var cmds: ?V = null;

  for (keys.S.slice(), 0..) |sym, i| {
    const name = vm.getSymbol(sym);
    if (std.mem.eql(u8, name, "render")) {
      const rv = vals.L.slice()[i];
      if (rv.tag() == .s) render_is_gfx = std.mem.eql(u8, vm.getSymbol(rv.s), "gfx");
    } else if (std.mem.eql(u8, name, "cmds")) {
      cmds = vals.L.slice()[i];
    }
  }

  if (render_is_gfx) {
    if (cmds) |c| renderCmds(vm, c, animate);
    return true;
  }
  return false;
}
