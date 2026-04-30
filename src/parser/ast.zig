const std = @import("std");
const Alloc = std.mem.Allocator;
const eql = std.mem.eql;
const trim = std.mem.trim;
const parseInt = std.fmt.parseInt;
const parseFloat = std.fmt.parseFloat;
const EnumFieldMap = @import("../util.zig").EnumFieldMap;

pub const Error = error{ OutOfMemory, UnsupportedNodeType, NoLanguage, ParserCreationFailed, SetLanguageFailed, ParseFailed, Overflow, InvalidCharacter };

const LiteralType = enum {
  terse, verb, clause, adjunct, stmt_clause, stmt_adjunct, right, bind,
  transit, affix, apposit, phrase, @"defer", pending,
  intrans, prefix, compose, noun, phrase_verb, apply,
  group, list, lambda, args, dict, table, utable, literal, term,
  verb_op, verb_io, div, sep, seq, op, cond, amend, dmend,
  bool, bools, command, comment,
  monad, adverb_val, adverb,
};

const NodeTypeMap = EnumFieldMap(LiteralType);

const TSLanguage = opaque {};
const TSParser = opaque {};
const TSTree = opaque {};

const test_allocator = std.testing.allocator;

const TSNode = extern struct {
  context: [4]u32, id: ?*anyopaque, tree: ?*const TSTree,
  pub fn nodeType(n: TSNode) LiteralType {
    const name = std.mem.span(ts_node_type(n));
    // const string = try std.fmt.allocPrint(std.heap.c_allocator, "unknown node type {s}", .{"hi"});
    return NodeTypeMap.get(n.nodeTypeName()) orelse @panic(name);
  }
  pub fn nodeTypeName(n: TSNode) []const u8 { return std.mem.span(ts_node_type(n)); }
  pub fn childCount(n: TSNode) u32 { return ts_node_child_count(n); }
  pub fn child(n: TSNode, i: u32) TSNode { return ts_node_child(n, i); }
  pub fn namedChildCount(n: TSNode) u32 { return ts_node_named_child_count(n); }
  pub fn namedChild(n: TSNode, i: u32) TSNode { return ts_node_named_child(n, i); }
  pub fn isNamed(n: TSNode) bool { return ts_node_is_named(n); }
  pub fn startByte(n: TSNode) u32 { return ts_node_start_byte(n); }
  pub fn endByte(n: TSNode) u32 { return ts_node_end_byte(n); }
  pub fn slice(n: TSNode, src: []const u8) []const u8 { return src[ts_node_start_byte(n)..ts_node_end_byte(n)]; }
  pub fn length(n: TSNode) usize { return ts_node_end_byte(n)-ts_node_start_byte(n); }
};

pub const Var = []const u8;
pub const Op = []const u8;
pub const Io = []const u8;
pub const Adverb = []const u8;
pub const Symbol = []const u8;
pub const Symbols = []Symbol;
pub const Strings = []const u8;
pub const Text = []const u8;

pub const Literal = union(enum) {
  b: bool, i: i32, f: f32, c: []const u8, s: []const u8,
  B: []bool, I: []i32, F: []f32, C: []const u8, S: [][]const u8,
  @"var": []const u8
};

pub const Command = struct { verb: []const u8, args: []const u8 };

pub const Item = struct { k: Var, v: *Node };
pub const Items = []Item;
pub const Arg = struct { is_some: bool, value: Var };
pub const Args = []Arg;
pub const Seq = []*Node;
pub const Stmt = struct { node: *Node, source: []const u8 };
pub const Terse = struct { stmts: []Stmt };
pub const Right = struct { clause: *Node };
pub const Defer = struct { adjunct: *Node };
pub const Bind = struct {
  v: *Node, f: ?Op, a: ?*Node,
  fn free(self: *const Bind, alloc: Alloc) void {
    self.v.free(alloc);
    if (self.f) |f| f.free(alloc);
    if (self.a) |a| a.free(alloc);
  }
};
pub const Pending = struct { v: *Node, f: ?Op, a: *Node };
pub const Transit = struct { a: *Node, v: *Node, b: *Node };
pub const Intrans = struct { a: *Node, v: *Node, z: ?*Node };
pub const Apposit = struct { f: *Node, a: *Node };
pub const ComposeFz = struct { f: *Node, z: *Node };
pub const Compose = union(enum) { v: *Node, fz: ComposeFz };
pub const Affix = struct { a: *Node, v: Op, b: *Node };
pub const Prefix = struct { a: *Node, v: Op, z: ?*Node };
pub const Term = struct { f: *Node, a: Adverb };
pub const VerbMonad = struct { f: Op }; // e.g. *: +: -:
pub const Apply = struct { f: *Node, a: ?Seq };
pub const Group = struct { stmt: *Node };
pub const List = struct { seq: ?Seq };
pub const Lambda = struct { a: ?Args, b: ?Seq, start: u32, end: u32 };
pub const Cond = struct { stmts: []*Node };
pub const Dict = struct { items: ?Items };
pub const UTable = struct { keys: ?Items, items: ?Items };
pub const Select = struct { rows: ?Seq, by: ?Seq, from: Var, where: ?*Node };
pub const Update = struct { rows: Seq, from: Var, where: ?*Node };
pub const Delete = struct { from: Var, where: ?*Node };

const NodeType = enum {
  terse, verb, stmt_clause, stmt_adjunct, right, bind,
  transit, affix, apposit, phrase, @"defer", pending,
  intrans, prefix, compose, noun, phrase_verb, apply,
  group, list, lambda, dict, table, utable, literal, term,
  verb_op, verb_io, blank, cond, amend, dmend,
  command, monad, adverb_val,
};

pub const Node = union(NodeType) {
  terse: Terse,
  verb: *Node,
  stmt_clause: *Node,
  stmt_adjunct: *Node,
  right: Right,
  bind: Bind,
  transit: Transit,
  affix: Affix,
  apposit: Apposit,
  phrase: *Node,
  @"defer": Defer,
  pending: struct { v: *Node, f: ?Op, a: *Node },
  intrans: Intrans,
  prefix: Prefix,
  compose: Compose,
  noun: *Node,
  phrase_verb: *Node,
  apply: Apply,
  group: Group,
  list: List,
  lambda: Lambda,
  // args,
  dict: Dict,
  table: Dict,
  utable: UTable,
  literal: Literal,
  term: Term,
  verb_op: Op,
  verb_io: Io,
  blank: void,
  cond: Cond,
  amend: Seq,
  dmend: Seq,
  command: Command,
  monad: VerbMonad,   // e.g. *: used as monadic verb value
  adverb_val: Adverb,      // e.g. ' or \ used as adverb value inside expression

  fn nodeType(n:Node) NodeType { return n.*; }
  
  pub fn format(self: Node, w: anytype) !void {
    var writer = w;
    switch (self) {
      .blank => try writer.writeAll("_"),
      .terse => |terse| {
        for (terse.stmts, 0..) |stmt, i| {
          if (i > 0) try writer.writeAll(" ");
          try writer.writeAll(stmt.source);
        }
      },
      .transit => |transit| {
        try writer.writeAll("(");
        try transit.a.format(writer);
        try writer.writeAll(" ");
        try transit.v.format(writer);
        try writer.writeAll(" ");
        try transit.b.format(writer);
        try writer.writeAll(")");
      },
      .verb_op => |op| {
        try writer.writeAll(op);
      },
      .apposit => |apposit| {
        try writer.writeAll("(");
        try apposit.f.format(writer);
        try writer.writeAll(" ");
        try apposit.a.format(writer);
        try writer.writeAll(")");
      },
      .term => |term| {
        try writer.writeAll("(");
        try term.f.format(writer);
        try writer.writeAll(term.a);
        try writer.writeAll(")");
      },
      .bind => |bind| {
        try writer.writeAll("(bind ");
        try bind.v.format(writer);
        if (bind.f) |ff| {
          try writer.writeAll(" ");
          try writer.writeAll(ff);
        }
        try writer.writeAll(" :");
        if (bind.a) |aa| {
          try writer.writeAll(" ");
          try aa.format(writer);
        }
        try writer.writeAll(")");
      },
      .lambda => |lambda| {
        try writer.writeAll("{");
        if (lambda.a) |args| {
          try writer.writeAll("[");
          for (args, 0..) |arg, i| {
            if (i > 0) try writer.writeAll(";");
            if (arg.is_some) try writer.writeAll(arg.value);
          }
          try writer.writeAll("] ");
        }
        if (lambda.b) |seq| {
          for (seq) |node| {
            try node.format(writer);
            try writer.writeAll(" ");
          }
        }
        try writer.writeAll("}");
      },
      .list => |list| {
        try writer.writeAll("(");
        if (list.seq) |seq| {
          for (seq, 0..) |stmt, i| {
            if (i > 0) try writer.writeAll("; ");
            try stmt.format(writer);
          }
        }
        try writer.writeAll(")");
      },
      .command => |cmd| {
        try writer.print("\\{s}", .{cmd.verb});
        if (cmd.args.len > 0) try writer.print(" {s}", .{cmd.args});
      },
      .literal => |literal| {
        switch (literal) {
          .b => |bv| try writer.print("{d}b", .{@intFromBool(bv)}),
          .i => |i| try writer.print("{}", .{i}),
          .f => |n| try writer.print("{}", .{n}),
          .c => |s| try writer.print("\"{s}\"", .{s}),
          .s => |s| try writer.print("`{s}", .{s}),
          .@"var" => |v| try writer.writeAll(v),
          .B => |bv| {
            for (bv) |val| try writer.print("{d}", .{@intFromBool(val)});
            try writer.writeAll("b");
          },
          .F => |f| {
            for (f, 0..) |val, idx| {
              if (idx > 0) try writer.writeAll(" ");
              try writer.print("{}", .{val});
            }
          },
          .I => |i| {
            for (i, 0..) |val, idx| {
              if (idx > 0) try writer.writeAll(" ");
              try writer.print("{}", .{val});
            }
          },
          .C => |s| try writer.writeAll(s),
          .S => |s| {
            for (s, 0..) |sym, idx| {
              if (idx > 0) try writer.writeAll(" ");
              try writer.print("`{s}", .{sym});
            }
          },
        }
      },
      .cond => |c| {
        try writer.writeAll("$[");
        for (c.stmts, 0..) |stmt, i| {
          if (i > 0) try writer.writeAll("; ");
          try stmt.format(writer);
        }
        try writer.writeAll("]");
      },
      .amend => |seq| {
        try writer.writeAll("@[");
        for (seq, 0..) |stmt, i| {
          if (i > 0) try writer.writeAll("; ");
          try stmt.format(writer);
        }
        try writer.writeAll("]");
      },
      .dmend => |seq| {
        try writer.writeAll(".[");
        for (seq, 0..) |stmt, i| {
          if (i > 0) try writer.writeAll("; ");
          try stmt.format(writer);
        }
        try writer.writeAll("]");
      },

      .select => |s| {
        try writer.writeAll("select ");
        if (s.rows) |rows| {
          for (rows, 0..) |row, i| {
            if (i > 0) try writer.writeAll(",");
            try row.format(writer);
          }
        }
        if (s.by) |by| {
          try writer.writeAll(" by ");
          for (by, 0..) |row, i| {
            if (i > 0) try writer.writeAll(",");
            try row.format(writer);
          }
        }
        try writer.print(" from {s}", .{s.from});
        if (s.where) |wh| {
          try writer.writeAll(" where ");
          try wh.format(writer);
        }
      },
      .update => |u| {
        try writer.writeAll("update ");
        for (u.rows, 0..) |row, i| {
          if (i > 0) try writer.writeAll(",");
          try row.format(writer);
        }
        try writer.print(" from {s}", .{u.from});
        if (u.where) |wh| {
          try writer.writeAll(" where ");
          try wh.format(writer);
        }
      },
      .@"delete" => |d| {
        try writer.print("delete from {s}", .{d.from});
        if (d.where) |wh| {
          try writer.writeAll(" where ");
          try wh.format(writer);
        }
      },
      .monad => |vm| try writer.print("({s}:)", .{vm.f}),
      .adverb_val => |a| try writer.writeAll(a),
      else => try writer.writeAll("<node>"),
    }
  }
};


// Zig-based parser (replaces tree-sitter for the runtime).
pub const Parser = struct {
  alloc: std.mem.Allocator,

  pub fn init(allocator: std.mem.Allocator) !Parser {
    return .{ .alloc = allocator };
  }

  pub fn deinit(_: *Parser) void {}

  pub fn parse(self: *Parser, src: []const u8) Error!*Node {
    const zigparser = @import("parser.zig");
    var p = zigparser.Parser.init(self.alloc, src);
    return p.parse() catch |err| switch (err) {
      error.OutOfMemory => return error.OutOfMemory,
      else => return error.ParseFailed,
    };
  }

  pub fn free(self: Parser, n:*Node) void {
    switch (n.*) {
      .terse => |t| {
        for (t.stmts) |s| self.free(s.node);
        self.alloc.free(t.stmts);
      },
      .verb => |v| self.free(v),
      .stmt_clause => |c| self.free(c),
      .stmt_adjunct => |a| self.free(a),
      .right => |r| self.free(r.clause),
      .@"defer" => |d| self.free(d.adjunct),
      .bind => |b| { self.free(b.v); if (b.a) |a| self.free(a); },
      .transit => |t| { self.free(t.a); self.free(t.v); self.free(t.b); },
      .affix => |a| { self.free(a.a); self.free(a.b); },
      .apposit => |a| { self.free(a.f); self.free(a.a); },
      .phrase => |p| self.free(p),
      .pending => |p| { self.free(p.v); self.free(p.a); },
      .intrans => |i| { self.free(i.a); self.free(i.v); if (i.z) |z| self.free(z); },
      .prefix => |p| { self.free(p.a); if (p.z) |z| self.free(z); },
      .compose => |c| switch (c) {
        .v => |v| self.free(v),
        .fz => |fz| {
          self.free(fz.f);
          self.free(fz.z);
        },
      },
      .noun => |m| self.free(m),
      .phrase_verb => |pv| self.free(pv),
      .apply => |a| {
        self.free(a.f);
        if (a.a) |args| self.freeSeq(args);
      },
      .group => |g| self.free(g.stmt),
      .list => |l| if (l.seq) |s| self.freeSeq(s),
      .lambda => |l| {
        if (l.a) |a| self.alloc.free(a);
        if (l.b) |b| self.freeSeq(b);
      },
      .cond => |c| {
        for (c.stmts) |stmt| self.free(stmt);
        self.alloc.free(c.stmts);
      },
      .dict => |d| if (d.items) |items| self.freeItems(items),
      .table => |t| if (t.items) |items| self.freeItems(items),
      .utable => |u| {
        if (u.keys) |keys| self.freeItems(keys);
        if (u.items) |items| self.freeItems(items);
      },
      .literal => |lit| switch (lit) {
        .B => |b| self.alloc.free(b),
        .I => |i| self.alloc.free(i),
        .F => |f| self.alloc.free(f),
        .S => |s| self.alloc.free(s),
        else => {},
      },
      .term => |t| self.free(t.f),
      .amend => |seq| self.freeSeq(seq),
      .dmend => |seq| self.freeSeq(seq),
      .verb_op, .verb_io, .blank, .command, .monad, .adverb_val => {},
    }
    self.alloc.destroy(n);
  }

  fn freeSeq(self: Parser, seq: Seq) void { for (seq) |n| self.free(n); self.alloc.free(seq); }
  fn freeArgs(self: Parser, args: Args) void { self.alloc.free(args); }
  fn freeItems(self: Parser, items:Items) void { for (items) |item| self.free(item.v); self.alloc.free(items); }
};

fn build(alloc:Alloc, n:TSNode, src:[]const u8) Error!*Node {
  switch (n.nodeType()) {
    .comment => {
      const m = try alloc.create(Node);
      m.* = .blank;
      return m;
    },
    .terse=>{
      var stmts_list = try std.ArrayList(Stmt).initCapacity(alloc, 0);
      const count = n.namedChildCount();
      var i: u32 = 0;
      while (i < count) : (i += 1) {
        const c = n.namedChild(i);
        const child_type = c.nodeType();
        if (child_type == .comment) continue;
        if (child_type != .sep) {
          try stmts_list.append(alloc, .{
            .node = try build(alloc, c, src),
            .source = c.slice(src),
          });
        } else {
          const slice = c.slice(src);
          if (std.mem.indexOfScalar(u8, slice, ';') != null) {
            const m = try alloc.create(Node);
            m.* = .blank;
            try stmts_list.append(alloc, .{
              .node = m,
              .source = ";",
            });
          }
        }
      }
      const duped = try stmts_list.toOwnedSlice(alloc);
      const m = try alloc.create(Node);
      m.* = .{ .terse = .{ .stmts = duped } };
      return m;
    },
    .transit=>{
      const a = try build(alloc, n.namedChild(0), src);
      const v = try build(alloc, n.namedChild(1), src);
      const b = try build(alloc, n.namedChild(2), src);
      const m = try alloc.create(Node);
      m.* = .{ .transit = .{ .a = a, .v = v, .b = b } };
      return m;
    },
    .apposit=>{
      const f = try build(alloc, n.namedChild(0), src);
      const a = try build(alloc, n.namedChild(1), src);
      const m = try alloc.create(Node);
      m.* = .{ .apposit = .{ .f = f, .a = a } };
      return m;
    },
    .term=>{
      const f = try build(alloc, n.namedChild(0), src);
      const a_child = n.namedChild(1);
      const a = a_child.slice(src);
      const m = try alloc.create(Node);
      m.* = .{ .term = .{ .f = f, .a = a } };
      return m;
    },
    .bind=>{
      const count = n.childCount();
      var v: ?*Node = null;
      var f: ?Op = null;
      var a: ?*Node = null;
      var seen_colon = false;
      var i: u32 = 0;
      while (i < count) {
        const c = n.child(i);
        const child_type = c.nodeTypeName();
        if (eql(u8, child_type, ":")) {
          seen_colon = true;
          i += 1;
        } else if (!c.isNamed()) {
          i += 1;
        } else if (v == null) {
          v = try build(alloc, c, src);
          i += 1;
        } else if (!seen_colon and eql(u8, child_type, "op")) {
          f = trim(u8, c.slice(src), " ");
          i += 1;
        } else {
          a = try build(alloc, c, src);
          i += 1;
        }
      }
      const m = try alloc.create(Node);
      m.* = .{ .bind = .{ .v = v.?, .f = f, .a = a } };
      return m;
    },
    .op=>{
      const m = try alloc.create(Node);
      m.* = .{ .verb_op = trim(u8, n.slice(src), " ") };
      return m;
    },
    .literal=>{
      const c = n.namedChild(0);
      const child_type = c.nodeTypeName();
      var literal: Literal = undefined;
      if (eql(u8, child_type, "bool")) {
        const lit_slice = trim(u8, c.slice(src), " ");
        literal = .{ .b = lit_slice[0] == '1' };
      } else if (eql(u8, child_type, "bools")) {
        const lit_slice = trim(u8, c.slice(src), " ");
        const digits = lit_slice[0 .. lit_slice.len - 1]; // strip trailing 'b'
        const bs = try alloc.alloc(bool, digits.len);
        for (digits, 0..) |ch, j| bs[j] = (ch == '1');
        literal = .{ .B = bs };
      } else if (eql(u8, child_type, "int")) {
        const lit_slice = trim(u8, c.slice(src), " ");
        if (std.mem.eql(u8, lit_slice, "0N") or std.mem.eql(u8, lit_slice, "-0N")) {
          literal = .{ .i = std.math.minInt(i32) };
        } else if (std.mem.eql(u8, lit_slice, "0W")) {
          literal = .{ .i = std.math.maxInt(i32) };
        } else if (std.mem.eql(u8, lit_slice, "-0W")) {
          literal = .{ .i = std.math.minInt(i32) + 1 };
        } else {
          literal = .{ .i = try parseInt(i32, lit_slice, 0) };
        }
      } else if (eql(u8, child_type, "float")) {
        const lit_slice = trim(u8, c.slice(src), " ");
        if (std.mem.eql(u8, lit_slice, "0n") or std.mem.eql(u8, lit_slice, "-0n")) {
          literal = .{ .f = std.math.nan(f32) };
        } else if (std.mem.eql(u8, lit_slice, "0w")) {
          literal = .{ .f = std.math.inf(f32) };
        } else if (std.mem.eql(u8, lit_slice, "-0w")) {
          literal = .{ .f = -std.math.inf(f32) };
        } else {
          literal = .{ .f = try parseFloat(f32, lit_slice) };
        }
      } else if (eql(u8, child_type, "ints")) {
        // Opaque external token: parse space-separated integers from raw text
        const raw = trim(u8, c.slice(src), " \t");
        var list = try std.ArrayList(i32).initCapacity(alloc, 4);
        var iter = std.mem.tokenizeAny(u8, raw, " \t");
        while (iter.next()) |tok| {
          const val: i32 = if (eql(u8, tok, "0N") or eql(u8, tok, "-0N"))
            std.math.minInt(i32)
          else if (eql(u8, tok, "0W"))
            std.math.maxInt(i32)
          else if (eql(u8, tok, "-0W"))
            std.math.minInt(i32) + 1
          else
            try parseInt(i32, tok, 0);
          try list.append(alloc, val);
        }
        literal = .{ .I = try list.toOwnedSlice(alloc) };
      } else if (eql(u8, child_type, "floats")) {
        // Opaque external token: parse space-separated floats from raw text
        const raw = trim(u8, c.slice(src), " \t");
        var list = try std.ArrayList(f32).initCapacity(alloc, 4);
        var iter = std.mem.tokenizeAny(u8, raw, " \t");
        while (iter.next()) |tok| {
          const val: f32 = if (eql(u8, tok, "0n") or eql(u8, tok, "-0n"))
            std.math.nan(f32)
          else if (eql(u8, tok, "0w"))
            std.math.inf(f32)
          else if (eql(u8, tok, "-0w"))
            -std.math.inf(f32)
          else if (eql(u8, tok, "0N") or eql(u8, tok, "-0N"))
            @as(f32, @floatFromInt(std.math.minInt(i32)))
          else
            parseFloat(f32, tok) catch @as(f32, @floatFromInt(try parseInt(i32, tok, 0)));
          try list.append(alloc, val);
        }
        literal = .{ .F = try list.toOwnedSlice(alloc) };
      } else if (eql(u8, child_type, "string")) {
        const full = trim(u8, c.slice(src), " "); // TODO the leading whitespace is a bug in the tree-sitter grammar
        const lit_slice = full[1..full.len - 1];
        literal = .{ .c = lit_slice };
      } else if (eql(u8, child_type, "symbol")) {
        const full = trim(u8, c.slice(src), " "); // TODO the leading whitespace is a bug in the tree-sitter grammar
        var lit_slice = full[1..];
        if (lit_slice.len >= 2 and lit_slice[0] == '"' and lit_slice[lit_slice.len - 1] == '"') {
          lit_slice = lit_slice[1 .. lit_slice.len - 1];
        }
        literal = .{ .s = lit_slice };
      } else if (eql(u8, child_type, "symbols")) {
        // Opaque external token: parse backtick-separated symbols from raw text
        const raw = trim(u8, c.slice(src), " \t");
        var list = try std.ArrayList([]const u8).initCapacity(alloc, 4);
        var pos: usize = 0;
        while (pos < raw.len) {
          if (raw[pos] != '`') { pos += 1; continue; }
          pos += 1; // skip backtick
          const start = pos;
          if (pos < raw.len and raw[pos] == '"') {
            // quoted symbol: `"content"
            pos += 1;
            while (pos < raw.len and raw[pos] != '"') pos += 1;
            if (pos < raw.len) pos += 1; // skip closing "
            try list.append(alloc, raw[start + 1 .. pos - 1]);
          } else {
            while (pos < raw.len and raw[pos] != '`' and raw[pos] != ' ' and raw[pos] != '\t') pos += 1;
            try list.append(alloc, raw[start..pos]);
          }
        }
        literal = .{ .S = try list.toOwnedSlice(alloc) };
      } else {
        const lit_slice = c.slice(src);
        literal = .{ .@"var" = trim(u8, lit_slice, " ") }; // TODO do we need the slice?
      }
      const m = try alloc.create(Node);
      m.* = .{ .literal = literal };
      return m;
    },
    .list=>{
      var seq: ?Seq = null;
      var i: u32 = 0;
      const count = n.namedChildCount();
      while (i < count) {
        const c = n.namedChild(i);
        const ct = c.nodeTypeName();
        if (eql(u8, ct, "seq")) seq = try buildSeq(alloc, c, src);
        i += 1;
      }
      const m = try alloc.create(Node);
      m.* = .{ .list = .{ .seq = seq } };
      return m;
    },
    .seq=>{},
    .apply=>{
      const f = try build(alloc, n.namedChild(0), src);
      var a: ?Seq = null;
      var i: u32 = 1;
      const count = n.namedChildCount();
      while (i < count) {
        const c = n.namedChild(i);
        const ct = c.nodeTypeName();
        if (eql(u8, ct, "seq")) a = try buildSeq(alloc, c, src);
        i += 1;
      }
      const m = try alloc.create(Node);
      m.* = .{ .apply = .{ .f = f, .a = a } };
      return m;
    },
    .lambda=>{
      var a: ?Args = null;
      var b: ?Seq = null;
      var i: u32 = 0;
      const count = n.namedChildCount();
      while (i < count) {
        const child = n.namedChild(i);
        const child_type = child.nodeTypeName();
        if (eql(u8, child_type, "args")) {
          a = try buildArgs(alloc, child, src);
        } else if (eql(u8, child_type, "seq")) {
          b = try buildSeq(alloc, child, src);
        }
        i += 1;
      }
      const m = try alloc.create(Node);
      m.* = .{ .lambda = .{ .a = a, .b = b, .start = n.startByte(), .end = n.endByte() } };
      return m;
    },
    .compose=>{
      const m = try alloc.create(Node);
      if (n.namedChildCount() == 1) {
        m.* = .{ .compose = .{ .v = try build(alloc, n.namedChild(0), src) } };
      } else {
        const f = try build(alloc, n.namedChild(0), src);
        const z = try build(alloc, n.namedChild(1), src);
        m.* = .{ .compose = .{ .fz = .{ .f = f, .z = z } } };
      }
      return m;
    },
    .pending=>{
      const count = n.namedChildCount();
      const v = try build(alloc, n.namedChild(0), src);
      var f: ?Op = null;
      var a: *Node = undefined;
      var i: u32 = 1;
      while (i < count) {
        const c = n.namedChild(i);
        const ct = c.nodeTypeName();
        if (eql(u8, ct, "op")) {
          f = trim(u8, c.slice(src), " ");
        } else if (eql(u8, ct, ":")) {
          // skip
        } else {
          a = try build(alloc, c, src);
        }
        i += 1;
      }
      const m = try alloc.create(Node);
      m.* = .{ .pending = .{ .v = v, .f = f, .a = a } };
      return m;
    },

    .intrans=>{
      const a = try build(alloc, n.namedChild(0), src);
      const v = try build(alloc, n.namedChild(1), src);
      var z: ?*Node = null;
      if (n.namedChildCount() > 2) {
        z = try build(alloc, n.namedChild(2), src);
      }
      const m = try alloc.create(Node);
      m.* = .{ .intrans = .{ .a = a, .v = v, .z = z } };
      return m;
    },
    .prefix=>{
      const a = try build(alloc, n.namedChild(0), src);
      const v = trim(u8, n.namedChild(1).slice(src), " ");
      var z: ?*Node = null;
      if (n.namedChildCount() > 2) {
        z = try build(alloc, n.namedChild(2), src);
      }
      const m = try alloc.create(Node);
      m.* = .{ .prefix = .{ .a = a, .v = v, .z = z } };
      return m;
    },
    .group=>{
      const stmt = try build(alloc, n.namedChild(0), src);
      const m = try alloc.create(Node);
      m.* = .{ .group = .{ .stmt = stmt } };
      return m;
    },
    .cond=>{
      const count = n.namedChildCount();
      const stmts = try alloc.alloc(*Node, count);
      errdefer alloc.free(stmts);
      var i: u32 = 0;
      while (i < count) : (i += 1) {
        stmts[i] = try build(alloc, n.namedChild(i), src);
      }
      const m = try alloc.create(Node);
      m.* = .{ .cond = .{ .stmts = stmts } };
      return m;
    },

    .amend=>{
      const m = try alloc.create(Node);
      m.* = .{ .amend = try buildSeq(alloc, n.namedChild(0), src) };
      return m;
    },
    .dmend=>{
      const m = try alloc.create(Node);
      m.* = .{ .dmend = try buildSeq(alloc, n.namedChild(0), src) };
      return m;
    },


    .clause, .adjunct, .phrase, .verb, .noun => return try build(alloc, n.namedChild(0), src),
    // .args=>{},
    // .stmt_clause=>{},
    // .stmt_adjunct=>{},
    .right => {
      const m = try alloc.create(Node);
      m.* = .{ .right = .{ .clause = try build(alloc, n.namedChild(0), src) } };
      return m;
    },
    // .affix=>{},
    // .@"defer"=>{},
    // .phrase_verb=>{},
    .dict => {
      const m = try alloc.create(Node);
      m.* = .{ .dict = .{ .items = try buildItems(alloc, n, src) } };
      return m;
    },
    .table => {
      const m = try alloc.create(Node);
      m.* = .{ .table = .{ .items = try buildItems(alloc, n, src) } };
      return m;
    },
    .utable => {
      var keys_list = try std.ArrayList(Item).initCapacity(alloc, 0);
      var vals_list = try std.ArrayList(Item).initCapacity(alloc, 0);
      var seen_mid_bracket = false;
      const count = n.childCount();
      for (0..count) |ci| {
        const i: u32 = @intCast(ci);
        const c = n.child(i);
        const ct = c.nodeTypeName();
        if (eql(u8, ct, "]") and i > 0 and i < count - 1) seen_mid_bracket = true;
        if (eql(u8, ct, "item")) {
          const k_node = c.namedChild(0);
          const k = trim(u8, k_node.slice(src), " ");
          const v = if (c.namedChildCount() > 1) try build(alloc, c.namedChild(1), src) else blk: {
            const m = try alloc.create(Node);
            m.* = .blank;
            break :blk m;
          };
          if (!seen_mid_bracket) try keys_list.append(alloc, .{ .k = k, .v = v })
          else try vals_list.append(alloc, .{ .k = k, .v = v });
        }
      }
      const m = try alloc.create(Node);
      m.* = .{ .utable = .{ 
        .keys = if (keys_list.items.len > 0) try keys_list.toOwnedSlice(alloc) else null,
        .items = if (vals_list.items.len > 0) try vals_list.toOwnedSlice(alloc) else null 
      } };
      return m;
    },
    .verb_io => {
      const m = try alloc.create(Node);
      m.* = .{ .verb_io = trim(u8, n.slice(src), " ") };
      return m;
    },
    .div => {
      const m = try alloc.create(Node);
      m.* = .blank;
      return m;
    },
    .command => {
      const full = trim(u8, n.slice(src), " ");
      // full starts with '\', skip it
      const rest = if (full.len > 1) full[1..] else "";
      // split verb (first word) from args
      const space = std.mem.indexOfScalar(u8, rest, ' ');
      const verb = if (space) |s| rest[0..s] else rest;
      const args = if (space) |s| trim(u8, rest[s+1..], " ") else "";
      const m = try alloc.create(Node);
      m.* = .{ .command = .{ .verb = verb, .args = args } };
      return m;
    },
    .adverb => {
      // standalone adverb node used as a value (inside adverb_val or term context)
      const raw = trim(u8, n.slice(src), " ");
      const m = try alloc.create(Node);
      m.* = .{ .adverb_val = raw };
      return m;
    },
    .monad => {
      // namedChild(0) is the op; get the op text without the colon
      const op_text = trim(u8, n.namedChild(0).slice(src), " ");
      const m = try alloc.create(Node);
      m.* = .{ .monad = .{ .f = op_text } };
      return m;
    },
    .adverb_val => {
      const raw = trim(u8, n.slice(src), " ");
      const m = try alloc.create(Node);
      m.* = .{ .adverb_val = raw };
      return m;
    },
    // .sep=>{},
    else=>{
      std.debug.print("unsupported node {s}\n", .{n.nodeTypeName()});
    }
  }
  return Error.UnsupportedNodeType;
}

fn buildArgs(alloc: Alloc, node: TSNode, src: []const u8) Error!Args {
  const cc = node.namedChildCount();
  var args = try std.ArrayList(Arg).initCapacity(alloc, @intCast(cc));
  // `div` nodes (`;`) are separators, not arg positions.
  // A blank arg only arises when two consecutive divs appear (or a leading/trailing div).
  // Algorithm: track whether the current slot still needs a var.
  var awaiting_var = true; // first slot starts awaiting
  for (0..cc) |ci| {
    const i: u32 = @intCast(ci);
    const child = node.namedChild(i);
    if (eql(u8, child.nodeTypeName(), "var")) {
      if (awaiting_var) {
        try args.append(alloc, .{ .is_some = true, .value = child.slice(src) });
        awaiting_var = false;
      }
    } else if (eql(u8, child.nodeTypeName(), "div")) {
      if (awaiting_var) {
        // A div arrived before a var: this slot is blank
        try args.append(alloc, .{ .is_some = false, .value = "" });
      }
      awaiting_var = true; // start next slot
    }
  }
  // Trailing blank if the last slot had no var (e.g. `[a;b;]`)
  if (awaiting_var and args.items.len > 0) {
    try args.append(alloc, .{ .is_some = false, .value = "" });
  }
  return args.toOwnedSlice(alloc);
}

fn buildSeq(allocator: std.mem.Allocator, node: TSNode, source: []const u8) !Seq {
  const count = node.childCount();
  var seq_list = try std.ArrayList(*Node).initCapacity(allocator, 0);
  errdefer seq_list.deinit(allocator);

  var i: u32 = 0;
  var last_was_sep = true;
  while (i < count) : (i += 1) {
    const child = node.child(i);
    const type_name = child.nodeTypeName();
    const is_sep = eql(u8, type_name, "div") or eql(u8, type_name, ";") or eql(u8, type_name, "\n");
    if (eql(u8, type_name, "comment")) continue;

    if (is_sep) {
      if (last_was_sep) {
        const m = try allocator.create(Node);
        m.* = .blank;
        try seq_list.append(allocator, m);
      }
      last_was_sep = true;
    } else if (child.isNamed()) {
      try seq_list.append(allocator, try build(allocator, child, source));
      last_was_sep = false;
    }
  }
  if (last_was_sep) {
    const m = try allocator.create(Node);
    m.* = .blank;
    try seq_list.append(allocator, m);
  }
  return try seq_list.toOwnedSlice(allocator);
}

fn buildItems(alloc: Alloc, n: TSNode, src: []const u8) Error!Items {
  var items = try std.ArrayList(Item).initCapacity(alloc, 0);
  const count = n.childCount();
  for (0..count) |ci| {
    const i: u32 = @intCast(ci);
    const c = n.child(i);
    if (eql(u8, c.nodeTypeName(), "item")) {
      const k = trim(u8, c.namedChild(0).slice(src), " ");
      const v = if (c.namedChildCount() > 1) try build(alloc, c.namedChild(1), src) else blk: {
        const m = try alloc.create(Node);
        m.* = .blank;
        break :blk m;
      };
      try items.append(alloc, .{ .k = k, .v = v });
    }
  }
  return try items.toOwnedSlice(alloc);
}

extern fn tree_sitter_terse() ?*const TSLanguage;
extern fn ts_parser_new() ?*TSParser;
extern fn ts_parser_delete(parser: *TSParser) void;
extern fn ts_parser_set_language(parser: *TSParser, language: *const TSLanguage) bool;
extern fn ts_parser_parse_string(parser: *TSParser, old_tree: ?*const TSTree, string: [*]const u8, length: u32) ?*TSTree;
extern fn ts_tree_delete(tree: ?*TSTree) void;
extern fn ts_tree_root_node(tree: ?*TSTree) TSNode;
extern fn ts_node_type(node: TSNode) [*:0]const u8;
extern fn ts_node_is_named(node: TSNode) bool;
extern fn ts_node_start_byte(node: TSNode) u32;
extern fn ts_node_end_byte(node: TSNode) u32;
extern fn ts_node_child_count(node: TSNode) u32;
extern fn ts_node_child(node: TSNode, index: u32) TSNode;
extern fn ts_node_named_child_count(node: TSNode) u32;
extern fn ts_node_named_child(node: TSNode, index: u32) TSNode;
extern fn ts_set_allocator( malloc_fn: ?*const fn (size: usize) callconv(.C) ?*anyopaque, calloc_fn: ?*const fn (count: usize, size: usize) callconv(.C) ?*anyopaque, realloc_fn: ?*const fn (ptr: ?*anyopaque, size: usize) callconv(.C) ?*anyopaque, free_fn: ?*const fn (ptr: ?*anyopaque) callconv(.C) void, ) void;


test "Ints" {
  var parser = try Parser.init(std.heap.c_allocator);
  defer parser.deinit();
  const source = "1 2 3";
  const node = try parser.parse(source);
  defer parser.free(node);
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .literal);
  try std.testing.expect(stmt.literal == .I);
  try std.testing.expect(std.mem.eql(i32, stmt.literal.I, &[_]i32{ 1, 2, 3 }));
}

test "Explicit Apply" {
  var parser = try Parser.init(std.heap.c_allocator);
  defer parser.deinit();
  const source = "f[1]";
  const node = try parser.parse(source);
  defer parser.free(node);
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .apply);
  const apply = &stmt.apply;
  try std.testing.expect(apply.f.* == .literal);
  try std.testing.expect(apply.f.literal == .@"var");
  try std.testing.expect(std.mem.eql(u8, apply.f.literal.@"var", "f"));
  try std.testing.expect(apply.a != null);
  const seq = apply.a.?;
  try std.testing.expect(seq.len == 1);
  try std.testing.expect(seq[0].* == .literal);
  try std.testing.expect(seq[0].literal == .i);
  try std.testing.expect(seq[0].literal.i == 1);
}

test "Bind" {
  var parser = try Parser.init(std.heap.c_allocator);
  defer parser.deinit();
  const source = "a:1";
  const node = try parser.parse(source);
  defer parser.free(node);
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .bind);
  const bind = &stmt.bind;
  try std.testing.expect(bind.v.* == .literal);
  try std.testing.expect(bind.v.literal == .@"var");
  try std.testing.expect(std.mem.eql(u8, bind.v.literal.@"var", "a"));
  try std.testing.expect(bind.f == null);
  try std.testing.expect(bind.a != null);
  try std.testing.expect(bind.a.?.* == .literal);
  try std.testing.expect(bind.a.?.literal == .i);
  try std.testing.expect(bind.a.?.literal.i == 1);
}

test "Lambda" {
  var parser = try Parser.init(std.heap.c_allocator);
  defer parser.deinit();
  const source = "{x+1}";
  const node = try parser.parse(source);
  defer parser.free(node);
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .lambda);
  const lambda = &stmt.lambda;
  try std.testing.expect(lambda.a == null);
  try std.testing.expect(lambda.b != null);
  const seq = lambda.b.?;
  try std.testing.expect(seq.len == 1);
  const transit_node = seq[0];
  try std.testing.expect(transit_node.* == .transit);
  const transit = &transit_node.transit;
  try std.testing.expect(transit.a.* == .literal);
  try std.testing.expect(transit.a.literal == .@"var");
  // try std.testing.expect(std.mem.eql(u8, transit.a.literal.@"var", "x"));
  // try std.testing.expect(transit.v.* == .verb_op);
  // try std.testing.expect(std.mem.eql(u8, transit.v.verb_op, "+"));
  // try std.testing.expect(transit.b.* == .literal);
  // try std.testing.expect(transit.b.literal == .i);
  // try std.testing.expect(transit.b.literal.i == 1);
  // std.debug.print("AST {f}\n", .{node});
}

test "Adverb" {
  var parser = try Parser.init(std.heap.c_allocator);
  defer parser.deinit();
  const source = "+/ 1 2 3";
  const node = try parser.parse(source);
  defer parser.free(node);
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .apposit);
  const apposit = &stmt.apposit;
  try std.testing.expect(apposit.f.* == .term);
  const term = &apposit.f.term;
  try std.testing.expect(std.mem.eql(u8, term.f.verb_op, "+"));
  try std.testing.expect(std.mem.eql(u8, term.a, "/"));
  try std.testing.expect(apposit.a.* == .literal);
  try std.testing.expect(apposit.a.literal == .I);
  try std.testing.expect(std.mem.eql(i32, apposit.a.literal.I, &[_]i32{ 1, 2, 3 }));
}

test "Implicit Call" {
  var parser = try Parser.init(std.heap.c_allocator);
  defer parser.deinit();
  const source = "f 1";
  const node = try parser.parse(source);
  defer parser.free(node);
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .apposit);
  const apposit = &stmt.apposit;
  try std.testing.expect(apposit.f.* == .literal);
  try std.testing.expect(apposit.f.literal == .@"var");
  try std.testing.expect(std.mem.eql(u8, apposit.f.literal.@"var", "f"));
  try std.testing.expect(apposit.a.* == .literal);
  try std.testing.expect(apposit.a.literal == .i);
  try std.testing.expect(apposit.a.literal.i == 1);
}

test "List" {
  var parser = try Parser.init(std.heap.c_allocator);
  defer parser.deinit();
  const source = "(1 2 3; 4 5 6)";
  const node = try parser.parse(source);
  defer parser.free(node);
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .list);
  const list = &stmt.list;
  try std.testing.expect(list.seq != null);
  const seq = list.seq.?;
  try std.testing.expect(seq.len == 2);
  try std.testing.expect(seq[0].* == .literal);
  try std.testing.expect(seq[0].literal == .I);
  try std.testing.expect(std.mem.eql(i32, seq[0].literal.I, &[_]i32{ 1, 2, 3 }));
  try std.testing.expect(seq[1].* == .literal);
  try std.testing.expect(seq[1].literal == .I);
  try std.testing.expect(std.mem.eql(i32, seq[1].literal.I, &[_]i32{ 4, 5, 6 }));
  // std.debug.print("AST {f}\n", .{node});
}

test "String" {
  var parser = try Parser.init(std.heap.c_allocator);
  defer parser.deinit();
  const source = "\"Hello\"";
  const node = try parser.parse(source);
  defer parser.free(node);
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .literal);
  try std.testing.expect(stmt.literal == .c);
  try std.testing.expect(std.mem.eql(u8, stmt.literal.c, "Hello"));
}

test "Symbol" {
  var parser = try Parser.init(std.heap.c_allocator);
  defer parser.deinit();
  const source = "`abc";
  const node = try parser.parse(source);
  defer parser.free(node);
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .literal);
  try std.testing.expect(stmt.literal == .s);
  try std.testing.expect(std.mem.eql(u8, stmt.literal.s, "abc"));
}
