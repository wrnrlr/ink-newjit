const std = @import("std");
const VM = @import("../runtime/vm.zig").VM;
const TerseFormatter = @import("../noun/format.zig").TerseFormatter;
const MockWriter = @import("../util.zig").MockWriter;
const V = @import("../noun/value.zig").V;

/// A generic interface for evaluating Terse expressions and formatting results.
/// This can be used by both the CLI and GUI environments.
pub const Repl = struct {
  vm: *VM,
  alloc: std.mem.Allocator,

  pub fn init(alloc: std.mem.Allocator, vm: *VM) Repl {
    return .{ .alloc = alloc, .vm = vm };
  }

  pub const Result = struct {
    source: []const u8,
    output: []const u8,
    value: V,
  };

  pub const EvalResult = struct {
    results: []Result,
    is_error: bool,
    vm_alloc: std.mem.Allocator,

    pub fn deinit(self: EvalResult, alloc: std.mem.Allocator) void {
      for (self.results) |res| {
        alloc.free(res.source);
        alloc.free(res.output);
        res.value.deinit(self.vm_alloc);
      }
      alloc.free(self.results);
    }
  };

  /// Evaluates a string of source code and returns a list of results for each statement.
  /// `pretty` selects the multi-line REPL rendering for dicts/tables (the caller
  /// passes false when the entry began with whitespace, to get the raw k literal).
  pub fn eval(self: *Repl, source: []const u8, pretty: bool) !EvalResult {
    if (source.len == 0) {
      return EvalResult{ .results = &.{}, .is_error = false, .vm_alloc = self.vm.alloc };
    }

    const node = self.vm.parser.?.parse(source) catch |err| {
      const msg = try std.fmt.allocPrint(self.alloc, "!parse_error: {s}", .{@errorName(err)});
      const results = try self.alloc.alloc(Result, 1);
      results[0] = .{ .source = try self.alloc.dupe(u8, source), .output = msg, .value = .blank };
      return EvalResult{ .results = results, .is_error = true, .vm_alloc = self.vm.alloc };
    };
    defer self.vm.parser.?.free(node);

    if (node.* != .terse) return error.UnexpectedNode;

    var results_list = try std.ArrayList(Result).initCapacity(self.alloc, 0);
    errdefer {
      for (results_list.items) |r| {
        self.alloc.free(r.source);
        self.alloc.free(r.output);
        r.value.deinit(self.vm.alloc);
      }
      results_list.deinit(self.alloc);
    }

    // Pre-extract all stmt info before any vm.eval call.
    // vm.eval calls parse() which resets the parser arena, invalidating node.
    const StmtInfo = struct { is_blank: bool, source: []const u8 };
    const stmt_infos = try self.alloc.alloc(StmtInfo, node.terse.stmts.len);
    defer self.alloc.free(stmt_infos);
    for (node.terse.stmts, 0..) |s, j| {
      stmt_infos[j] = .{ .is_blank = s.node.* == .blank, .source = s.source };
    }

    const src_base: usize = @intFromPtr(source.ptr);
    var prev_src_end: usize = 0;

    var i: usize = 0;
    while (i < stmt_infos.len) {
      const stmt = stmt_infos[i];
      i += 1;

      if (stmt.is_blank) continue;

      // stmt.source is a slice of source; compute its byte offset.
      const stmt_start = @intFromPtr(stmt.source.ptr) - src_base;
      const stmt_raw_end = stmt_start + stmt.source.len;

      // Emit any line comments that appear in the raw source gap before this stmt.
      try emitGapComments(self.alloc, source[prev_src_end..stmt_start], &results_list);

      // Extend stmt source to include an inline comment on the same line ( /... ).
      var stmt_end = stmt_raw_end;
      {
        var ext = stmt_raw_end;
        while (ext < source.len and (source[ext] == ' ' or source[ext] == '\t')) ext += 1;
        if (ext < source.len and source[ext] == '/') {
          while (ext < source.len and source[ext] != '\n') ext += 1;
          stmt_end = ext;
        }
      }
      prev_src_end = stmt_end;

      // Semicolon suppression: if the next blank has source ";" the result is discarded.
      var is_suppressed = false;
      var full_stmt_src = try std.ArrayList(u8).initCapacity(self.alloc, 0);
      defer full_stmt_src.deinit(self.alloc);
      try full_stmt_src.appendSlice(self.alloc, source[stmt_start..stmt_end]);

      if (i < stmt_infos.len and stmt_infos[i].is_blank and
          std.mem.eql(u8, stmt_infos[i].source, ";")) {
        try full_stmt_src.appendSlice(self.alloc, ";");
        i += 1;
        is_suppressed = true;
      }

      const stmt_src = try full_stmt_src.toOwnedSlice(self.alloc);

      var res = self.vm.eval(stmt_src) catch |err| {
        const msg = try std.fmt.allocPrint(self.alloc, "!{s}", .{@errorName(err)});
        try results_list.append(self.alloc, .{ .source = stmt_src, .output = msg, .value = .blank });
        return EvalResult{ .results = try results_list.toOwnedSlice(self.alloc), .is_error = true, .vm_alloc = self.vm.alloc };
      };

      if (is_suppressed) {
        res.deinit(self.vm.alloc);
        res = .blank;
      }

      var mock_out = try MockWriter.init(self.alloc);
      defer mock_out.deinit();
      var t_fmt = TerseFormatter.init(self.vm, self.alloc, .Repl);
      t_fmt.pretty = pretty;
      var mw_out = mock_out.writer();
      if (!is_suppressed) {
        t_fmt.formatter().fmt(res, &mw_out.interface) catch {};
      }

      var result_text = mock_out.getText();
      while (result_text.len > 0 and std.ascii.isWhitespace(result_text[result_text.len - 1])) {
        result_text = result_text[0 .. result_text.len - 1];
      }

      try results_list.append(self.alloc, .{
        .source = stmt_src,
        .output = try self.alloc.dupe(u8, result_text),
        .value = res,
      });
    }

    // Emit any trailing line comments after the last stmt.
    try emitGapComments(self.alloc, source[prev_src_end..], &results_list);

    return .{
      .results = try results_list.toOwnedSlice(self.alloc),
      .is_error = false,
      .vm_alloc = self.vm.alloc,
    };
  }

  /// Evaluates source statement-by-statement, printing each non-blank result
  /// immediately to writer (interleaved with io verb side effects).
  /// Returns true if an error occurred.
  pub fn evalStream(self: *Repl, source: []const u8, writer: *std.Io.Writer) !bool {
    if (source.len == 0) return false;
  
    const node = self.vm.parser.?.parse(source) catch |err| {
      writer.print("!parse_error: {s}\n", .{@errorName(err)}) catch {};
      writer.flush() catch {};
      return true;
    };
    if (node.* != .terse) { self.vm.parser.?.free(node); return false; }
  
    const StmtInfo = struct { is_blank: bool, source: []const u8 };
    const stmt_infos = try self.alloc.alloc(StmtInfo, node.terse.stmts.len);
    defer self.alloc.free(stmt_infos);
    for (node.terse.stmts, 0..) |s, j| {
      stmt_infos[j] = .{ .is_blank = s.node.* == .blank, .source = s.source };
    }
    self.vm.parser.?.free(node);
  
    var i: usize = 0;
    while (i < stmt_infos.len) {
      const stmt = stmt_infos[i];
      i += 1;
      if (stmt.is_blank) continue;
  
      var is_suppressed = false;
      var full_stmt_src = try std.ArrayList(u8).initCapacity(self.alloc, stmt.source.len + 1);
      defer full_stmt_src.deinit(self.alloc);
      try full_stmt_src.appendSlice(self.alloc, stmt.source);
  
      if (i < stmt_infos.len and stmt_infos[i].is_blank and
          std.mem.eql(u8, stmt_infos[i].source, ";")) {
        try full_stmt_src.append(self.alloc, ';');
        i += 1;
        is_suppressed = true;
      }
  
      var res = self.vm.eval(full_stmt_src.items) catch |err| {
        writer.print("!{s}\n", .{@errorName(err)}) catch {};
        writer.flush() catch {};
        return true;
      };
      defer res.deinit(self.vm.alloc);
  
      if (!is_suppressed) {
        var mock_out = try MockWriter.init(self.alloc);
        defer mock_out.deinit();
        var t_fmt = TerseFormatter.init(self.vm, self.alloc, .Repl);
        var mw_out = mock_out.writer();
        t_fmt.formatter().fmt(res, &mw_out.interface) catch {};

        var result_text = mock_out.getText();
        while (result_text.len > 0 and std.ascii.isWhitespace(result_text[result_text.len - 1])) {
          result_text = result_text[0 .. result_text.len - 1];
        }
  
        if (result_text.len > 0) {
          writer.print("{s}\n", .{result_text}) catch {};
          writer.flush() catch {};
        }
      }
    }
    return false;
  }
};

/// Scan a raw source gap (between two stmts or at the start/end) and emit any
/// line comments found there as blank pass-through results.
fn emitGapComments(alloc: std.mem.Allocator, gap: []const u8, results_list: *std.ArrayList(Repl.Result)) !void {
  var lines = std.mem.splitScalar(u8, gap, '\n');
  while (lines.next()) |line| {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len > 0 and trimmed[0] == '/') {
      try results_list.append(alloc, .{
        .source = try alloc.dupe(u8, trimmed),
        .output = try alloc.dupe(u8, ""),
        .value = .blank,
      });
    }
  }
}
