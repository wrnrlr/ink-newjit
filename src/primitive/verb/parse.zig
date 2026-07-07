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

fn seqToV(vm: *VM, head: []const u8, nodes: []const *Node) !V {
  const alloc = vm.alloc;
  var list = try std.ArrayList(V).initCapacity(alloc, nodes.len + 1);
  errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
  try list.append(alloc, try sym(vm, head));
  for (nodes, 0..) |item, i| {
    if (i > 0) try list.append(alloc, try sym(vm, "div"));
    try list.append(alloc, try nodeToV(vm, item));
  }
  return transfer(alloc, &list);
}

fn nodeToV(vm: *VM, node: *Node) anyerror!V {
  const alloc = vm.alloc;
  switch (node.*) {
    .terse => |t| {
      var list = try std.ArrayList(V).initCapacity(alloc, t.stmts.len + 1);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "terse"));
      for (t.stmts, 0..) |stmt, i| {
        if (i > 0) try list.append(alloc, try sym(vm, "sep"));
        if (stmt.node.* != .blank)
          try list.append(alloc, try nodeToV(vm, stmt.node));
      }
      return transfer(alloc, &list);
    },
    .literal => |lit| {
      const type_name: []const u8 = switch (lit) {
        .b => "bool",  .B => "bools",
        .i => "int",   .I => "ints",
        .f => "float", .F => "floats",
        .c, .C => "string",
        .s => "symbol", .S => "symbols",
        .@"var" => "var",
      };
      var list = try std.ArrayList(V).initCapacity(alloc, 3);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "literal"));
      try list.append(alloc, try sym(vm, type_name));
      switch (lit) {
        .@"var" => |v| try list.append(alloc, try sym(vm, v)),
        .f      => |f| try list.append(alloc, V{ .f = f }),
        .i      => |i| try list.append(alloc, V{ .i = i }),
        .b      => |b| try list.append(alloc, V{ .b = b }),
        .s      => |s| try list.append(alloc, try sym(vm, s)),
        .c      => |c| try list.append(alloc, try sym(vm, c)),
        .F      => |f| try list.append(alloc, try V.Floats(alloc, f)),
        .I      => |i| try list.append(alloc, try V.Ints(alloc, i)),
        .B      => |b| try list.append(alloc, .{ .B = try N(bool).n1(alloc, b) }),
        .S      => |s| {
          const arr = try N(u32).init(alloc, s.len);
          for (s, arr.slice()) |str, *dst| dst.* = try vm.intern(str);
          try list.append(alloc, V{ .S = arr });
        },
        .C      => |c| try list.append(alloc, try V.Chars(alloc, c)),
      }
      return transfer(alloc, &list);
    },
    .op         => |op_str| return sym(vm, op_str),
    .io    => |io_str| return sym(vm, io_str),
    .adverb_val => return sym(vm, "adverb_val"),
    .monad      => return sym(vm, "monad"),
    .blank      => return sym(vm, "blank"),
    .command    => return sym(vm, "command"),
    .transit => |t| {
      var list = try std.ArrayList(V).initCapacity(alloc, 4);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "transit"));
      try list.append(alloc, try nodeToV(vm, t.a));
      try list.append(alloc, try nodeToV(vm, t.v));
      try list.append(alloc, try nodeToV(vm, t.b));
      return transfer(alloc, &list);
    },
    .apposit => |a| {
      var list = try std.ArrayList(V).initCapacity(alloc, 3);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "apposit"));
      try list.append(alloc, try nodeToV(vm, a.f));
      try list.append(alloc, try nodeToV(vm, a.a));
      return transfer(alloc, &list);
    },
    .bind => |b| {
      var list = try std.ArrayList(V).initCapacity(alloc, 4);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "bind"));
      try list.append(alloc, try nodeToV(vm, b.v));
      if (b.f) |_| try list.append(alloc, try sym(vm, "op"));
      if (b.a) |a| try list.append(alloc, try nodeToV(vm, a));
      return transfer(alloc, &list);
    },
    .right => |r| {
      var list = try std.ArrayList(V).initCapacity(alloc, 2);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "right"));
      try list.append(alloc, try nodeToV(vm, r.clause));
      return transfer(alloc, &list);
    },
    .term => |t| {
      var list = try std.ArrayList(V).initCapacity(alloc, 3);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "term"));
      try list.append(alloc, try nodeToV(vm, t.f));
      try list.append(alloc, try sym(vm, t.a));
      return transfer(alloc, &list);
    },
    .group => |g| {
      var list = try std.ArrayList(V).initCapacity(alloc, 2);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "group"));
      try list.append(alloc, try nodeToV(vm, g.stmt));
      return transfer(alloc, &list);
    },
    .list => |l| {
      if (l.seq) |seq| {
        var list = try std.ArrayList(V).initCapacity(alloc, 2);
        errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
        try list.append(alloc, try sym(vm, "list"));
        try list.append(alloc, try seqToV(vm, "seq", seq));
        return transfer(alloc, &list);
      } else {
        return sym(vm, "list");
      }
    },
    .lambda => |l| {
      var list = try std.ArrayList(V).initCapacity(alloc, 3);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "lambda"));
      if (l.a) |args| {
        var inner = try std.ArrayList(V).initCapacity(alloc, args.len + 1);
        errdefer { for (inner.items) |v| v.deinit(alloc); inner.deinit(alloc); }
        try inner.append(alloc, try sym(vm, "args"));
        for (args, 0..) |arg, i| {
          if (i > 0) try inner.append(alloc, try sym(vm, "div"));
          if (arg.is_some) try inner.append(alloc, try sym(vm, arg.value));
        }
        try list.append(alloc, try transfer(alloc, &inner));
      }
      if (l.b) |seq| try list.append(alloc, try seqToV(vm, "seq", seq));
      return transfer(alloc, &list);
    },
    .apply => |a| {
      var list = try std.ArrayList(V).initCapacity(alloc, 3);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "apply"));
      try list.append(alloc, try nodeToV(vm, a.f));
      if (a.a) |seq| try list.append(alloc, try seqToV(vm, "seq", seq));
      return transfer(alloc, &list);
    },
    .dict => |d| {
      var list = try std.ArrayList(V).initCapacity(alloc, (if (d.items) |it| it.len else 0) + 1);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "dict"));
      if (d.items) |items| {
        for (items) |item| {
          var inner = try std.ArrayList(V).initCapacity(alloc, 3);
          errdefer { for (inner.items) |v| v.deinit(alloc); inner.deinit(alloc); }
          try inner.append(alloc, try sym(vm, "item"));
          try inner.append(alloc, try sym(vm, keyType(item.k)));
          try inner.append(alloc, try nodeToV(vm, item.v));
          try list.append(alloc, try transfer(alloc, &inner));
        }
      }
      return transfer(alloc, &list);
    },
    .table => |d| {
      var list = try std.ArrayList(V).initCapacity(alloc, (if (d.items) |it| it.len else 0) + 1);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "table"));
      if (d.items) |items| {
        for (items) |item| {
          var inner = try std.ArrayList(V).initCapacity(alloc, 3);
          errdefer { for (inner.items) |v| v.deinit(alloc); inner.deinit(alloc); }
          try inner.append(alloc, try sym(vm, "item"));
          try inner.append(alloc, try sym(vm, keyType(item.k)));
          try inner.append(alloc, try nodeToV(vm, item.v));
          try list.append(alloc, try transfer(alloc, &inner));
        }
      }
      return transfer(alloc, &list);
    },
    .cond => |c| {
      var list = try std.ArrayList(V).initCapacity(alloc, c.stmts.len + 1);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "cond"));
      for (c.stmts) |s| try list.append(alloc, try nodeToV(vm, s));
      return transfer(alloc, &list);
    },
    .intrans => |it| {
      var list = try std.ArrayList(V).initCapacity(alloc, 3);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "intrans"));
      try list.append(alloc, try nodeToV(vm, it.a));
      try list.append(alloc, try nodeToV(vm, it.v));
      return transfer(alloc, &list);
    },
    else => return sym(vm, "?"),
  }
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
    .op => "op", .io => "io", .monad => "monad", .adverb_val => "adverb_val",
    .blank => "blank", .command => "command",
    .literal => |lit| switch (lit) {
      .b => "bool", .B => "bools", .i => "int", .I => "ints",
      .f => "float", .F => "floats", .c, .C => "string",
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
    .cond => |co| for (co.stmts) |st| try collect(vm, p, cp, cols, st, row, "stmt", cd, &lo, &hi),
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
pub fn tableFromSource(vm: *VM, src: []const u8) V {
  var p = parser_mod.Parser.init(vm.alloc);
  defer p.deinit();
  const node = p.parse(src) catch return V{ .err = .domain };

  // Byte→codepoint prefix: cp[i] = codepoint index of byte offset i.
  const cp = vm.alloc.alloc(u32, src.len + 1) catch return V{ .err = .memory };
  defer vm.alloc.free(cp);
  var c: u32 = 0;
  for (src, 0..) |b, i| { cp[i] = c; if (b & 0xC0 != 0x80) c += 1; }
  cp[src.len] = c;

  var cols = Cols{};
  _ = emit(vm, &p, cp, &cols, node, -1, vm.intern("") catch 0, 0) catch return V{ .err = .memory };

  // Comments are dropped from the tree; append them as `comment rows under the
  // root terse (row 0), carrying their source range and raw text, for syntax
  // highlighting and doc tooling. Appended after the tree so parent(0) < row.
  {
    const cmt = vm.intern("comment") catch 0;
    for (p.comments.items) |span| {
      cols.parent.append(vm.alloc, 0) catch return V{ .err = .memory };
      cols.kind.append(vm.alloc, cmt) catch return V{ .err = .memory };
      cols.field.append(vm.alloc, cmt) catch return V{ .err = .memory };
      cols.start.append(vm.alloc, @intCast(cp[span[0]])) catch return V{ .err = .memory };
      cols.len.append(vm.alloc, @intCast(cp[span[1]] - cp[span[0]])) catch return V{ .err = .memory };
      cols.value.append(vm.alloc, V.Chars(vm.alloc, src[span[0]..span[1]]) catch return V{ .err = .memory }) catch return V{ .err = .memory };
      cols.depth.append(vm.alloc, 1) catch return V{ .err = .memory };
    }
  }

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

fn keyType(k: []const u8) []const u8 {
  if (k.len == 0) return "var";
  const c = k[0];
  if (std.ascii.isDigit(c) or c == '-') return "int";
  if (c == '`') return "symbol";
  if (c == '"') return "string";
  return "var";
}
