const std = @import("std");
const builtin = @import("builtin");
const VM = @import("../runtime/vm.zig").VM;
const Repl = @import("repl.zig").Repl;
const serve = @import("../runtime/serve.zig");
const ffi = @import("../ffi.zig");
const home = @import("../home.zig");
const modules = @import("modules.zig");
const lsp = @import("lsp.zig");
const jupyter = @import("jupyter.zig");
const help = @import("help.zig");
const disasm = @import("disasm.zig");
const cmdparse = @import("parse.zig");
const bundle = @import("bundle.zig");
const Lexer = @import("../parser/lexer.zig").Lexer;

/// Called by C extensions (e.g. GPU) to process pending IPC messages from
/// within their own event loop.  No-ops when current_vm is not set.
export fn terse_poll() callconv(.c) void {
  const vm_ptr = ffi.getCurrentVm() orelse return;
  serve.pollOnce(@ptrCast(@alignCast(vm_ptr)), .blank);
}

const build_options = @import("build_options");

// Zig 0.16's std no longer exposes setenv/getenv; call libc directly.  These
// env vars are only read by the (macOS-only) GPU extension, and mingw libc has
// no setenv, so setting them is a no-op on Windows.
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setEnvConst(name: [*:0]const u8, value: [*:0]const u8) void {
  if (builtin.os.tag != .windows) _ = setenv(name, value, 1);
}

// setenv() with a non-sentinel-terminated value (args aren't null-terminated).
// setenv copies its arguments, so the temporary dup can be freed immediately.
fn setEnvZ(allocator: std.mem.Allocator, name: [*:0]const u8, value: []const u8) void {
  if (builtin.os.tag != .windows) {
    const z = allocator.dupeZ(u8, value) catch return;
    defer allocator.free(z);
    _ = setenv(name, z, 1);
  }
}

// True if `s` is a comma/dot-separated list of numbers (a `-snap` time list),
// so we can tell `-snap 0.5,2` from `-snap script.k`.
fn looksLikeTimes(s: []const u8) bool {
  if (s.len == 0) return false;
  var has_digit = false;
  for (s) |c| {
    if (c >= '0' and c <= '9') has_digit = true
    else if (c != '.' and c != ',') return false;
  }
  return has_digit;
}

// Basename with its extension removed: `test/eyes.k` → `eyes`. The directory is
// dropped so snapshots are written into the CWD, not next to the script.
fn snapBase(p: []const u8) []const u8 {
  const start = if (std.mem.lastIndexOfScalar(u8, p, '/')) |s| s + 1 else 0;
  const name = p[start..];
  const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
  if (dot == 0) return name; // dotfile like ".foo" — keep whole name
  return name[0..dot];
}

const V = @import("../noun/value.zig").V;
const K = @import("../noun/class.zig").K;
const N = @import("../noun/array.zig").N;

// Read one physical line (up to '\n') from fd, appending its bytes (without the
// newline) to buf. Returns false on EOF when nothing was read on this line.
fn readPhysicalLine(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !bool {
  const io = std.Io.Threaded.global_single_threaded.io();
  var byte: [1]u8 = undefined;
  var any = false;
  while (true) {
    const n = std.Io.File.stdin().readStreaming(io, &.{byte[0..]}) catch |err| {
      if (err == error.EndOfStream) return any;
      return err;
    };
    if (n == 0) return any; // EOF
    any = true;
    if (byte[0] == '\n') return true;
    try buf.append(allocator, byte[0]);
  }
}

fn runRepl(allocator: std.mem.Allocator, vm: *VM, loader: *modules.ModuleLoader) !void {
  var repl = Repl.init(allocator, vm);
  var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
  defer buf.deinit(allocator);
  while (true) {
    std.debug.print("  ", .{});
    buf.clearRetainingCapacity();
    // Read a logical input, spanning multiple physical lines while an
    // unterminated multi-line string keeps the buffer open.
    var eof = false;
    while (true) {
      if (!try readPhysicalLine(allocator, &buf)) { eof = true; break; }
      try buf.append(allocator, '\n');
      if (!Lexer.endsOpenString(buf.items)) break;
      std.debug.print("  ", .{}); // continuation prompt
    }
    // A leading space/tab on the entry requests the raw k literal instead of
    // the pretty multi-line dict/table rendering.
    const lead_ws = buf.items.len > 0 and (buf.items[0] == ' ' or buf.items[0] == '\t');
    const line = std.mem.trim(u8, buf.items, " \t\r\n");
    if (eof and line.len == 0) return;
    if (std.mem.eql(u8, line, "\\q") or std.mem.eql(u8, line, "exit")) break;
    if (line.len > 0) {
      loader.autoLoad(vm, line) catch {};
      if (repl.eval(line, !lead_ws)) |res| {
        defer res.deinit(allocator);
        for (res.results) |r| {
          if (r.output.len > 0) std.debug.print("{s}\n", .{r.output});
        }
      } else |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
      }
    }
    if (eof) return;
  }
}

fn evalStdin(allocator: std.mem.Allocator, vm: *VM, loader: *modules.ModuleLoader) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  var read_buf: [4096]u8 = undefined;
  var reader = std.Io.File.stdin().reader(io, &read_buf);
  var content_list: std.ArrayList(u8) = .empty;
  defer content_list.deinit(allocator);
  try reader.interface.appendRemainingUnlimited(allocator, &content_list);
  const content = content_list.items;
  const trimmed = std.mem.trim(u8, content, " \t\r\n");
  loader.autoLoad(vm, trimmed) catch {};
  var stdout_buf: [4096]u8 = undefined;
  var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
  vm.out = &stdout_writer.interface;
  var repl = Repl.init(allocator, vm);
  _ = try repl.evalStream(trimmed, &stdout_writer.interface);
}

// Scan both the working-directory lib (dev tree) and $INK_HOME/lib (installed)
// so module auto-loading finds k libraries regardless of where ink runs from.
fn scanLibDirs(loader: *modules.ModuleLoader) void {
  loader.scan("lib") catch {};
  var hbuf: [512]u8 = undefined;
  if (home.dir(&hbuf)) |hdir| {
    var pbuf: [640]u8 = undefined;
    const lib = std.fmt.bufPrint(&pbuf, "{s}/lib", .{hdir}) catch return;
    loader.scan(lib) catch {};
  }
}

// Populate vm.argv = [exe, script?, extra...] and the `x` global (= extra args).
fn setupArgs(vm: *VM, exe_name: []const u8, script_path: ?[]const u8, extra_args: []const []const u8) !void {
  var parts: usize = 1; // exe always included
  if (script_path != null) parts += 1;
  parts += extra_args.len;
  const argv_n = try N(V).init(vm.alloc, parts);
  errdefer (V{ .L = argv_n }).deinit(vm.alloc);
  @memset(argv_n.slice(), .blank);
  var i: usize = 0;
  argv_n.slice()[i] = try V.Chars(vm.alloc, exe_name); i += 1;
  if (script_path) |sp| { argv_n.slice()[i] = try V.Chars(vm.alloc, sp); i += 1; }
  for (extra_args) |arg| { argv_n.slice()[i] = try V.Chars(vm.alloc, arg); i += 1; }
  vm.argv = V{ .L = argv_n };

  // Register 'x' global with extra_args only (user-provided script arguments).
  if (extra_args.len > 0) {
    const x_n = try N(V).init(vm.alloc, extra_args.len);
    errdefer (V{ .L = x_n }).deinit(vm.alloc);
    @memset(x_n.slice(), .blank);
    for (extra_args, x_n.slice()) |arg, *slot| slot.* = try V.Chars(vm.alloc, arg);
    const key = try vm.alloc.dupe(u8, "x");
    errdefer vm.alloc.free(key);
    const idx: u8 = @intCast(vm.names.count());
    try vm.names.put(key, idx);
    vm.globals[idx].deinit(vm.alloc);
    vm.globals[idx] = V{ .L = x_n };
  }
}

// Evaluate program source statement-by-statement, printing each non-blank
// result to stdout, then serve forever if the script opened a listening port.
fn evalSource(allocator: std.mem.Allocator, vm: *VM, loader: *modules.ModuleLoader, source: []const u8, label: []const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  var stdout_buf: [4096]u8 = undefined;
  var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
  vm.out = &stdout_writer.interface;

  const trimmed = std.mem.trim(u8, source, " \t\r\n");
  loader.autoLoad(vm, trimmed) catch {};
  var repl = Repl.init(allocator, vm);
  _ = repl.evalStream(trimmed, &stdout_writer.interface) catch |err| {
    std.debug.print("error in {s}: {}\n", .{ label, err });
    std.process.exit(1);
  };

  // If the script set \p port, enter the event loop and serve forever.
  if (vm.listen_handle != null) {
    ffi.setCurrentVm(vm);
    serve.runLoop(vm);
  }
}

// Entry point for a statically-linked bundle (called via corelib's C-ABI
// `ink_run_bundle`).  `inits` are the linked extensions' ink_ext_init_<name>
// functions; calling each registers its functions by name into the FFI registry
// (so `2:(`Name;…)` resolves with no dlopen).  `archive` is the embedded
// script+modules blob produced by `ink bundle`.
pub fn runBundle(archive: []const u8, inits: []const ?*const fn (*anyopaque) callconv(.c) void) c_int {
  const allocator = std.heap.c_allocator;
  for (inits) |maybe| if (maybe) |init_fn| init_fn(ffi.registryPtr());

  const owned = allocator.dupe(u8, archive) catch return 1;
  var b = bundle.decode(allocator, owned) catch return 1; // decode frees `owned` on error
  defer b.deinit(allocator);

  var vfs = std.StringHashMap([]const u8).init(allocator);
  defer vfs.deinit();
  for (b.paths, b.data) |p, d| vfs.put(p, d) catch return 1;

  const vm = VM.create(allocator) catch return 1;
  defer vm.deinit();
  vm.vfs = &vfs;
  var loader = modules.ModuleLoader.init(allocator);
  defer loader.deinit();
  for (b.paths, b.data) |p, d| loader.scanText(p, d) catch {};
  setupArgs(vm, "ink", null, &[_][]const u8{}) catch return 1;
  evalSource(allocator, vm, &loader, b.main, "bundle") catch return 1;
  return 0;
}

pub fn main(init: std.process.Init.Minimal) !void {
  var gpa = std.heap.DebugAllocator(.{}){};
  defer { if (builtin.mode == .Debug) _ = gpa.deinit(); }
  const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

  var args_iter = try init.args.iterateAllocator(allocator);
  defer args_iter.deinit();
  const exe_name = args_iter.next() orelse "";

  // A bundled executable (script + its modules appended to the ink binary by
  // `ink bundle`) runs its embedded program directly; further argv passes
  // through as `x`.  Embedded modules are exposed via the VM's file overlay and
  // the autoload index, so both `2:"…k"` and identifier autoloads resolve from
  // the bundle with no filesystem dependency.
  if (try bundle.embedded(allocator)) |bndl| {
    var b = bndl;
    defer b.deinit(allocator);
    var sargs: std.ArrayList([]const u8) = .empty;
    defer sargs.deinit(allocator);
    while (args_iter.next()) |a| try sargs.append(allocator, a);

    var vfs = std.StringHashMap([]const u8).init(allocator);
    defer vfs.deinit();
    for (b.paths, b.data) |p, d| try vfs.put(p, d);

    const vm = try VM.create(allocator);
    defer vm.deinit();
    vm.vfs = &vfs;
    var loader = modules.ModuleLoader.init(allocator);
    defer loader.deinit();
    for (b.paths, b.data) |p, d| loader.scanText(p, d) catch {};
    try setupArgs(vm, exe_name, null, sargs.items);
    return evalSource(allocator, vm, &loader, b.main, exe_name);
  }

  var script_path: ?[]const u8 = null;
  var extra_args: std.ArrayList([]const u8) = .empty;
  defer extra_args.deinit(allocator);
  var pushback: ?[]const u8 = null; // one-arg lookahead (for -snap's optional time list)
  while (true) {
    const arg = if (pushback) |p| blk: { pushback = null; break :blk p; } else (args_iter.next() orelse break);
    if (std.mem.eql(u8, arg, "-unfocus")) {
      // GPU window opens without grabbing keyboard focus.
      setEnvConst("INK_UNFOCUS", "1");
    } else if (std.mem.eql(u8, arg, "-top")) {
      // GPU window stays above all others (always-on-top).
      setEnvConst("INK_TOP", "1");
    } else if (std.mem.eql(u8, arg, "-monitor")) {
      // `-monitor N` places the GPU window on monitor N (0-based).
      if (args_iter.next()) |v| setEnvZ(allocator, "INK_MONITOR", v);
    } else if (std.mem.eql(u8, arg, "-size")) {
      // `-size WxH` sets the GPU window size (e.g. -size 1280x720).
      if (args_iter.next()) |v| setEnvZ(allocator, "INK_SIZE", v);
    } else if (std.mem.eql(u8, arg, "-snap")) {
      // `-snap [t0,t1,...]` captures PNG screenshots headlessly at the given
      // sim-times (seconds); bare `-snap` shoots once on the first frame and
      // exits.  The optional time list, if present, is the next argument.
      if (args_iter.next()) |v| {
        if (looksLikeTimes(v)) setEnvZ(allocator, "INK_SNAP", v)
        else { setEnvConst("INK_SNAP", "0"); pushback = v; }
      } else setEnvConst("INK_SNAP", "0");
    } else if (script_path == null) {
      script_path = arg;
    } else {
      try extra_args.append(allocator, arg);
    }
  }

  // Snapshot filenames are `<script-basename>-snap-<epoch-ms>.png` in the CWD.
  if (script_path) |sp| setEnvZ(allocator, "INK_SNAP_BASE", snapBase(sp));

  // `ink help` / `ink -h` / `ink --help` — print usage and exit.  No VM needed.
  if (script_path) |sp| if (std.mem.eql(u8, sp, "help") or
      std.mem.eql(u8, sp, "-h") or std.mem.eql(u8, sp, "--help")) return help.run(allocator);

  // `ink version` / `ink --version` — print the release version.
  if (script_path) |sp| if (std.mem.eql(u8, sp, "version") or
      std.mem.eql(u8, sp, "--version") or std.mem.eql(u8, sp, "-v")) {
    std.debug.print("ink {s}\n", .{build_options.version});
    return;
  };

  // `ink bundle <script.k> [-o out] [-t platform]` — ship a k script as a
  // single self-contained executable.  No VM needed.
  if (script_path) |sp| if (std.mem.eql(u8, sp, "bundle")) return bundle.run(allocator, extra_args.items);

  // `ink lsp` — run the language server over stdio (JSON-RPC).  No VM needed.
  if (script_path) |sp| if (std.mem.eql(u8, sp, "lsp")) return lsp.run(allocator);

  // `ink jupyter -f <connection-file>` — run a Jupyter kernel over ZeroMQ.
  // `ink jupyter install` — write a kernelspec so editors can discover it.
  // The kernel uses posix poll(2)/sockets, unavailable in Windows' std, so the
  // whole jupyter module is left uncompiled there (comptime-dead branch).
  if (script_path) |sp| if (std.mem.eql(u8, sp, "jupyter")) {
    if (builtin.os.tag != .windows) {
      for (extra_args.items) |a| if (std.mem.eql(u8, a, "install")) return jupyter.install(allocator);
      var conn: ?[]const u8 = null;
      for (extra_args.items) |a| if (!std.mem.eql(u8, a, "-f")) { conn = a; break; };
      return jupyter.run(allocator, conn orelse {
        std.debug.print("usage: ink jupyter -f <connection-file> | ink jupyter install\n", .{});
        std.process.exit(1);
      });
    }
    std.debug.print("ink jupyter is not supported on Windows\n", .{});
    std.process.exit(1);
  };

  const io = std.Io.Threaded.global_single_threaded.io();
  const stdin_is_tty = (std.Io.File.stdin().isTty(io) catch false);

  const vm = try VM.create(allocator);
  defer vm.deinit();

  var loader = modules.ModuleLoader.init(allocator);
  defer loader.deinit();
  scanLibDirs(&loader);

  // `ink disasm <script.k>` — compile without running, print bytecode, exit.
  if (script_path) |sp| if (std.mem.eql(u8, sp, "disasm")) {
    const file = if (extra_args.items.len > 0) extra_args.items[0] else {
      std.debug.print("usage: ink disasm <script.k>\n", .{});
      std.process.exit(1);
    };
    return disasm.run(vm, file);
  };

  // `ink parse [script.k]` — parse the file (or stdin) and print the CST table.
  if (script_path) |sp| if (std.mem.eql(u8, sp, "parse")) {
    const file: ?[]const u8 = if (extra_args.items.len > 0) extra_args.items[0] else null;
    return cmdparse.run(vm, file);
  };

  if (script_path == null and stdin_is_tty) return runRepl(allocator, vm, &loader);
  if (script_path == null) return evalStdin(allocator, vm, &loader);

  try setupArgs(vm, exe_name, script_path, extra_args.items);

  // Read the script and evaluate it statement-by-statement.
  const text = std.Io.Dir.cwd().readFileAlloc(io, script_path.?, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
    std.debug.print("error loading {s}: {}\n", .{ script_path.?, err });
    std.process.exit(1);
  };
  defer allocator.free(text);

  return evalSource(allocator, vm, &loader, text, script_path.?);
}
