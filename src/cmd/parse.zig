// `ink parse [file.k]` — parse a script (or stdin) and print its CST as a
// column table (the apter-tree serialization from parse.zig). Reads stdin when
// no file is given.
const std = @import("std");
const VM = @import("../runtime/vm.zig").VM;
const parse = @import("../primitive/verb/parse.zig");
const TerseFormatter = @import("../noun/format.zig").TerseFormatter;

pub fn run(vm: *VM, file: ?[]const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  const alloc = vm.alloc;

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

  var table = parse.tableFromSource(vm, std.mem.trim(u8, src, " \t\r\n"));
  defer table.deinit(alloc);

  var buf: [4096]u8 = undefined;
  var w = std.Io.File.stdout().writer(io, &buf);
  var fmt = TerseFormatter.init(vm, alloc, .Repl);
  fmt.pretty = true;
  try fmt.formatter().fmt(table, &w.interface);
  try w.interface.writeAll("\n");
  try w.interface.flush();
}
