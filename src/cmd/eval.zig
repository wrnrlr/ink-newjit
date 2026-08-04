const std = @import("std");
const VM = @import("../runtime/vm.zig").VM;
const TerseFormatter = @import("../noun/format.zig").TerseFormatter;
const MockWriter = @import("../util.zig").MockWriter;
const V = @import("../noun/value.zig").V;

/// Statement-by-statement evaluation of a source text, with each statement's
/// result rendered the way it would be shown at a prompt.
///
/// `stream` prints results as it goes — that is how `ink script.k` and
/// `ink < file` run. `collect` returns them instead, for the Jupyter kernel,
/// which needs one cell's worth at a time. The INTERACTIVE loop is not here: it
/// is `tools/repl.k`, written in ink.

/// A byte offset resolved to a 1-based line/column plus that source line.
pub const SrcPos = struct {
  line: u32, col: u32, text: []const u8,

  pub fn of(src: []const u8, off: u32) SrcPos {
    const o = @min(off, src.len);
    var line: u32 = 1;
    var bol: usize = 0;
    for (src[0..o], 0..) |ch, i| if (ch == '\n') { line += 1; bol = i + 1; };
    var eol = bol;
    while (eol < src.len and src[eol] != '\n') eol += 1;
    return .{ .line = line, .col = @intCast(o - bol + 1), .text = src[bol..eol] };
  }
};

/// `!parse_error: <name> at L:C` followed by the offending line and a caret.
/// Purely a reporting path — the position comes from the parser, so the VM is
/// untouched and nothing is carried at runtime.
fn writeParseError(w: *std.Io.Writer, err: anyerror, src: []const u8, off: u32) void {
  const p = SrcPos.of(src, off);
  w.print("!parse_error: {s} at {d}:{d}\n", .{ @errorName(err), p.line, p.col }) catch return;
  if (p.text.len == 0) return;
  w.print("  {s}\n  ", .{p.text}) catch return;
  // Indent with the line's own leading whitespace so tabs line the caret up.
  for (p.text[0..@min(p.col - 1, p.text.len)]) |ch| w.writeByte(if (ch == '\t') '\t' else ' ') catch return;
  w.print("^\n", .{}) catch return;
}

pub const Eval = struct {
  vm: *VM,
  alloc: std.mem.Allocator,

  pub fn init(alloc: std.mem.Allocator, vm: *VM) Eval {
    return .{ .alloc = alloc, .vm = vm };
  }

  pub const Result = struct {
    output: []const u8,
    value: V,
  };

  pub const Results = struct {
    results: []Result,
    is_error: bool,
    vm_alloc: std.mem.Allocator,

    pub fn deinit(self: Results, alloc: std.mem.Allocator) void {
      for (self.results) |res| {
        alloc.free(res.output);
        res.value.deinit(self.vm_alloc);
      }
      alloc.free(self.results);
    }
  };

  /// Evaluate `source` and return one result per statement.
  /// `pretty` selects the multi-line rendering for dicts/tables.
  pub fn collect(self: *Eval, source: []const u8, pretty: bool) !Results {
    if (source.len == 0) {
      return Results{ .results = &.{}, .is_error = false, .vm_alloc = self.vm.alloc };
    }

    const node = self.vm.parser.?.parse(source) catch |err| {
      const p = SrcPos.of(source, self.vm.parser.?.err_pos);
      const msg = try std.fmt.allocPrint(self.alloc, "!parse_error: {s} at {d}:{d}",
        .{ @errorName(err), p.line, p.col });
      const results = try self.alloc.alloc(Result, 1);
      results[0] = .{ .output = msg, .value = V.nil };
      return Results{ .results = results, .is_error = true, .vm_alloc = self.vm.alloc };
    };
    if (node.* != .terse) { self.vm.parser.?.free(node); return error.UnexpectedNode; }

    // Take the statement spans before any vm.eval: that parses again, which
    // resets the parser arena and invalidates `node`.
    const stmts = try self.stmtSpans(node);
    defer self.alloc.free(stmts);
    self.vm.parser.?.free(node);

    var results = try std.ArrayList(Result).initCapacity(self.alloc, stmts.len);
    errdefer {
      for (results.items) |r| { self.alloc.free(r.output); r.value.deinit(self.vm.alloc); }
      results.deinit(self.alloc);
    }

    for (stmts) |stmt| {
      var res = self.vm.eval(stmt.src) catch |err| {
        const msg = try std.fmt.allocPrint(self.alloc, "!{s}", .{@errorName(err)});
        try results.append(self.alloc, .{ .output = msg, .value = V.nil });
        return Results{ .results = try results.toOwnedSlice(self.alloc), .is_error = true, .vm_alloc = self.vm.alloc };
      };
      if (stmt.suppressed) { res.deinit(self.vm.alloc); res = V.nil; }
      try results.append(self.alloc, .{ .output = try self.render(res, pretty), .value = res });
    }

    return .{
      .results = try results.toOwnedSlice(self.alloc),
      .is_error = false,
      .vm_alloc = self.vm.alloc,
    };
  }

  /// Evaluate statement by statement, printing each result as it is produced so
  /// it interleaves with the io verbs' own output. True if an error occurred.
  pub fn stream(self: *Eval, source: []const u8, writer: *std.Io.Writer) !bool {
    if (source.len == 0) return false;

    const node = self.vm.parser.?.parse(source) catch |err| {
      writeParseError(writer, err, source, self.vm.parser.?.err_pos);
      writer.flush() catch {};
      return true;
    };
    if (node.* != .terse) { self.vm.parser.?.free(node); return false; }

    // Order-independent defs: a script is compiled statement-by-statement below, so
    // pre-register every qualified top-level target across the WHOLE file first —
    // a reference to `group.expand` (or bare `expand` inside `group`) then resolves
    // even when its definition appears later in the file.
    self.vm.compiler.prescanGlobals(node.terse.stmts) catch {};

    const stmts = try self.stmtSpans(node);
    defer self.alloc.free(stmts);
    self.vm.parser.?.free(node);

    for (stmts) |stmt| {
      var res = self.vm.eval(stmt.src) catch |err| {
        writer.print("!{s}\n", .{@errorName(err)}) catch {};
        writer.flush() catch {};
        return true;
      };
      defer res.deinit(self.vm.alloc);
      if (stmt.suppressed) continue;

      const text = try self.render(res, false);
      defer self.alloc.free(text);
      if (text.len > 0) {
        writer.print("{s}\n", .{text}) catch {};
        writer.flush() catch {};
      }
    }
    return false;
  }

  const Stmt = struct { src: []const u8, suppressed: bool };

  /// The statements of a parsed source, as slices of it. Blank statements are
  /// dropped, except the `;` the parser emits for a trailing semicolon: that one
  /// suppresses the result of the statement before it (`2+2;` evaluates and
  /// prints nothing). Its `.source` is a literal `";"`, not a slice of the input,
  /// so it is recorded as a flag rather than folded into the span.
  fn stmtSpans(self: *Eval, node: anytype) ![]const Stmt {
    var out = try std.ArrayList(Stmt).initCapacity(self.alloc, node.terse.stmts.len);
    errdefer out.deinit(self.alloc);
    for (node.terse.stmts) |s| {
      if (s.node.* != .blank) { try out.append(self.alloc, .{ .src = s.source, .suppressed = false }); continue; }
      if (out.items.len == 0 or !std.mem.eql(u8, s.source, ";")) continue;
      out.items[out.items.len - 1].suppressed = true;
    }
    return out.toOwnedSlice(self.alloc);
  }

  /// A result as text, trimmed of trailing whitespace. Empty for a null (`::`)
  /// result, which prints nothing, as in ngn/k — assignments, `\d` and the
  /// side-effecting verbs all yield one.
  fn render(self: *Eval, v: V, pretty: bool) ![]const u8 {
    if (v.isNil()) return self.alloc.dupe(u8, "");
    var mock = try MockWriter.init(self.alloc);
    defer mock.deinit();
    var fmt = TerseFormatter.init(self.vm, self.alloc, .Repl);
    fmt.pretty = pretty;
    var w = mock.writer();
    fmt.formatter().fmt(v, &w.interface) catch {};
    var text = mock.getText();
    while (text.len > 0 and std.ascii.isWhitespace(text[text.len - 1])) text = text[0 .. text.len - 1];
    return self.alloc.dupe(u8, text);
  }
};
