const std = @import("std");
const VM = @import("../runtime/vm.zig").VM;
const V = @import("./value.zig").V;
const Fn = @import("./operator.zig").Fn;
const Adverb = @import("./operator.zig").Adverb;
const FnKind = @import("./operator.zig").FnKind;
const Dict = @import("./dict.zig").Dict;
const Alloc = std.mem.Allocator;

// A symbol name is "identifier-shaped" if it reads back as a bare k name: a
// leading letter followed by letters/digits/dots. Used to pick bare vs quoted
// rendering for error names.
fn isIdentSym(s: []const u8) bool {
  if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
  for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.') return false;
  return true;
}

fn adverbStr(adv: Adverb) []const u8 {
  return switch (adv) {
    .@"'" => "'", .@"/" => "/", .@"\\" => "\\",
    .@"':" => "':", .@"/:" => "/:", .@"\\:" => "\\:",
  };
}

pub const Formatter = struct {
  ctx: *anyopaque,
  fmtFn: *const fn (f: *anyopaque, v: V, w: *std.Io.Writer) anyerror!void,
  pub fn fmt(f: Formatter, v: V, w: *std.Io.Writer) !void { try f.fmtFn(f.ctx, v, w); }
};

pub const TerseFormatter = struct {
  vm: *const VM,
  alloc: Alloc,
  mode: Mode,
  indent: usize = 0,
  force_single_line: bool = false,
  // When set, top-level dicts/tables/keyed-tables print in the multi-line REPL
  // form (key|value lines, header/separator/row table grid) instead of the
  // single-line k literal. Only the REPL turns this on, and only for entries
  // that do not start with whitespace.
  pretty: bool = false,

  pub const Mode = enum { Repl, Text };

  const Self = @This();

  pub fn init(vm: *const VM, alloc: Alloc, mode: Mode) Self {
    return .{
      .vm = vm,
      .alloc = alloc,
      .mode = mode,
      .force_single_line = (mode == .Text),
    };
  }

  pub fn formatter(self: *Self) Formatter {
    return Formatter{
      .ctx = self,
      .fmtFn = struct {
        fn fmt(ctx: *anyopaque, v: V, w: *std.Io.Writer) anyerror!void {
          const s: *Self = @ptrCast(@alignCast(ctx));
          try s.formatTop(v, w);
        }
      }.fmt,
    };
  }

  fn formatValue(self: *Self, v: V, w: anytype) anyerror!void {
    switch (v) {
      .i => |a| {
        if (a == std.math.minInt(i32)) try w.writeAll("0N")
        else if (a == std.math.maxInt(i32)) try w.writeAll("0W")
        else if (a == std.math.minInt(i32) + 1) try w.writeAll("-0W")
        else try w.print("{d}", .{a});
      },
      .f => |a| {
        if (std.math.isNan(a)) {
          try w.writeAll("0n");
        } else if (std.math.isInf(a)) {
          try w.writeAll(if (a > 0) "0w" else "-0w");
        } else {
          var buf: [64]u8 = undefined;
          const s = try std.fmt.bufPrint(&buf, "{d}", .{a});
          try w.writeAll(s);
          if (std.mem.indexOfScalar(u8, s, '.') == null and std.mem.indexOfScalar(u8, s, 'e') == null) {
            try w.writeAll(".0");
          }
        }
      },
      .c => |a| {
        const byte: u8 = @intCast(a);
        try w.writeAll("\"");
        switch (byte) {
          0    => try w.writeAll("\\0"),
          '\n' => try w.writeAll("\\n"),
          '\t' => try w.writeAll("\\t"),
          '\\' => try w.writeAll("\\\\"),
          else => try w.writeByte(byte),
        }
        try w.writeAll("\"");
      },
      .b => |a| try w.print("{d}b", .{@as(u8, if (a) 1 else 0)}),
      .n => |a| try formatNat(a, w),
      .d => |a| try formatFloatSuffix(f64, a, "d", w),
      .h => |a| try formatFloatSuffix(f16, a, "h", w),
      .N => |vec| {
        const s = vec.slice();
        if (s.len == 0) { try w.writeAll("&0"); return; }
        if (s.len == 1) try w.writeAll(",");
        for (s, 0..) |e, i| {
          if (i > 0) try w.writeAll(" ");
          try formatNat(e, w);
        }
      },
      .D => |vec| {
        const s = vec.slice();
        if (s.len == 0) { try w.writeAll("!0.0d"); return; }
        if (s.len == 1) try w.writeAll(",");
        for (s, 0..) |e, i| {
          if (i > 0) try w.writeAll(" ");
          try formatFloatSuffix(f64, e, "d", w);
        }
      },
      .H => |vec| {
        const s = vec.slice();
        if (s.len == 0) { try w.writeAll("!0.0h"); return; }
        if (s.len == 1) try w.writeAll(",");
        for (s, 0..) |e, i| {
          if (i > 0) try w.writeAll(" ");
          try formatFloatSuffix(f16, e, "h", w);
        }
      },
      .s => |a| {
        if (a < self.vm.symbolCount()) {
          try w.print("`{s}", .{self.vm.getSymbol(a)});
        } else {
          try w.print("`{d}", .{a});
        }
      },
      .I => |n| try self.formatVector(i32, n.slice(), w),
      .F => |n| try self.formatVector(f32, n.slice(), w),
      .S => |n| try self.formatVector(u32, n.slice(), w),
      .C => |n| try self.formatVector(u8, n.slice(), w),
      .B => |n| try self.formatVector(bool, n.slice(), w),
      .L => |n| {
        const slice = n.slice();
        if (slice.len == 0) {
          try w.writeAll("()");
          return;
        }

        if (slice.len == 1) {
          try w.writeAll(",");
          try self.formatValue(slice[0], w);
          return;
        }

        try w.writeAll("(");
        const is_multiline = !self.force_single_line and self.isComplex(v);
        const old_single = self.force_single_line;
        if (is_multiline) {
          self.force_single_line = true;
          self.indent += 1;
        }

        for (slice, 0..) |item, i| {
          if (i > 0) {
            if (is_multiline) {
              try w.writeAll("\n");
              try self.writeIndent(w);
            } else {
              try w.writeAll(";");
            }
          }
          try self.formatValue(item, w);
        }
        if (is_multiline) self.indent -= 1;
        self.force_single_line = old_single;
        try w.writeAll(")");
      },
      .m => |d| try self.formatDict(d, w),
      .M => |d| try self.formatTable(d, w),
      .o => |ref| try self.formatFn(ref, w),
      .p => |p| {
        // Compact display for operator projections: 1+ or +1
        const opmod = @import("./operator.zig");
        const is_builtin = p.ref.kind == .callable and opmod.isBuiltinIdx(p.ref.idx) and p.ref.arity == 2;
        if (is_builtin and p.arity == 2) {
          const arg0_filled = p.fill & 1 != 0;
          const arg1_filled = p.fill & 2 != 0;
          if (arg0_filled and !arg1_filled) {
            try self.formatValue(p.args[0], w);
            try self.formatFn(p.ref, w);
            return;
          } else if (!arg0_filled and arg1_filled) {
            try self.formatFn(p.ref, w);
            try self.formatValue(p.args[1], w);
            return;
          }
        }
        try self.formatFn(p.ref, w);
        try w.writeAll("[");
        for (0..p.arity) |i| {
          if (i > 0) try w.writeAll(";");
          if (p.fill & (@as(u8, 1) << @intCast(i)) != 0)
            try self.formatValue(p.args[i], w);
        }
        try w.writeAll("]");
      },
      .x => |obj| {
        if (obj.vtable.format_fn) |fmt| {
          var buf: [256]u8 = undefined;
          const n = fmt(obj.data, &buf);
          try w.writeAll(buf[0..n]);
        } else {
          try w.print("<{s}>", .{obj.vtable.name});
        }
      },
      .err => |a| {
        // Errors carry a symbol-pool index. Identifier-shaped names print bare
        // (`!domain`); anything else (a message) is quoted (`!"cannot bake FOO"`)
        // so it round-trips through monadic `!` on the string.
        const idx = @intFromEnum(a);
        if (idx >= self.vm.symbolCount()) {
          try w.print("!`{d}", .{idx});
        } else {
          const nm = self.vm.getSymbol(idx);
          if (isIdentSym(nm)) try w.print("!{s}", .{nm}) else try w.print("!\"{s}\"", .{nm});
        }
      },
      .blank => {},
    }
  }

  fn formatFn(self: *Self, ref: Fn, w: anytype) anyerror!void {
    const opmod = @import("./operator.zig");
    switch (ref.kind) {
      .callable => {
        const idx = ref.idx;
        if (opmod.isLambdaIdx(idx)) {
          const entry = self.vm.fn_tables.lambdaAt(opmod.lambdaIdxOf(idx));
          try w.writeAll(self.vm.fs.getSource(entry.range));
        } else if (opmod.isOp1Idx(idx)) {
          try w.writeAll(opmod.op1OfIdx(idx).toString());
          try w.writeAll(":");
        } else if (opmod.isOp2Idx(idx)) {
          try w.writeAll(opmod.op2OfIdx(idx).toString());
        } else if (opmod.isAdverbIdx(idx)) {
          try w.writeAll(@tagName(opmod.adverbOfIdx(idx)));
        } else if (opmod.isOp3Idx(idx)) {
          try w.writeAll(opmod.op3OfIdx(idx).toString());
        } else if (opmod.isOp4Idx(idx)) {
          try w.writeAll(opmod.op4OfIdx(idx).toString());
        }
      },
      .derived => {
        const base_idx = ref.idx;
        if (opmod.isLambdaIdx(base_idx)) {
          try w.print("{{lambda:{d}}}", .{opmod.lambdaIdxOf(base_idx)});
        } else if (opmod.isOp1Idx(base_idx)) {
          try w.writeAll(opmod.op1OfIdx(base_idx).toString());
        } else if (opmod.isOp2Idx(base_idx)) {
          try w.writeAll(opmod.op2OfIdx(base_idx).toString());
        } else {
          try w.print("[builtin:{d}]", .{base_idx});
        }
        try w.writeAll(adverbStr(ref.getAdverb()));
      },
      .derived_data => {
        const entry = self.vm.fn_tables.derivedAt(@intCast(ref.idx));
        try self.formatValue(entry.base, w);
        try w.writeAll(adverbStr(entry.adverb));
      },
      .train => {
        var buf: [7]u8 = undefined;
        const ops = ref.trainOps(&buf);
        try w.writeAll(ops);
      },
    }
  }

  fn formatVector(self: *Self, comptime T: type, slice: []const T, w: anytype) anyerror!void {
    if (T == u8) {
      if (slice.len == 1) try w.writeAll(",");
      try w.writeAll("\"");
      for (slice) |c| {
        switch (c) {
          0    => try w.writeAll("\\0"),
          '\n' => try w.writeAll("\\n"),
          '\t' => try w.writeAll("\\t"),
          '\\' => try w.writeAll("\\\\"),
          else => try w.writeByte(c),
        }
      }
      try w.writeAll("\"");
      return;
    }
    if (T == bool) {
      if (slice.len == 0) {
        try w.writeAll("&0");
      } else {
        if (slice.len == 1) try w.writeAll(",");
        for (slice) |b| try w.writeByte(if (b) '1' else '0');
        try w.writeAll("b");
      }
      return;
    }
    if (slice.len == 0) {
      try w.writeAll(switch (T) {
        i32 => "!0",
        f32 => "!0.0",
        else => "&0",
      });
    } else if (slice.len == 1) {
      try w.writeAll(",");
      try self.formatAtom(T, slice[0], w);
    } else {
      for (slice, 0..) |e, i| {
        if (i > 0 and T != u32) try w.writeAll(" ");
        try self.formatAtom(T, e, w);
      }
    }
  }

  // Naturals print with a `u` suffix so they round-trip and stay visibly
  // distinct from ints (precision is not transparent). Null is `0Nu`.
  fn formatNat(a: u32, w: anytype) anyerror!void {
    if (a == std.math.maxInt(u32)) try w.writeAll("0Nu")
    else try w.print("{d}u", .{a});
  }

  // Tier-2 float (f64/f16) with a precision suffix so it round-trips and stays
  // visibly distinct from the default f32. Null/inf mirror `0n`/`0w`.
  fn formatFloatSuffix(comptime T: type, a: T, comptime suffix: []const u8, w: anytype) anyerror!void {
    if (std.math.isNan(a)) { try w.writeAll("0n"); try w.writeAll(suffix); return; }
    if (std.math.isInf(a)) { try w.writeAll(if (a > 0) "0w" else "-0w"); try w.writeAll(suffix); return; }
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{a});
    try w.writeAll(s);
    if (std.mem.indexOfScalar(u8, s, '.') == null and std.mem.indexOfScalar(u8, s, 'e') == null) try w.writeAll(".0");
    try w.writeAll(suffix);
  }

  fn formatDictKey(self: *Self, k: V, w: anytype) anyerror!void {
    defer k.deinit(self.alloc);
    if (k.tag() == .s) {
      if (k.s < self.vm.symbolCount()) try w.writeAll(self.vm.getSymbol(k.s))
      else try w.print("{d}", .{k.s});
    } else try self.formatValue(k, w);
  }

  fn formatDict(self: *Self, d: Dict, w: anytype) anyerror!void {
    const keys = d.av();
    const vals = d.bv();
    const n = keys.len();
    // A keyed table (utable) is an `m` dict whose keys AND values are tables (M):
    // print it in the k9 `[[keycols]valcols]` literal form.
    if (keys.tag() == .M and vals.tag() == .M) {
      try w.writeAll("[[");
      try self.formatTableCols(keys.M, w);
      try w.writeAll("]");
      try self.formatTableCols(vals.M, w);
      try w.writeAll("]");
      return;
    }
    // Empty dict prints as [] (its literal form); otherwise only symbol keys
    // can use the bracket syntax.
    const can_use_syntax = (n == 0) or (keys.tag() == .S) or (keys.tag() == .s) or (keys.tag() == .L and self.allSymbols(keys.L.slice()));
    if (!can_use_syntax) {
      try self.formatValue(keys, w);
      try w.writeAll("!");
      try self.formatValue(vals, w);
      return;
    }
    try w.writeAll("[");
    for (0..n) |i| {
      if (i > 0) try w.writeAll(";");
      try self.formatDictKey(keys.at(i), w);
      try w.writeAll(":");
      const v = if (n == 1) vals.ref() else vals.at(i);
      defer v.deinit(self.alloc);
      try self.formatValue(v, w);
    }
    try w.writeAll("]");
  }

  // The `col:vals;col:vals` body shared by the table `[[]…]` and utable `[[…]…]` forms.
  fn formatTableCols(self: *Self, d: Dict, w: anytype) anyerror!void {
    const keys = d.av();
    const vals = d.bv();
    const n = keys.len();
    for (0..n) |i| {
      if (i > 0) try w.writeAll(";");
      try self.formatDictKey(keys.at(i), w);
      try w.writeAll(":");
      const v = vals.at(i);
      defer v.deinit(self.alloc);
      try self.formatValue(v, w);
    }
  }

  fn formatTable(self: *Self, d: Dict, w: anytype) anyerror!void {
    try w.writeAll("[[]");
    try self.formatTableCols(d, w);
    try w.writeAll("]");
  }

  // Top-level entry. In `pretty` mode dicts/tables/keyed-tables get the
  // multi-line REPL rendering; everything else (and all nested values) falls
  // through to the single-line `formatValue`.
  fn formatTop(self: *Self, v: V, w: anytype) anyerror!void {
    if (self.pretty) switch (v) {
      .m => |d| {
        const keys = d.av();
        const vals = d.bv();
        if (keys.tag() == .M and vals.tag() == .M)
          return self.formatKeyedTablePretty(keys.M, vals.M, w);
        if (keys.len() != 0) return self.formatDictPretty(d, w);
      },
      .M => |d| {
        if (d.av().len() != 0) return self.formatTablePretty(d, w);
      },
      else => {},
    };
    try self.formatValue(v, w);
  }

  // Render a single cell value to bytes for the pretty grid: char data as raw
  // text, symbols without the leading backtick, everything else as its normal
  // single-line form. Errors (e.g. a cell larger than the scratch buffer) are
  // swallowed — the truncated content is used.
  fn renderCell(self: *Self, v: V, w: *std.Io.Writer) void {
    switch (v) {
      .C => |n| w.writeAll(n.slice()) catch {},
      .c => |a| w.writeByte(@intCast(a)) catch {},
      .S => |n| for (n.slice(), 0..) |sym, i| {
        if (i > 0) w.writeAll(" ") catch {};
        self.writeSymName(sym, w);
      },
      .s => |a| self.writeSymName(a, w),
      else => {
        const old = self.force_single_line;
        self.force_single_line = true;
        defer self.force_single_line = old;
        self.formatValue(v, w) catch {};
      },
    }
  }

  fn writeSymName(self: *Self, a: u32, w: *std.Io.Writer) void {
    if (a < self.vm.symbolCount()) w.writeAll(self.vm.getSymbol(a)) catch {}
    else w.print("{d}", .{a}) catch {};
  }

  fn renderCellAlloc(self: *Self, v: V) ![]u8 {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.Writer.fixed(&buf);
    self.renderCell(v, &fw);
    return self.alloc.dupe(u8, fw.buffered());
  }

  // Print `cells` separated by a single space, each padded to `colw`.
  // Right-aligned columns (numbers, k9-style) pad on the left; left-aligned
  // columns pad on the right, and the final column is right-padded only when
  // `pad_last` is set (so a trailing `|` aligns).
  fn printPrettyRow(_: *Self, strs: []const []const u8, colw: []const usize, right: []const bool, pad_last: bool, w: anytype) anyerror!void {
    for (strs, 0..) |s, i| {
      if (i > 0) try w.writeAll(" ");
      if (right[i]) {
        for (s.len..colw[i]) |_| try w.writeAll(" ");
        try w.writeAll(s);
      } else {
        try w.writeAll(s);
        if (pad_last or i + 1 < strs.len)
          for (s.len..colw[i]) |_| try w.writeAll(" ");
      }
    }
  }

  // Numeric columns are right-aligned in the grid (k9 convention); everything
  // else (symbols, chars, mixed lists) stays left-aligned.
  fn columnIsRight(v: V) bool {
    return switch (v) {
      .I, .F, .B => true,
      else => false,
    };
  }

  // The `- -` underline: a run of dashes per column, full column width.
  fn printPrettySep(_: *Self, colw: []const usize, w: anytype) anyerror!void {
    for (colw, 0..) |cw, i| {
      if (i > 0) try w.writeAll(" ");
      for (0..cw) |_| try w.writeAll("-");
    }
  }

  fn formatDictPretty(self: *Self, d: Dict, w: anytype) anyerror!void {
    const keys = d.av();
    const vals = d.bv();
    const n = keys.len();
    const keystrs = try self.alloc.alloc([]u8, n);
    defer { for (keystrs) |ks| self.alloc.free(ks); self.alloc.free(keystrs); }
    var keyw: usize = 0;
    for (0..n) |i| {
      const k = keys.at(i);
      defer k.deinit(self.alloc);
      keystrs[i] = try self.renderCellAlloc(k);
      if (keystrs[i].len > keyw) keyw = keystrs[i].len;
    }
    for (0..n) |i| {
      if (i > 0) try w.writeAll("\n");
      try w.writeAll(keystrs[i]);
      for (keystrs[i].len..keyw) |_| try w.writeAll(" ");
      try w.writeAll("|");
      const v = if (n == 1) vals.ref() else vals.at(i);
      defer v.deinit(self.alloc);
      self.renderCell(v, w);
    }
  }

  // Collect a table's column headers, column arrays, per-cell strings and column
  // widths. Caller frees via `freeGrid`. `cells` is column-major: `cells[c*nrow+r]`.
  const Grid = struct {
    headers: [][]u8,
    cols: []V,
    cells: [][]u8,
    colw: []usize,
    right: []bool,
    nrow: usize,
  };

  fn buildGrid(self: *Self, d: Dict) anyerror!Grid {
    const names = d.av();
    const vals = d.bv();
    const ncol = names.len();
    const headers = try self.alloc.alloc([]u8, ncol);
    const cols = try self.alloc.alloc(V, ncol);
    const colw = try self.alloc.alloc(usize, ncol);
    const right = try self.alloc.alloc(bool, ncol);
    for (0..ncol) |c| {
      const nm = names.at(c);
      defer nm.deinit(self.alloc);
      headers[c] = try self.renderCellAlloc(nm);
      cols[c] = vals.at(c);
      colw[c] = headers[c].len;
      right[c] = columnIsRight(cols[c]);
    }
    const nrow = if (ncol > 0) cols[0].len() else 0;
    const cells = try self.alloc.alloc([]u8, ncol * nrow);
    for (0..ncol) |c| for (0..nrow) |r| {
      const elem = cols[c].at(r);
      defer elem.deinit(self.alloc);
      const s = try self.renderCellAlloc(elem);
      cells[c * nrow + r] = s;
      if (s.len > colw[c]) colw[c] = s.len;
    };
    return .{ .headers = headers, .cols = cols, .cells = cells, .colw = colw, .right = right, .nrow = nrow };
  }

  fn freeGrid(self: *Self, g: Grid) void {
    for (g.headers) |h| self.alloc.free(h);
    for (g.cells) |c| self.alloc.free(c);
    for (g.cols) |c| c.deinit(self.alloc);
    self.alloc.free(g.headers);
    self.alloc.free(g.cells);
    self.alloc.free(g.cols);
    self.alloc.free(g.colw);
    self.alloc.free(g.right);
  }

  fn formatTablePretty(self: *Self, d: Dict, w: anytype) anyerror!void {
    const g = try self.buildGrid(d);
    defer self.freeGrid(g);
    try self.printPrettyRow(g.headers, g.colw, g.right, false, w);
    try w.writeAll("\n");
    try self.printPrettySep(g.colw, w);
    const ncol = g.headers.len;
    const row = try self.alloc.alloc([]const u8, ncol);
    defer self.alloc.free(row);
    for (0..g.nrow) |r| {
      try w.writeAll("\n");
      for (0..ncol) |c| row[c] = g.cells[c * g.nrow + r];
      try self.printPrettyRow(row, g.colw, g.right, false, w);
    }
  }

  // A keyed table is a dict whose keys and values are both tables: the key
  // columns and value columns share rows, joined by `|`.
  fn formatKeyedTablePretty(self: *Self, kt: Dict, vt: Dict, w: anytype) anyerror!void {
    const kg = try self.buildGrid(kt);
    defer self.freeGrid(kg);
    const vg = try self.buildGrid(vt);
    defer self.freeGrid(vg);
    const nrow = @max(kg.nrow, vg.nrow);
    // header
    try self.printPrettyRow(kg.headers, kg.colw, kg.right, true, w);
    try w.writeAll("|");
    try self.printPrettyRow(vg.headers, vg.colw, vg.right, false, w);
    // separator
    try w.writeAll("\n");
    try self.printPrettySep(kg.colw, w);
    try w.writeAll("|");
    try self.printPrettySep(vg.colw, w);
    // rows
    const krow = try self.alloc.alloc([]const u8, kg.headers.len);
    defer self.alloc.free(krow);
    const vrow = try self.alloc.alloc([]const u8, vg.headers.len);
    defer self.alloc.free(vrow);
    for (0..nrow) |r| {
      try w.writeAll("\n");
      for (0..kg.headers.len) |c| krow[c] = kg.cells[c * kg.nrow + r];
      for (0..vg.headers.len) |c| vrow[c] = vg.cells[c * vg.nrow + r];
      try self.printPrettyRow(krow, kg.colw, kg.right, true, w);
      try w.writeAll("|");
      try self.printPrettyRow(vrow, vg.colw, vg.right, false, w);
    }
  }

  fn allSymbols(self: *Self, slice: []const V) bool {
    _ = self;
    if (slice.len == 0) return false;
    for (slice) |item| {
      if (item.tag() != .s) return false;
    }
    return true;
  }

  fn formatAtom(self: *Self, comptime T: type, val: T, w: anytype) !void {
    switch (T) {
      bool => try self.formatValue(V{ .b = val }, w),
      i32 => try self.formatValue(V{ .i = val }, w),
      f32 => try self.formatValue(V{ .f = val }, w),
      u32 => try self.formatValue(V{ .s = val }, w),
      u8 => try self.formatValue(V{ .c = @intCast(val) }, w),
      else => unreachable,
    }
  }

  fn isComplex(_: *Self, v: V) bool {
    return switch (v) {
      .L => |n| {
        for (n.slice()) |item| {
          if (switch (item) {
            .I, .F, .S, .C, .B, .L, .m => true,
            else => false,
          }) return true;
        }
        return false;
      },
      .m, .M, => true,
      else => false,
    };
  }

  fn writeIndent(self: *Self, w: anytype) anyerror!void {
    if (self.mode == .Text) return;
    for (0..self.indent) |_| try w.writeAll(" ");
  }
};
