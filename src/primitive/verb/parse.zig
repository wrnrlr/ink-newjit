const std = @import("std");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const ast = @import("../../parser/ast.zig");
const Node = ast.Node;
const parser_mod = @import("../../parser/parser.zig");
const util = @import("../../util.zig");

pub const Parse = struct {
  pub const op = .parse;
  _C: util.MonadFn = parseChars,
};

fn parseChars(vm: *VM, x: V) V {
  var p = parser_mod.Parser.init(vm.alloc);
  defer p.deinit();
  const node = p.parse(x.C.slice()) catch return V{ .err = .domain };
  return nodeToV(vm, node) catch return V{ .err = .memory };
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
      var list = try std.ArrayList(V).initCapacity(alloc, 2);
      errdefer { for (list.items) |v| v.deinit(alloc); list.deinit(alloc); }
      try list.append(alloc, try sym(vm, "literal"));
      try list.append(alloc, try sym(vm, type_name));
      return transfer(alloc, &list);
    },
    .verb_op    => return sym(vm, "op"),
    .io    => return sym(vm, "verb_io"),
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
      try list.append(alloc, try sym(vm, "adverb"));
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
          if (arg.is_some) try inner.append(alloc, try sym(vm, "var"));
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

fn keyType(k: []const u8) []const u8 {
  if (k.len == 0) return "var";
  const c = k[0];
  if (std.ascii.isDigit(c) or c == '-') return "int";
  if (c == '`') return "symbol";
  if (c == '"') return "string";
  return "var";
}
