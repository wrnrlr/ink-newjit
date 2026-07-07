// `ink parse [-r] [-t] [file.k]` — parse a script (or stdin) and print its CST.
// Default: a tree-sitter-style S-expression tree (for humans / LLM agents).
//   -r, --ranges   annotate every node with its [row, col] source span
//   -t, --table    print the raw column table (the apter-tree serialization)
const std = @import("std");
const VM = @import("../runtime/vm.zig").VM;
const parse = @import("../primitive/verb/parse.zig");
const TerseFormatter = @import("../noun/format.zig").TerseFormatter;

pub fn run(vm: *VM, args: []const []const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  const alloc = vm.alloc;

  var ranges = false;
  var table = false;
  var file: ?[]const u8 = null;
  for (args) |a| {
    if (std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--ranges")) ranges = true
    else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--table")) table = true
    else file = a;
  }

  const src: []const u8 = if (file) |f|
    std.Io.Dir.cwd().readFileAlloc(io, f, alloc, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
      std.debug.print("error loading {s}: {}\n", .{ f, err });
      std.process.exit(1);
    }
  else blk: {
    var read_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &read_buf);
    var list: std.ArrayList(u8) = .empty;
    try reader.interface.appendRemainingUnlimited(alloc, &list);
    break :blk try list.toOwnedSlice(alloc);
  };
  defer alloc.free(src);
  const trimmed = std.mem.trim(u8, src, " \t\r\n");

  var buf: [4096]u8 = undefined;
  var w = std.Io.File.stdout().writer(io, &buf);

  if (table) {
    var t = parse.tableFromSource(vm, trimmed);
    defer t.deinit(alloc);
    var fmt = TerseFormatter.init(vm, alloc, .Repl);
    fmt.pretty = true;
    try fmt.formatter().fmt(t, &w.interface);
    try w.interface.writeAll("\n");
  } else {
    try parse.sexprFromSource(vm, trimmed, &w.interface, ranges);
  }
  try w.interface.flush();
}
