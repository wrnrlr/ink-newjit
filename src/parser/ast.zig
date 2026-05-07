const std = @import("std");

pub const Error = error{ OutOfMemory, ParseFailed, Overflow, InvalidCharacter };

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
pub const Bind = struct { v: *Node, f: ?Op, a: ?*Node };
pub const Pending = struct { v: *Node, f: ?Op, a: *Node };
pub const Transit = struct { a: *Node, v: *Node, b: *Node };
pub const Intrans = struct { a: *Node, v: *Node, z: ?*Node };
pub const Apposit = struct { f: *Node, a: *Node };
pub const ComposeFz = struct { f: *Node, z: *Node };
pub const Compose = union(enum) { v: *Node, fz: ComposeFz };
pub const Affix = struct { a: *Node, v: Op, b: *Node };
pub const Prefix = struct { a: *Node, v: Op, z: ?*Node };
pub const Term = struct { f: *Node, a: Adverb };
pub const VerbMonad = struct { f: Op };
pub const Apply = struct { f: *Node, a: ?Seq };
pub const Group = struct { stmt: *Node };
pub const List = struct { seq: ?Seq };
pub const Lambda = struct { a: ?Args, b: ?Seq, start: u32, end: u32 };
pub const Cond = struct { stmts: []*Node };
pub const Dict = struct { items: ?Items };
pub const UTable = struct { keys: ?Items, items: ?Items };
// pub const Select = struct { rows: ?Seq, by: ?Seq, from: Var, where: ?*Node };
// pub const Update = struct { rows: Seq, from: Var, where: ?*Node };
// pub const Delete = struct { from: Var, where: ?*Node };

const NodeType = enum {
  terse, verb, stmt_clause, stmt_adjunct, right, bind,
  transit, affix, apposit, phrase, @"defer", pending,
  intrans, prefix, compose, noun, phrase_verb, apply,
  group, list, lambda, dict, table, utable, literal, term,
  verb_op, io, blank, cond,
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
  io: Io,
  blank: void,
  cond: Cond,
  command: Command,
  monad: VerbMonad,
  adverb_val: Adverb,

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
      .monad => |vm| try writer.print("({s}:)", .{vm.f}),
      .adverb_val => |a| try writer.writeAll(a),
      else => try writer.writeAll("<node>"),
    }
  }
};

pub const Parser = @import("parser.zig").Parser;

test "Ints" {
  var parser = Parser.init(std.heap.c_allocator);
  const node = try parser.parse("1 2 3");
  defer parser.deinit();
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .literal);
  try std.testing.expect(stmt.literal == .I);
  try std.testing.expect(std.mem.eql(i32, stmt.literal.I, &[_]i32{ 1, 2, 3 }));
}

test "Explicit Apply" {
  var parser = Parser.init(std.heap.c_allocator);
  const node = try parser.parse("f[1]");
  defer parser.deinit();
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
  var parser = Parser.init(std.heap.c_allocator);
  const node = try parser.parse("a:1");
  defer parser.deinit();
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
  var parser = Parser.init(std.heap.c_allocator);
  const node = try parser.parse("{x+1}");
  defer parser.deinit();
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
}

test "Adverb" {
  var parser = Parser.init(std.heap.c_allocator);
  const node = try parser.parse("+/ 1 2 3");
  defer parser.deinit();
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
  var parser = Parser.init(std.heap.c_allocator);
  const node = try parser.parse("f 1");
  defer parser.deinit();
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
  var parser = Parser.init(std.heap.c_allocator);
  const node = try parser.parse("(1 2 3; 4 5 6)");
  defer parser.deinit();
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
}

test "String" {
  var parser = Parser.init(std.heap.c_allocator);
  const node = try parser.parse("\"Hello\"");
  defer parser.deinit();
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .literal);
  try std.testing.expect(stmt.literal == .c);
  try std.testing.expect(std.mem.eql(u8, stmt.literal.c, "Hello"));
}

test "Symbol" {
  var parser = Parser.init(std.heap.c_allocator);
  const node = try parser.parse("`abc");
  defer parser.deinit();
  try std.testing.expect(node.* == .terse);
  try std.testing.expect(node.terse.stmts.len == 1);
  const stmt = node.terse.stmts[0].node;
  try std.testing.expect(stmt.* == .literal);
  try std.testing.expect(stmt.literal == .s);
  try std.testing.expect(std.mem.eql(u8, stmt.literal.s, "abc"));
}
