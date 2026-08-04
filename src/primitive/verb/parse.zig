const std = @import("std");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const ast = @import("../../parser/ast.zig");
const Node = ast.Node;
const parser_mod = @import("../../parser/parser.zig");

pub const Parse = struct {
  pub const op = .parse;
  _C: VM.Monad = parseChars,
};

fn parseChars(vm: *VM, x: V) V {
  return tableFromSource(vm, x.C.slice());
}

fn sym(vm: *VM, name: []const u8) !V {
  return V{ .s = try vm.intern(name) };
}

// Move items from ArrayList into a new V.L without bumping ref counts.
fn transfer(alloc: std.mem.Allocator, list: *std.ArrayList(V)) !V {
  const n = try N(V).init(alloc, list.items.len);
  @memcpy(n.slice(), list.items);
  list.deinit(alloc);
  return V{ .L = n };
}

// ── CST table serializer ─────────────────────────────────────────────────────
// Emits the parse tree as an apter-tree "table": a dict of equal-length column
// vectors, one row per node, in pre-order (parent row precedes its children, so
// parent < row). Ranges are codepoint offsets. Columns:
//   parent I  parent row index, -1 for root
//   kind   S  node type (literals flattened to their leaf type: var/int/…)
//   field  S  role in parent (`v`a`f`b`arg`elem`stmt`param or dict key); ` if none
//   start  I  codepoint offset of first char
//   len    I  codepoint length
//   value  L  literal payload / glyph symbol; ` for pure structure
//   depth  I  nesting depth
const Cols = struct {
  parent: std.ArrayList(i32) = .empty,
  kind:   std.ArrayList(u32) = .empty,
  field:  std.ArrayList(u32) = .empty,
  start:  std.ArrayList(i32) = .empty,
  len:    std.ArrayList(i32) = .empty,
  value:  std.ArrayList(V)   = .empty,
  depth:  std.ArrayList(i32) = .empty,
};

fn kindName(node: *Node) []const u8 {
  return switch (node.*) {
    .terse => "terse", .transit => "transit", .intrans => "intrans",
    .apposit => "apposit", .bind => "bind", .right => "right", .term => "term",
    .group => "group", .list => "list", .lambda => "lambda", .apply => "apply",
    .dict => "dict", .table => "table", .utable => "utable", .cond => "cond",
    .progn => "progn", .ret => "ret",
    .op => "op", .io => "io", .monad => "monad", .adverb_val => "adverb_val",
    .blank => "blank", .command => "command",
    .literal => |lit| switch (lit) {
      .b => "bool", .B => "bools", .i => "int", .I => "ints",
      .f => "float", .F => "floats", .c, .C => "string",
      .n => "nat", .N => "nats",
      .d => "dbl", .D => "dbls", .h => "hlf", .H => "hlfs",
      .s => "symbol", .S => "symbols", .@"var" => "var",
    },
    else => "?",
  };
}

// The `value` cell: literal payload for literals, glyph symbol for verbs/adverbs,
// else the empty symbol.
fn nodeValue(vm: *VM, node: *Node) !V {
  return switch (node.*) {
    .op => |s| try sym(vm, s),
    .io => |s| try sym(vm, s),
    .adverb_val => |s| try sym(vm, s),
    .term => |t| try sym(vm, t.a),
    .monad => |m| try sym(vm, m.f),
    .command => |c| try sym(vm, c.verb),
    .literal => |lit| switch (lit) {
      .@"var" => |v| try sym(vm, v),
      .s => |s| try sym(vm, s),
      .c => |c| try sym(vm, c),
      .f => |f| V{ .f = f },
      .i => |i| V{ .i = i },
      .b => |b| V{ .b = b },
      .n => |n| V{ .n = n },
      .N => |n| .{ .N = try N(u32).n1(vm.alloc, n) },
      .d => |x| V{ .d = x },
      .h => |x| V{ .h = x },
      .D => |x| .{ .D = try N(f64).n1(vm.alloc, x) },
      .H => |x| .{ .H = try N(f16).n1(vm.alloc, x) },
      .F => |f| try V.Floats(vm.alloc, f),
      .I => |i| try V.Ints(vm.alloc, i),
      .B => |b| .{ .B = try N(bool).n1(vm.alloc, b) },
      .C => |c| try V.Chars(vm.alloc, c),
      .S => |s| blk: {
        const arr = try N(u32).init(vm.alloc, s.len);
        for (s, arr.slice()) |str, *dst| dst.* = try vm.intern(str);
        break :blk V{ .S = arr };
      },
    },
    else => try sym(vm, ""),
  };
}

const Span = struct { s: u32, e: u32 };

// Append one node (and, recursively, its children) to the columns. Returns the
// node's byte span so interior nodes can compose their span from children when
// the parser did not record one directly.
fn emit(vm: *VM, p: *parser_mod.Parser, cp: []const u32, cols: *Cols, node: *Node, parent: i32, field: u32, depth: i32) anyerror!Span {
  const a = vm.alloc;
  const row: i32 = @intCast(cols.parent.items.len);
  try cols.parent.append(a, parent);
  try cols.kind.append(a, try vm.intern(kindName(node)));
  try cols.field.append(a, field);
  try cols.start.append(a, 0);
  try cols.len.append(a, 0);
  try cols.value.append(a, try nodeValue(vm, node));
  try cols.depth.append(a, depth);

  // Recurse into children, tracking their combined byte extent.
  var lo: u32 = std.math.maxInt(u32);
  var hi: u32 = 0;
  const cd = depth + 1;
  const collect = struct {
    fn go(v: *VM, pp: *parser_mod.Parser, c: []const u32, cs: *Cols, n: *Node, par: i32, fld: []const u8, d: i32, l: *u32, h: *u32) !void {
      const fs = try v.intern(fld);
      const span = try emit(v, pp, c, cs, n, par, fs, d);
      if (span.s < l.*) l.* = span.s;
      if (span.e > h.*) h.* = span.e;
    }
  }.go;

  switch (node.*) {
    .terse => |t| for (t.stmts) |st| { if (st.node.* != .blank) try collect(vm, p, cp, cols, st.node, row, "stmt", cd, &lo, &hi); },
    .transit => |t| {
      try collect(vm, p, cp, cols, t.a, row, "a", cd, &lo, &hi);
      try collect(vm, p, cp, cols, t.v, row, "v", cd, &lo, &hi);
      try collect(vm, p, cp, cols, t.b, row, "b", cd, &lo, &hi);
    },
    .intrans => |t| {
      try collect(vm, p, cp, cols, t.a, row, "a", cd, &lo, &hi);
      try collect(vm, p, cp, cols, t.v, row, "v", cd, &lo, &hi);
      if (t.z) |z| try collect(vm, p, cp, cols, z, row, "z", cd, &lo, &hi);
    },
    .apposit => |ap| {
      try collect(vm, p, cp, cols, ap.f, row, "f", cd, &lo, &hi);
      try collect(vm, p, cp, cols, ap.a, row, "a", cd, &lo, &hi);
    },
    .bind => |b| {
      try collect(vm, p, cp, cols, b.v, row, "v", cd, &lo, &hi);
      if (b.a) |av| try collect(vm, p, cp, cols, av, row, "a", cd, &lo, &hi);
    },
    .right => |r| try collect(vm, p, cp, cols, r.clause, row, "clause", cd, &lo, &hi),
    .term => |t| try collect(vm, p, cp, cols, t.f, row, "f", cd, &lo, &hi),
    .group => |g| try collect(vm, p, cp, cols, g.stmt, row, "stmt", cd, &lo, &hi),
    .list => |l| if (l.seq) |seq| for (seq) |e| try collect(vm, p, cp, cols, e, row, "elem", cd, &lo, &hi),
    .apply => |ap| {
      try collect(vm, p, cp, cols, ap.f, row, "f", cd, &lo, &hi);
      if (ap.a) |seq| for (seq) |e| try collect(vm, p, cp, cols, e, row, "arg", cd, &lo, &hi);
    },
    .lambda => |l| {
      if (l.a) |args| for (args) |arg| if (arg.is_some) {
        try cols.parent.append(a, row);
        try cols.kind.append(a, try vm.intern("param"));
        try cols.field.append(a, try vm.intern("param"));
        try cols.start.append(a, @intCast(cp[arg.start]));
        try cols.len.append(a, @intCast(cp[arg.end] - cp[arg.start]));
        try cols.value.append(a, try sym(vm, arg.value));
        try cols.depth.append(a, cd);
      };
      if (l.b) |seq| for (seq) |e| { if (e.* != .blank) try collect(vm, p, cp, cols, e, row, "stmt", cd, &lo, &hi); };
    },
    .dict, .table => |d| if (d.items) |items| for (items) |it| try collect(vm, p, cp, cols, it.v, row, it.k, cd, &lo, &hi),
    .utable => |u| {
      if (u.keys) |ks| for (ks) |it| try collect(vm, p, cp, cols, it.v, row, it.k, cd, &lo, &hi);
      if (u.items) |is| for (is) |it| try collect(vm, p, cp, cols, it.v, row, it.k, cd, &lo, &hi);
    },
    .cond => |co| for (co.stmts) |st| try collect(vm, p, cp, cols, st, row, "stmt", cd, &lo, &hi),
    .progn => |pg| if (pg.seq) |seq| for (seq) |st| { if (st.* != .blank) try collect(vm, p, cp, cols, st, row, "stmt", cd, &lo, &hi); },
    .ret => |r| if (r.clause) |c| try collect(vm, p, cp, cols, c, row, "clause", cd, &lo, &hi),
    else => {},
  }

  // This node's byte span: prefer a parser-recorded one, else compose from
  // children, else empty.
  const span: Span = if (p.spans.get(node)) |rs| .{ .s = rs[0], .e = rs[1] }
    else if (lo <= hi) .{ .s = lo, .e = hi } else .{ .s = 0, .e = 0 };
  cols.start.items[@intCast(row)] = @intCast(cp[span.s]);
  cols.len.items[@intCast(row)] = @intCast(cp[span.e] - cp[span.s]);
  return span;
}

fn colI(a: std.mem.Allocator, list: *std.ArrayList(i32)) !V { const v = try V.Ints(a, list.items); list.deinit(a); return v; }
fn colS(a: std.mem.Allocator, list: *std.ArrayList(u32)) !V { const v = try V.Symbols(a, list.items); list.deinit(a); return v; }

// Parse `src` and return the CST as a dict of column vectors (flip with `+` for
// a row-wise table). This is the array-native counterpart to the nested `parse`.
fn deinitCols(alloc: std.mem.Allocator, cols: *Cols) void {
  for (cols.value.items) |v| v.deinit(alloc);
  cols.parent.deinit(alloc); cols.kind.deinit(alloc); cols.field.deinit(alloc);
  cols.start.deinit(alloc); cols.len.deinit(alloc); cols.value.deinit(alloc);
  cols.depth.deinit(alloc);
}

// Parse `src` into `cols`: one row per node (pre-order), then comment rows each
// attached to the innermost node whose span contains it. cp maps byte→codepoint.
fn fillCols(vm: *VM, p: *parser_mod.Parser, cp: []const u32, src: []const u8, cols: *Cols) !void {
  const node = try p.parse(src);
  _ = try emit(vm, p, cp, cols, node, -1, try vm.intern(""), 0);

  const cmt = try vm.intern("comment");
  const nreal = cols.parent.items.len; // node rows only; comments never nest
  for (p.comments.items) |span| {
    const cs: i32 = @intCast(cp[span[0]]);
    const ce: i32 = @intCast(cp[span[1]]);
    var host: usize = 0;                // default: root terse
    var best: i32 = std.math.maxInt(i32);
    for (0..nreal) |r| {
      const rs = cols.start.items[r];
      const rl = cols.len.items[r];
      // Smallest containing span wins; on a tie, the later (deeper, pre-order)
      // row wins, so a comment nests in the innermost block, not its terse/group.
      if (rs <= cs and ce <= rs + rl and rl <= best) { best = rl; host = r; }
    }
    try cols.parent.append(vm.alloc, @intCast(host));
    try cols.kind.append(vm.alloc, cmt);
    try cols.field.append(vm.alloc, cmt);
    try cols.start.append(vm.alloc, cs);
    try cols.len.append(vm.alloc, ce - cs);
    try cols.value.append(vm.alloc, try V.Chars(vm.alloc, src[span[0]..span[1]]));
    try cols.depth.append(vm.alloc, cols.depth.items[host] + 1);
  }
}

// Byte→codepoint prefix: result[i] = codepoint index of byte offset i.
fn cpPrefix(alloc: std.mem.Allocator, src: []const u8) ![]u32 {
  const cp = try alloc.alloc(u32, src.len + 1);
  var c: u32 = 0;
  for (src, 0..) |b, i| { cp[i] = c; if (b & 0xC0 != 0x80) c += 1; }
  cp[src.len] = c;
  return cp;
}

pub fn tableFromSource(vm: *VM, src: []const u8) V {
  var p = parser_mod.Parser.init(vm.alloc);
  defer p.deinit();
  const cp = cpPrefix(vm.alloc, src) catch return V{ .err = .memory };
  defer vm.alloc.free(cp);

  var cols = Cols{};
  fillCols(vm, &p, cp, src, &cols) catch return V{ .err = .domain };

  const parent = colI(vm.alloc, &cols.parent) catch return V{ .err = .memory };
  const kind   = colS(vm.alloc, &cols.kind) catch return V{ .err = .memory };
  const field  = colS(vm.alloc, &cols.field) catch return V{ .err = .memory };
  const start  = colI(vm.alloc, &cols.start) catch return V{ .err = .memory };
  const len    = colI(vm.alloc, &cols.len) catch return V{ .err = .memory };
  const value  = transfer(vm.alloc, &cols.value) catch return V{ .err = .memory };
  const depth  = colI(vm.alloc, &cols.depth) catch return V{ .err = .memory };

  const keys = V.Symbols(vm.alloc, &.{
    vm.intern("parent") catch 0, vm.intern("kind") catch 0, vm.intern("field") catch 0,
    vm.intern("start") catch 0, vm.intern("len") catch 0, vm.intern("value") catch 0,
    vm.intern("depth") catch 0,
  }) catch return V{ .err = .memory };
  const vals = N(V).init(vm.alloc, 7) catch return V{ .err = .memory };
  vals.slice()[0] = parent; vals.slice()[1] = kind; vals.slice()[2] = field;
  vals.slice()[3] = start; vals.slice()[4] = len; vals.slice()[5] = value; vals.slice()[6] = depth;
  const Dict = @import("../../noun/dict.zig").Dict;
  const d = Dict.init(vm.alloc, keys, V{ .L = vals }) catch return V{ .err = .memory };
  return V{ .m = d };
}

// ── S-expression tree view ───────────────────────────────────────────────────
// A tree-sitter-style textual rendering of the CST for humans / LLM agents:
//   (terse [0, 0] - [5, 0]
//     (comment [0, 0] - [0, 33])
//     (bind [3, 0] - [3, 10]
//       v: (var [3, 0] - [3, 1]) ...))
// Field labels (v:/a:/f:/…) precede each child except the positional `stmt`.
// Positions are [row, col] in codepoints; ranges are omitted unless requested.
const RowCol = struct { row: u32, col: u32 };

fn lineStarts(alloc: std.mem.Allocator, src: []const u8) ![]u32 {
  var ls: std.ArrayList(u32) = .empty;
  errdefer ls.deinit(alloc);
  try ls.append(alloc, 0);
  var c: u32 = 0;
  for (src) |b| { if (b & 0xC0 != 0x80) c += 1; if (b == '\n') try ls.append(alloc, c); }
  return ls.toOwnedSlice(alloc);
}

fn rowcol(line_start: []const u32, off: u32) RowCol {
  var lo: usize = 0;
  var hi: usize = line_start.len;
  while (lo < hi) { const mid = (lo + hi) / 2; if (line_start[mid] <= off) lo = mid + 1 else hi = mid; }
  const l = lo - 1;
  return .{ .row = @intCast(l), .col = off - line_start[l] };
}

fn cmpByStart(cols: *Cols, a: usize, b: usize) bool { return cols.start.items[a] < cols.start.items[b]; }

fn printNode(vm: *VM, cols: *Cols, w: *std.Io.Writer, row: usize, indent: usize, line_start: []const u32, ranges: bool) !void {
  try w.writeAll("(");
  try w.writeAll(vm.getSymbol(cols.kind.items[row]));
  if (ranges) {
    const s: u32 = @intCast(cols.start.items[row]);
    const e: u32 = @intCast(cols.start.items[row] + cols.len.items[row]);
    const sp = rowcol(line_start, s);
    const ep = rowcol(line_start, e);
    try w.print(" [{d}, {d}] - [{d}, {d}]", .{ sp.row, sp.col, ep.row, ep.col });
  }
  // Children = rows whose parent is this row, in source order.
  var kids: std.ArrayList(usize) = .empty;
  defer kids.deinit(vm.alloc);
  const me: i32 = @intCast(row);
  for (cols.parent.items, 0..) |par, r| { if (par == me and r != row) try kids.append(vm.alloc, r); }
  std.sort.insertion(usize, kids.items, cols, cmpByStart);
  for (kids.items) |ch| {
    try w.writeAll("\n");
    for (0..indent + 2) |_| try w.writeAll(" ");
    const f = vm.getSymbol(cols.field.items[ch]);
    if (f.len > 0 and !std.mem.eql(u8, f, "stmt")) { try w.writeAll(f); try w.writeAll(": "); }
    try printNode(vm, cols, w, ch, indent + 2, line_start, ranges);
  }
  try w.writeAll(")");
}

// Parse `src` and render the CST as an S-expression to `w`. `ranges` adds
// [row, col] source spans to every node.
pub fn sexprFromSource(vm: *VM, src: []const u8, w: *std.Io.Writer, ranges: bool) !void {
  var p = parser_mod.Parser.init(vm.alloc);
  defer p.deinit();
  const cp = try cpPrefix(vm.alloc, src);
  defer vm.alloc.free(cp);
  var cols = Cols{};
  defer deinitCols(vm.alloc, &cols);
  try fillCols(vm, &p, cp, src, &cols);
  const ls = try lineStarts(vm.alloc, src);
  defer vm.alloc.free(ls);
  if (cols.parent.items.len == 0) return;
  try printNode(vm, &cols, w, 0, 0, ls, ranges);
  try w.writeAll("\n");
}
