const std = @import("std");
const VM = @import("runtime/vm.zig").VM;
const Repl = @import("repl.zig").Repl;
const value = @import("noun/value.zig");
const disasm = @import("runtime/disasm.zig");

const build_options = @import("build_options");
const enable_ui = build_options.enable_ui;

const V = value.V;
const K = @import("noun/class.zig").K;

// ── REPL / stdin eval ─────────────────────────────────────────────────────────

fn runRepl(allocator: std.mem.Allocator) !void {
  const vm = try VM.create(allocator);
  defer vm.deinit();
  var repl = Repl.init(allocator, vm);
  var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
  defer buf.deinit(allocator);
  const stdin_fd = std.posix.STDIN_FILENO;
  while (true) {
    std.debug.print("  ", .{});
    buf.clearRetainingCapacity();
    var byte: [1]u8 = undefined;
    while (true) {
      const n = std.posix.read(stdin_fd, &byte) catch |err| {
        if (err == error.Interrupted) continue;
        return err;
      };
      if (n == 0) return;
      if (byte[0] == '\n') break;
      try buf.append(allocator, byte[0]);
    }
    const line = std.mem.trim(u8, buf.items, " \t\r\n");
    if (std.mem.eql(u8, line, "\\q") or std.mem.eql(u8, line, "exit")) break;
    if (line.len > 0) {
      const res = repl.eval(line) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        continue;
      };
      defer res.deinit(allocator);
      for (res.results) |r| {
        if (r.output.len > 0) std.debug.print("{s}\n", .{r.output});
      }
    }
  }
}

fn evalStdin(allocator: std.mem.Allocator) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  var read_buf: [4096]u8 = undefined;
  var reader = std.Io.File.stdin().reader(io, &read_buf);
  var content_list: std.ArrayList(u8) = .empty;
  defer content_list.deinit(allocator);
  try reader.interface.appendRemainingUnlimited(allocator, &content_list);
  const content = content_list.items;
  const vm = try VM.create(allocator);
  defer vm.deinit();
  var repl = Repl.init(allocator, vm);
  const res = try repl.eval(std.mem.trim(u8, content, " \t\r\n"));
  defer res.deinit(allocator);
  for (res.results) |r| {
    if (r.output.len > 0) std.debug.print("{s}\n", .{r.output});
  }
}

// ── main ─────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init.Minimal) !void {
  var gpa = std.heap.DebugAllocator(.{}){};
  defer _ = gpa.deinit();
  const allocator = gpa.allocator();

  var args_iter = try init.args.iterateAllocator(allocator);
  defer args_iter.deinit();
  _ = args_iter.next(); // skip exe name

  var disasm_mode = false;
  var script_path: ?[]const u8 = null;
  while (args_iter.next()) |arg| {
    if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--disasm")) {
      disasm_mode = true;
    } else {
      script_path = arg;
    }
  }

  const io = std.Io.Threaded.global_single_threaded.io();
  const stdin_is_tty = (std.Io.File.stdin().isTty(io) catch false);

  if (script_path == null and stdin_is_tty) return runRepl(allocator);
  if (script_path == null) return evalStdin(allocator);

  // Disassemble mode: compile without running, print bytecode, exit.
  if (disasm_mode) {
    const vm = try VM.create(allocator);
    defer vm.deinit();
    var d = disasm.Disassembler.init(vm.compiler);
    d.compileFile(vm.parser.?, script_path.?) catch |err| {
      std.debug.print("error compiling {s}: {}\n", .{ script_path.?, err });
      std.process.exit(1);
    };
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try d.print(&stdout_writer.interface);
    return;
  }

  // Load VM and script
  const vm = try VM.create(allocator);
  defer vm.deinit();

  var stdout_buf: [4096]u8 = undefined;
  var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
  vm.out = &stdout_writer.interface;

  const script_res = vm.load(script_path.?) catch |err| {
    std.debug.print("error loading {s}: {}\n", .{ script_path.?, err });
    std.process.exit(1);
  };
  script_res.deinit(vm.alloc);

  // Find 'loop' global — if absent, file was already evaluated; exit cleanly
  const loop_idx = vm.globals_names.get("loop") orelse return;
  if (loop_idx >= vm.globals.items.len or !vm.globals.items[loop_idx].isLambda()) return;
  const loop_fn = vm.globals.items[loop_idx];

  if (!enable_ui) {
    std.debug.print("UI support not compiled in (rebuild with -Dui=true)\n", .{});
    return;
  }

  try @import("runner_ui.zig").run(vm, loop_fn, allocator);
}
