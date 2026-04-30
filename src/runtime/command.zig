const std = @import("std");
const MockWriter = @import("../util.zig").MockWriter;
const TerseFormatter = @import("../noun/format.zig").TerseFormatter;
const VM = @import("vm.zig").VM;

const Cmd = union {
  h: void,        // show help
  v: void,        // show variables
  f: void,        // show functions
  cd: []const u8, // change directory
  d: ?[]const u8, // set namespace
  l: []const u8,  // load namespace
  t: ?[]const u8, // time expression
  
};

pub fn exec(vm: *VM, verb: []const u8, args: []const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  if (std.mem.eql(u8, verb, "h")) {
    std.debug.print("{s}\n", .{"TODO"});
  } else if (std.mem.eql(u8, verb, "l")) {
    _ = try vm.load(args);
  } else if (std.mem.eql(u8, verb, "v")) {
    var it_v = vm.globals_names.iterator();
    while (it_v.next()) |entry| {
      const name = entry.key_ptr.*;
      const idx = entry.value_ptr.*;
      if (idx < vm.globals.items.len) {
        const val = vm.globals.items[idx];
        if (val != .blank) {
          var mw = try MockWriter.init(vm.alloc);
          defer mw.deinit();
          var w = mw.writer();
          var fmt = TerseFormatter.init(vm, vm.alloc, .Text);
          fmt.formatter().format(val, &w.interface) catch {};
          std.debug.print("{s}: {s}\n", .{ name, mw.getText() });
        }
      }
    }
  } else if (std.mem.eql(u8, verb, "f")) {
    var it_f = vm.globals_names.iterator();
    while (it_f.next()) |entry| {
      const name = entry.key_ptr.*;
      const idx = entry.value_ptr.*;
      if (idx < vm.globals.items.len and vm.globals.items[idx].isLambda()) {
        std.debug.print("{s}\n", .{name});
      }
    }
  } else if (std.mem.eql(u8, verb, "cd")) {
    const dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, args, .{});
    try std.process.setCurrentDir(io, dir);
  } else if (std.mem.eql(u8, verb, "d")) {
    std.debug.print("\\d {s}\n", .{args});
  } else if (std.mem.eql(u8, verb, "t")) {
    std.debug.print("\\t NYI\n", .{});
  } else {
    // Pass to shell
    const full_cmd = if (args.len > 0)
      try std.fmt.allocPrint(vm.alloc, "{s} {s}", .{ verb, args })
    else
      try vm.alloc.dupe(u8, verb);
    defer vm.alloc.free(full_cmd);
    const result = try std.process.run(vm.alloc, io, .{ .argv = &.{ "sh", "-c", full_cmd } });
    defer vm.alloc.free(result.stdout);
    defer vm.alloc.free(result.stderr);
    if (result.stdout.len > 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
  }
}
