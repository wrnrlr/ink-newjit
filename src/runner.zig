const std = @import("std");
const VM = @import("runtime/vm.zig").VM;
const Repl = @import("repl.zig").Repl;
const value = @import("noun/value.zig");
const disasm = @import("runtime/disasm.zig");

const build_options = @import("build_options");
const enable_ui  = build_options.enable_ui;
const enable_gpu = build_options.enable_gpu;
const gpu_compute = if (enable_gpu) @import("gpu_compute") else void;

const V = value.V;
const K = @import("noun/class.zig").K;

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

  // Attach GPU compute backend when --gpu flag is present and the binary
  // was compiled with -Dgpu=true (or -Dui=true which implies GPU support).
  // The comptime branches ensure dead GPU code is never type-checked in
  // non-GPU builds (gpu_compute == void when enable_gpu == false).
  const GpuBackendT = comptime if (enable_gpu) *gpu_compute.WgpuBackend else void;
  var gpu_backend: ?GpuBackendT = null;
  if (comptime enable_gpu) {
    if (gpu_flag) {
      if (gpu_compute.WgpuBackend.create(allocator)) |b| {
        gpu_backend = b;
        vm.gpu = &b.ctx;
      } else |err| {
        std.debug.print("warning: GPU backend unavailable ({s}), running on CPU\n",
          .{@errorName(err)});
      }
    }
  }
  defer if (comptime enable_gpu) {
    if (gpu_backend) |b| b.destroy();
  };

  // Build argv list and pre-register global x before loading any script.
  if (extra_args.items.len > 0) {
    const n = extra_args.items.len;
    const argv_items_n = try value.N(V).init(allocator, n);
    errdefer (V{ .L = argv_items_n }).deinit(allocator);
    @memset(argv_items_n.slice(), .blank);
    for (extra_args.items, argv_items_n.slice()) |arg, *slot| {
      slot.* = try V.charsFromSlice(allocator, arg);
    }
    vm.argv = V{ .L = argv_items_n };
    const key = try vm.alloc.dupe(u8, "x");
    errdefer vm.alloc.free(key);
    const idx: u8 = @intCast(vm.globals.items.len);
    try vm.globals_names.put(key, idx);
    try vm.globals.append(vm.alloc, vm.argv.ref());
  }

  if (script_path == null and stdin_is_tty) return runRepl(allocator, vm);
  if (script_path == null) return evalStdin(allocator, vm);

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
