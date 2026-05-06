// Corpus test runner for the hand-written Zig parser.
// Reads test files in the same format as tree-sitter's test corpus:
//
//   ==================
//   test name
//   ==================
//   input expression
//   ---
//   (expected s-expression)
//
// Run from build.zig or directly:  zig test src/corpus.zig

const std = @import("std");
const Alloc = std.mem.Allocator;
const ast = @import("parser/ast.zig");
const Node = ast.Node;
const Literal = ast.Literal;
const parser = @import("parser/parser.zig");
const MockWriter = @import("util.zig").MockWriter;

const W = *std.Io.Writer;

// ---- S-expression formatter ----

pub fn formatSexp(n: *Node, w: W) !void {
  switch (n.*) {
    .terse => |t| {
      try w.writeAll("(terse");
      for (t.stmts, 0..) |stmt, i| {
        if (i > 0) try w.writeAll(" (sep)");
        if (stmt.node.* != .blank) {
          try w.writeAll(" ");
          try formatSexp(stmt.node, w);
        }
      }
      try w.writeAll(")");
    },
    .literal => |lit| {
      try w.writeAll("(literal (");
      switch (lit) {
        .b  => try w.writeAll("bool"),
        .B  => try w.writeAll("bools"),
        .i  => try w.writeAll("int"),
        .I  => try w.writeAll("ints"),
        .f  => try w.writeAll("float"),
        .F  => try w.writeAll("floats"),
        .c  => try w.writeAll("string"),
        .C  => try w.writeAll("string"),
        .s  => try w.writeAll("symbol"),
        .S  => try w.writeAll("symbols"),
        .@"var" => try w.writeAll("var"),
      }
      try w.writeAll("))");
    },
    .verb_op => try w.writeAll("(op)"),
    .verb_io => try w.writeAll("(verb_io)"),
    .adverb_val => try w.writeAll("(adverb_val)"),
    .transit => |t| {
      try w.writeAll("(transit ");
      try formatSexp(t.a, w);
      try w.writeAll(" ");
      try formatSexp(t.v, w);
      try w.writeAll(" ");
      try formatSexp(t.b, w);
      try w.writeAll(")");
    },
    .apposit => |a| {
      try w.writeAll("(apposit ");
      try formatSexp(a.f, w);
      try w.writeAll(" ");
      try formatSexp(a.a, w);
      try w.writeAll(")");
    },
    .bind => |b| {
      try w.writeAll("(bind ");
      try formatSexp(b.v, w);
      if (b.f) |f| {
        // augmented bind: a+:1 → (bind (var) (op) (int))
        _ = f;
        try w.writeAll(" (op)");
      }
      if (b.a) |a| {
        try w.writeAll(" ");
        try formatSexp(a, w);
      }
      try w.writeAll(")");
    },
    .right => |r| {
      try w.writeAll("(right ");
      try formatSexp(r.clause, w);
      try w.writeAll(")");
    },
    .term => |t| {
      try w.writeAll("(term ");
      try formatSexp(t.f, w);
      try w.writeAll(" (adverb))");
    },
    .group => |g| {
      try w.writeAll("(group ");
      try formatSexp(g.stmt, w);
      try w.writeAll(")");
    },
    .list => |l| {
      if (l.seq) |seq| {
        try w.writeAll("(list (seq");
        for (seq, 0..) |item, i| {
          if (i > 0) try w.writeAll(" (div)");
          try w.writeAll(" ");
          try formatSexp(item, w);
        }
        try w.writeAll("))");
      } else {
        try w.writeAll("(list)");
      }
    },
    .lambda => |l| {
      try w.writeAll("(lambda");
      if (l.a) |args| {
        try w.writeAll(" (args");
        for (args, 0..) |arg, i| {
          if (i > 0) try w.writeAll(" (div)");
          if (arg.is_some) {
            try w.writeAll(" (var)");
          }
        }
        try w.writeAll(")");
      }
      if (l.b) |seq| {
        try w.writeAll(" (seq");
        for (seq, 0..) |item, i| {
          if (i > 0) try w.writeAll(" (div)");
          try w.writeAll(" ");
          try formatSexp(item, w);
        }
        try w.writeAll(")");
      }
      try w.writeAll(")");
    },
    .apply => |a| {
      try w.writeAll("(apply ");
      try formatSexp(a.f, w);
      if (a.a) |seq| {
        try w.writeAll(" (seq");
        for (seq, 0..) |item, i| {
          if (i > 0) try w.writeAll(" (div)");
          try w.writeAll(" ");
          try formatSexp(item, w);
        }
        try w.writeAll(")");
      }
      try w.writeAll(")");
    },
    .dict => |d| {
      try w.writeAll("(dict");
      if (d.items) |items| {
        for (items) |item| {
          try w.writeAll(" (item (");
          try w.writeAll(keyType(item.k));
          try w.writeAll(") ");
          try formatSexp(item.v, w);
          try w.writeAll(")");
        }
      }
      try w.writeAll(")");
    },
    .table => |t| {
      try w.writeAll("(table");
      if (t.items) |items| {
        for (items) |item| {
          try w.writeAll(" (item (");
          try w.writeAll(keyType(item.k));
          try w.writeAll(") ");
          try formatSexp(item.v, w);
          try w.writeAll(")");
        }
      }
      try w.writeAll(")");
    },
    .cond => |c| {
      try w.writeAll("(cond");
      for (c.stmts) |s| {
        try w.writeAll(" ");
        try formatSexp(s, w);
      }
      try w.writeAll(")");
    },
    .intrans => |it| {
      try w.writeAll("(intrans ");
      try formatSexp(it.a, w);
      try w.writeAll(" ");
      try formatSexp(it.v, w);
      try w.writeAll(")");
    },
    .monad => try w.writeAll("(monad)"),
    .blank => try w.writeAll("(blank)"),
    .command => try w.writeAll("(command)"),
    else => try w.writeAll("(?)"),
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

// ---- Corpus file parser ----

pub const TestCase = struct {
  name: []const u8,
  input: []const u8,
  expected: []const u8,
};

fn isDelim(line: []const u8) bool {
  if (line.len < 3) return false;
  for (line) |c| {
    if (c != '=') return false;
  }
  return true;
}

pub fn parseCorpus(src: []const u8, alloc: Alloc) ![]TestCase {
  var cases = try std.ArrayList(TestCase).initCapacity(alloc, 0);
  var lines = std.mem.splitScalar(u8, src, '\n');
  var state: enum { seek_delim, seek_name, seek_delim2, seek_input, seek_expected } = .seek_delim;
  var name: []const u8 = "";
  var input_start: usize = 0;
  var input_end: usize = 0;
  var expected_start: usize = 0;
  var pos: usize = 0;

  while (lines.next()) |raw_line| {
    const line = std.mem.trim(u8, raw_line, " \r");
    const line_end = pos + raw_line.len + 1; // +1 for the newline

    switch (state) {
      .seek_delim => {
        if (isDelim(line)) state = .seek_name;
      },
      .seek_name => {
        name = line;
        state = .seek_delim2;
      },
      .seek_delim2 => {
        if (isDelim(line)) {
          input_start = line_end;
          state = .seek_input;
        }
      },
      .seek_input => {
        if (std.mem.eql(u8, line, "---")) {
          input_end = pos;
          expected_start = line_end;
          state = .seek_expected;
        }
      },
      .seek_expected => {
        if (isDelim(line)) {
          const expected_end = pos;
          const input_raw = std.mem.trim(u8, src[input_start..input_end], " \t\n\r");
          const expected_raw = std.mem.trim(u8, src[expected_start..expected_end], " \t\n\r");
          try cases.append(alloc, .{
            .name = name,
            .input = input_raw,
            .expected = expected_raw,
          });
          name = line; // delimiter also starts next test? no — need next state
          state = .seek_name; // next line after delimiter is the name
        }
      },
    }
    pos = line_end;
  }

  // Handle last test (no trailing delimiter)
  if (state == .seek_expected) {
    const expected_raw = std.mem.trim(u8, src[expected_start..], " \t\n\r");
    const input_raw = std.mem.trim(u8, src[input_start..input_end], " \t\n\r");
    try cases.append(alloc, .{
      .name = name,
      .input = input_raw,
      .expected = expected_raw,
    });
  }

  return cases.toOwnedSlice(alloc);
}

// ---- Test runner ----

const testing = std.testing;

fn runCorpusFile(alloc: Alloc, path: []const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  const src = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(1024 * 1024));
  defer alloc.free(src);

  const cases = try parseCorpus(src, alloc);
  defer alloc.free(cases);

  var pass: u32 = 0;
  var fail: u32 = 0;
  for (cases) |tc| {
    var p = parser.Parser.init(alloc);
    const n = p.parse(tc.input) catch |err| {
      fail += 1;
      std.debug.print("FAIL [{s}]: parse error {s}\n", .{ tc.name, @errorName(err) });
      continue;
    };
    defer parser.freeNode(alloc, n);

    var mock = try MockWriter.init(alloc);
    defer mock.deinit();
    var mw = mock.writer();
    try formatSexp(n, &mw.interface);
    const got = mock.getText();

    if (std.mem.eql(u8, got, tc.expected)) {
      pass += 1;
    } else {
      fail += 1;
      std.debug.print("FAIL [{s}]\n  input:    {s}\n  expected: {s}\n  got:      {s}\n",
        .{ tc.name, tc.input, tc.expected, got });
    }
  }

  if (fail > 0) {
    std.debug.print("{s}: {d} pass, {d} fail\n", .{ path, pass, fail });
    return error.CorpusTestFailed;
  }
}

test "corpus literals" {
  const alloc = testing.allocator;
  try runCorpusFile(alloc, "test/corpus/ink/literals.txt");
}

test "corpus verbs" {
  const alloc = testing.allocator;
  try runCorpusFile(alloc, "test/corpus/ink/verbs.txt");
}
