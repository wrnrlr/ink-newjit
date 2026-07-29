const std = @import("std");
const MockWriter = @import("../util.zig").MockWriter;
const TerseFormatter = @import("../noun/format.zig").TerseFormatter;
const VM = @import("vm.zig").VM;
const V = @import("../noun/value.zig").V;
const verb_io = @import("../primitive/verb/io.zig");

pub fn exec(vm: *VM, verb: []const u8, n: u32, args: []const u8) !V {
  const io = std.Io.Threaded.global_single_threaded.io();
  if (std.mem.eql(u8, verb, "p")) {
    const port_str = std.mem.trim(u8, args, " \t");
    if (port_str.len == 0) return .blank;
    const port = std.fmt.parseInt(u16, port_str, 10) catch return V{ .err = .domain };
    const h = verb_io.netListenOnly(vm, port);
    if (h.tag() == .err) return h;
    vm.listen_handle = @intCast(h.i);
    return .blank;
  } else if (std.mem.eql(u8, verb, "h")) {
    std.debug.print("{s}\n", .{"TODO"});
    return .blank;
  } else if (std.mem.eql(u8, verb, "l")) {
    _ = try vm.load(args);
    return .blank;
  } else if (std.mem.eql(u8, verb, "v")) {
    var it_v = vm.names.iterator();
    while (it_v.next()) |entry| {
      const name = entry.key_ptr.*;
      const idx = entry.value_ptr.*;
      {
        const val = vm.globals[idx];
        if (val != .blank) {
          var mw = try MockWriter.init(vm.alloc);
          defer mw.deinit();
          var w = mw.writer();
          var fmt = TerseFormatter.init(vm, vm.alloc, .Text);
          fmt.formatter().fmt(val, &w.interface) catch {};
          std.debug.print("{s}: {s}\n", .{ name, mw.getText() });
        }
      }
    }
    return .blank;
  } else if (std.mem.eql(u8, verb, "f")) {
    var it_f = vm.names.iterator();
    while (it_f.next()) |entry| {
      const name = entry.key_ptr.*;
      const idx = entry.value_ptr.*;
      if (vm.globals[idx].isLambda()) {
        std.debug.print("{s}\n", .{name});
      }
    }
    return .blank;
  } else if (std.mem.eql(u8, verb, "cd")) {
    const dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, args, .{});
    try std.process.setCurrentDir(io, dir);
    return .blank;
  } else if (std.mem.eql(u8, verb, "d")) {
    std.debug.print("\\d {s}\n", .{args});
    return .blank;
  } else if (std.mem.eql(u8, verb, "e")) {
    // `\e a b c` — export bare names for autoload.  Consumed by the module
    // indexer (cmd/modules.zig scanText) at scan time; no runtime effect.
    return .blank;
  } else if (std.mem.eql(u8, verb, "t")) {
    if (args.len == 0) return .blank;
    const count = if (n == 0) 1 else n;
    // Compile the expression once, then time only its repeated execution —
    // re-parsing/compiling each iteration would dominate the measurement.
    const start_ip = try vm.compileOnce(args);
    const start = std.Io.Clock.awake.now(io);
    for (0..@as(usize, count)) |_| {
      var r = try vm.runFrom(start_ip);
      r.deinit(vm.alloc);
    }
    const end = std.Io.Clock.awake.now(io);
    const elapsed_ns = end.nanoseconds - start.nanoseconds;
    const elapsed_ms: i32 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
    return V{ .i = elapsed_ms };
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
    return .blank;
  }
}
