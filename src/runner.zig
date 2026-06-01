const std = @import("std");
const builtin = @import("builtin");
const VM = @import("runtime/vm.zig").VM;
const Repl = @import("repl.zig").Repl;
const disasm = @import("runtime/disasm.zig");

const build_options = @import("build_options");

const V = @import("noun/value.zig").V;
const K = @import("noun/class.zig").K;
const N = @import("noun/array.zig").N;

// ── REPL / stdin eval ─────────────────────────────────────────────────────────

fn runRepl(allocator: std.mem.Allocator, vm: *VM) !void {
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

fn evalStdin(allocator: std.mem.Allocator, vm: *VM) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  var read_buf: [4096]u8 = undefined;
  var reader = std.Io.File.stdin().reader(io, &read_buf);
  var content_list: std.ArrayList(u8) = .empty;
  defer content_list.deinit(allocator);
  try reader.interface.appendRemainingUnlimited(allocator, &content_list);
  const content = content_list.items;
  var stdout_buf: [4096]u8 = undefined;
  var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
  vm.out = &stdout_writer.interface;
  var repl = Repl.init(allocator, vm);
  _ = try repl.evalStream(std.mem.trim(u8, content, " \t\r\n"), &stdout_writer.interface);
}

// ── main ─────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init.Minimal) !void {
  var gpa = std.heap.DebugAllocator(.{}){};
  defer { if (builtin.mode == .Debug) _ = gpa.deinit(); }
  const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

  var args_iter = try init.args.iterateAllocator(allocator);
  defer args_iter.deinit();
  const exe_name = args_iter.next() orelse "";

  var disasm_mode = false;
  var gpu_flag    = false;
  var script_path: ?[]const u8 = null;
  var extra_args: std.ArrayList([]const u8) = .empty;
  defer extra_args.deinit(allocator);
  while (args_iter.next()) |arg| {
    if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--disasm")) {
      disasm_mode = true;
    } else if (std.mem.eql(u8, arg, "--gpu")) {
      gpu_flag = true;
    } else if (script_path == null) {
      script_path = arg;
    } else {
      try extra_args.append(allocator, arg);
    }
  }

  const io = std.Io.Threaded.global_single_threaded.io();
  const stdin_is_tty = (std.Io.File.stdin().isTty(io) catch false);

  // Create VM once; GPU backend (if requested) is attached before any eval.
  const vm = try VM.create(allocator);
  defer vm.deinit();

  // Disassemble mode: compile without running, print bytecode, exit.
  if (disasm_mode and script_path != null) {
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

  if (gpu_flag) {
    std.debug.print("warning: --gpu flag ignored (GPU support is disabled in this build)\n", .{});
  }

  // Build argv = [exe_name, script_path?, ...extra_args]
  {
    var parts: usize = 1; // exe always included
    if (script_path != null) parts += 1;
    parts += extra_args.items.len;
    const argv_n = try N(V).init(vm.alloc, parts);
    errdefer (V{ .L = argv_n }).deinit(vm.alloc);
    @memset(argv_n.slice(), .blank);
    var i: usize = 0;
    argv_n.slice()[i] = try V.Chars(vm.alloc, exe_name); i += 1;
    if (script_path) |sp| { argv_n.slice()[i] = try V.Chars(vm.alloc, sp); i += 1; }
    for (extra_args.items) |arg| { argv_n.slice()[i] = try V.Chars(vm.alloc, arg); i += 1; }
    vm.argv = V{ .L = argv_n };
  }
  // Register 'x' global with extra_args only (user-provided script arguments)
  if (extra_args.items.len > 0) {
    const n = extra_args.items.len;
    const x_n = try N(V).init(vm.alloc, n);
    errdefer (V{ .L = x_n }).deinit(vm.alloc);
    @memset(x_n.slice(), .blank);
    for (extra_args.items, x_n.slice()) |arg, *slot| {
      slot.* = try V.Chars(vm.alloc, arg);
    }
    const key = try vm.alloc.dupe(u8, "x");
    errdefer vm.alloc.free(key);
    const idx: u8 = @intCast(vm.globals_names.count());
    try vm.globals_names.put(key, idx);
    vm.globals[idx].deinit(vm.alloc);
    vm.globals[idx] = V{ .L = x_n };
  }

  if (script_path == null and stdin_is_tty) return runRepl(allocator, vm);
  if (script_path == null) return evalStdin(allocator, vm);

  var stdout_buf: [4096]u8 = undefined;
  var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
  vm.out = &stdout_writer.interface;

  // Read the file and evaluate statement-by-statement so that:
  // - each non-blank, non-suppressed result is printed to stdout
  // - commands like \t that internally call vm.eval don't break subsequent statements
  const text = std.Io.Dir.cwd().readFileAlloc(io, script_path.?, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
    std.debug.print("error loading {s}: {}\n", .{ script_path.?, err });
    std.process.exit(1);
  };
  defer allocator.free(text);

  var repl = Repl.init(allocator, vm);
  _ = repl.evalStream(std.mem.trim(u8, text, " \t\r\n"), &stdout_writer.interface) catch |err| {
    std.debug.print("error in {s}: {}\n", .{ script_path.?, err });
    std.process.exit(1);
  };

  // Find 'loop' global — if absent, file was already evaluated; exit cleanly
  const loop_idx = vm.globals_names.get("loop") orelse return;
  if (!vm.globals[loop_idx].isLambda()) return;
  // UI runner removed in Phase-0 GPU strip; the loop lambda is parsed but not
  // invoked. When the graphics stack is restored, dispatch back to runner_ui.
  _ = vm.globals[loop_idx];
}
