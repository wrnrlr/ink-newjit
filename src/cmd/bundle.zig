// `ink bundle <script.k> [-o out] [-t platform]` — ship a k script as a single
// self-contained executable.  The script and the lib modules it needs are
// packed into an archive appended to a copy of the ink binary, followed by a
// 16-byte trailer (u64 archive length + 8-byte magic).  When such a binary
// starts, `embedded()` finds the archive and runs the script, resolving module
// loads (`2:"…k"` and autoloaded identifiers) from the embedded files.
//
// Only the modules the script actually depends on are embedded (computed
// transitively at bundle time).  Native extensions (.dylib/.so) are NOT
// embedded — a bundle that uses them still needs the matching shared library at
// runtime (e.g. via an installed ~/.ink).
//
// With `-t <platform>` the base binary is taken from `$INK_HOME/bin/ink-<platform>`,
// so a k program can be cross-bundled for any distributed platform.
const std = @import("std");
const builtin = @import("builtin");
const home = @import("../home.zig");
const modules = @import("modules.zig");

const MAGIC = "INKBNDL2"; // 8 bytes, identifies a bundled archive
const TRAILER = 16;       // u64 little-endian archive length + MAGIC
const MAX_BIN = 256 * 1024 * 1024;
const MAX_K = 10 * 1024 * 1024;

// Path to the running executable.  May be relative; callers open it via cwd().
fn selfExePath(buf: *[4096]u8) ![]const u8 {
  if (builtin.os.tag == .macos) {
    var size: u32 = buf.len;
    if (std.c._NSGetExecutablePath(buf, &size) != 0) return error.PathTooLong;
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
  } else if (builtin.os.tag == .linux) {
    const n = std.c.readlink("/proc/self/exe", buf, buf.len);
    if (n <= 0) return error.NoExePath;
    return buf[0..@intCast(n)];
  }
  return error.Unsupported;
}

/// A decoded bundle: the main script plus its embedded modules (path → content).
pub const Bundle = struct {
  buf: []u8,             // backing allocation; main/paths/data slice into it
  main: []const u8,
  paths: [][]const u8,
  data: [][]const u8,

  pub fn deinit(self: *Bundle, gpa: std.mem.Allocator) void {
    gpa.free(self.paths);
    gpa.free(self.data);
    gpa.free(self.buf);
  }
};

fn readU32(buf: []const u8, off: *usize) ?u32 {
  if (off.* + 4 > buf.len) return null;
  const v = std.mem.readInt(u32, buf[off.*..][0..4], .little);
  off.* += 4;
  return v;
}

fn readSlice(buf: []const u8, off: *usize, len: usize) ?[]const u8 {
  if (off.* + len > buf.len) return null;
  const s = buf[off.*..][0..len];
  off.* += len;
  return s;
}

/// If the running executable carries an appended bundle archive, decode it
/// (caller owns the returned Bundle).  Returns null when there is no archive.
pub fn embedded(gpa: std.mem.Allocator) !?Bundle {
  const io = std.Io.Threaded.global_single_threaded.io();
  var ebuf: [4096]u8 = undefined;
  const exe = selfExePath(&ebuf) catch return null;
  var file = std.Io.Dir.cwd().openFile(io, exe, .{}) catch return null;
  defer file.close(io);
  const st = file.stat(io) catch return null;
  if (st.size < TRAILER) return null;
  var trailer: [TRAILER]u8 = undefined;
  if ((file.readPositionalAll(io, &trailer, st.size - TRAILER) catch return null) < TRAILER) return null;
  if (!std.mem.eql(u8, trailer[8..16], MAGIC)) return null;
  const alen = std.mem.readInt(u64, trailer[0..8], .little);
  if (alen == 0 or alen + TRAILER > st.size) return null;

  const buf = try gpa.alloc(u8, alen);
  errdefer gpa.free(buf);
  if ((file.readPositionalAll(io, buf, st.size - TRAILER - alen) catch return null) < alen) return null;
  return decode(gpa, buf) catch return null;
}

/// Decode an archive buffer (which the Bundle takes ownership of) into its main
/// script + embedded modules.  Layout:
///   [u32 n][u32 main_len][main][n × ([u32 path_len][path][u32 data_len][data])]
/// Shared by `embedded()` (trailer-appended bundles) and the statically-linked
/// `ink_run_bundle` entry (archive @embedFile'd in the generated glue).
pub fn decode(gpa: std.mem.Allocator, buf: []u8) !Bundle {
  errdefer gpa.free(buf);
  var off: usize = 0;
  const n = readU32(buf, &off) orelse return error.BadBundle;
  const main_len = readU32(buf, &off) orelse return error.BadBundle;
  const main = readSlice(buf, &off, main_len) orelse return error.BadBundle;

  const paths = try gpa.alloc([]const u8, n);
  errdefer gpa.free(paths);
  const data = try gpa.alloc([]const u8, n);
  errdefer gpa.free(data);
  var i: usize = 0;
  while (i < n) : (i += 1) {
    const pl = readU32(buf, &off) orelse return error.BadBundle;
    paths[i] = readSlice(buf, &off, pl) orelse return error.BadBundle;
    const dl = readU32(buf, &off) orelse return error.BadBundle;
    data[i] = readSlice(buf, &off, dl) orelse return error.BadBundle;
  }
  return Bundle{ .buf = buf, .main = main, .paths = paths, .data = data };
}

fn usage() noreturn {
  std.debug.print("usage: ink bundle <script.k> [-o <out>] [-t <platform>]\n", .{});
  std.process.exit(1);
}

// Drop directory and a trailing `.k`: `app/main.k` → `main`.
fn scriptStem(path: []const u8) []const u8 {
  const start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
  const name = path[start..];
  if (std.mem.endsWith(u8, name, ".k")) return name[0 .. name.len - 2];
  return name;
}

fn appendU32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
  var b: [4]u8 = undefined;
  std.mem.writeInt(u32, &b, v, .little);
  try list.appendSlice(gpa, &b);
}

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();

  var script: ?[]const u8 = null;
  var out: ?[]const u8 = null;
  var target: ?[]const u8 = null;
  var force_static = false;
  var force_trailer = false;
  var i: usize = 0;
  while (i < args.len) : (i += 1) {
    const a = args[i];
    if (std.mem.eql(u8, a, "-o")) {
      i += 1; if (i < args.len) out = args[i] else usage();
    } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--target")) {
      i += 1; if (i < args.len) target = args[i] else usage();
    } else if (std.mem.eql(u8, a, "--static")) {
      force_static = true;
    } else if (std.mem.eql(u8, a, "--trailer")) {
      force_trailer = true;
    } else if (script == null) {
      script = a;
    } else usage();
  }
  const sp = script orelse usage();
  const win = if (target) |t| std.mem.startsWith(u8, t, "windows") else (builtin.os.tag == .windows);

  // The k source to embed.
  const src = std.Io.Dir.cwd().readFileAlloc(io, sp, gpa, std.Io.Limit.limited(MAX_K)) catch |err| {
    std.debug.print("error reading {s}: {}\n", .{ sp, err });
    std.process.exit(1);
  };
  defer gpa.free(src);

  // Transitively collect the lib modules the script depends on.
  var loader = modules.ModuleLoader.init(gpa);
  defer loader.deinit();
  loader.scan("lib") catch {};
  var deps = std.StringHashMap([]const u8).init(gpa);
  defer {
    var it = deps.iterator();
    while (it.next()) |e| { gpa.free(e.key_ptr.*); gpa.free(e.value_ptr.*); }
    deps.deinit();
  }
  loader.collectDeps(src, &deps) catch {};

  // Which native extensions do the embedded modules pull in (libX.dylib refs)?
  var exts = std.ArrayList([]const u8).empty;
  defer { for (exts.items) |e| gpa.free(e); exts.deinit(gpa); }
  try collectExtNames(gpa, src, &deps, &exts);

  // Build the archive: [u32 n][u32 main_len][main][n × (path, data)].
  var archive: std.ArrayList(u8) = .empty;
  defer archive.deinit(gpa);
  try appendU32(&archive, gpa, @intCast(deps.count()));
  try appendU32(&archive, gpa, @intCast(src.len));
  try archive.appendSlice(gpa, src);
  var dit = deps.iterator();
  while (dit.next()) |e| {
    try appendU32(&archive, gpa, @intCast(e.key_ptr.len));
    try archive.appendSlice(gpa, e.key_ptr.*);
    try appendU32(&archive, gpa, @intCast(e.value_ptr.len));
    try archive.appendSlice(gpa, e.value_ptr.*);
  }

  // Output name: explicit -o, else the script stem (plus .exe for windows).
  var namebuf: [4096]u8 = undefined;
  const outname = out orelse (std.fmt.bufPrint(&namebuf, "{s}{s}", .{ scriptStem(sp), if (win) ".exe" else "" }) catch usage());

  // A script using native extensions needs them linked in (static), otherwise
  // the lightweight trailer-append is enough.  --static/--trailer force a mode.
  // Static linking shells out to `zig` and is a posix-host feature for now.
  const static = builtin.os.tag != .windows and !force_trailer and (force_static or exts.items.len > 0);
  if (static) {
    return bundleStatic(gpa, sp, outname, target, archive.items, deps.count(), exts.items);
  }
  return bundleTrailer(gpa, sp, outname, target, win, archive.items, deps.count());
}

// Append the k archive to a copy of a prebuilt ink binary (+ trailer).  Fully
// self-contained for pure-k scripts; extension-using scripts still need ~/.ink.
fn bundleTrailer(gpa: std.mem.Allocator, sp: []const u8, outname: []const u8, target: ?[]const u8, win: bool, archive: []const u8, nmods: usize) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  var basebuf: [4096]u8 = undefined;
  const base = if (target) |t| blk: {
    var hbuf: [512]u8 = undefined;
    const hdir = home.dir(&hbuf) orelse {
      std.debug.print("error: $INK_HOME / $HOME not set; cannot find base binary for -t {s}\n", .{t});
      std.process.exit(1);
    };
    break :blk std.fmt.bufPrint(&basebuf, "{s}/bin/ink-{s}{s}", .{ hdir, t, if (win) ".exe" else "" }) catch usage();
  } else selfExePath(&basebuf) catch {
    std.debug.print("error: cannot locate the ink binary on this platform; pass -t <platform>\n", .{});
    std.process.exit(1);
  };

  const basebytes = std.Io.Dir.cwd().readFileAlloc(io, base, gpa, std.Io.Limit.limited(MAX_BIN)) catch |err| {
    std.debug.print("error reading base binary {s}: {}\n", .{ base, err });
    std.process.exit(1);
  };
  defer gpa.free(basebytes);

  var trailer: [TRAILER]u8 = undefined;
  std.mem.writeInt(u64, trailer[0..8], archive.len, .little);
  @memcpy(trailer[8..16], MAGIC);

  var f = std.Io.Dir.cwd().createFile(io, outname, .{}) catch |err| {
    std.debug.print("error creating {s}: {}\n", .{ outname, err });
    std.process.exit(1);
  };
  defer f.close(io);
  try f.writeStreamingAll(io, basebytes);
  try f.writeStreamingAll(io, archive);
  try f.writeStreamingAll(io, &trailer);
  makeExecutable(gpa, outname);

  var obuf: [256]u8 = undefined;
  var w = std.Io.File.stdout().writer(io, &obuf);
  try w.interface.print("Bundled {s} -> {s} ({d} module(s), {d} bytes)\n", .{ sp, outname, nmods, basebytes.len + archive.len + TRAILER });
  try w.interface.flush();
}

// Static-link a fresh native executable: generate glue (which @embedFile's the
// archive + declares each linked extension's init) and `zig build-exe` it
// against libink-core.a + the needed extension .a's.  No dlopen at runtime.
fn bundleStatic(gpa: std.mem.Allocator, sp: []const u8, outname: []const u8, target: ?[]const u8, archive: []const u8, nmods: usize, exts: []const []const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();

  // Scratch dir holding archive.bin + glue.zig (co-located for @embedFile).
  var dbuf: [512]u8 = undefined;
  const dir = std.fmt.bufPrint(&dbuf, "{s}/ink-bundle-{d}", .{ tmpRoot(), std.c.getpid() }) catch usage();
  std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch {};

  try writeAbs(io, gpa, dir, "archive.bin", archive);

  var glue: std.ArrayList(u8) = .empty;
  defer glue.deinit(gpa);
  try glue.appendSlice(gpa,
    \\const std = @import("std");
    \\const archive = @embedFile("archive.bin");
    \\const ExtInit = *const fn (*anyopaque) callconv(.c) void;
    \\extern fn ink_run_bundle(p: [*]const u8, n: usize, ip: [*]const ?ExtInit, il: usize) c_int;
    \\
  );
  for (exts) |e| {
    const line = try std.fmt.allocPrint(gpa, "extern fn ink_ext_init_{s}(reg: *anyopaque) void;\n", .{e});
    defer gpa.free(line);
    try glue.appendSlice(gpa, line);
  }
  try glue.appendSlice(gpa, "pub fn main(init: std.process.Init.Minimal) !void {\n  _ = init;\n  const inits = [_]?ExtInit{ ");
  for (exts, 0..) |e, idx| {
    if (idx != 0) try glue.appendSlice(gpa, ", ");
    const sym = try std.fmt.allocPrint(gpa, "ink_ext_init_{s}", .{e});
    defer gpa.free(sym);
    try glue.appendSlice(gpa, sym);
  }
  try glue.appendSlice(gpa, " };\n  _ = ink_run_bundle(archive.ptr, archive.len, &inits, inits.len);\n}\n");
  try writeAbs(io, gpa, dir, "glue.zig", glue.items);

  // Locate libink-core.a and each extension .a (zig-out/lib for dev, else ~/.ink/share/<platform>).
  const core_a = findLib(gpa, "ink-core", target) orelse {
    std.debug.print("error: libink-core.a not found (run `zig build static`{s})\n", .{ if (target != null) " for the target and install it under ~/.ink/share" else "" });
    std.process.exit(1);
  };
  defer gpa.free(core_a);

  var argv: std.ArrayList([]const u8) = .empty;
  defer {
    for (argv.items) |a| gpa.free(a);
    argv.deinit(gpa);
  }
  const zig_exe = findZig(gpa) orelse {
    std.debug.print("error: `zig` not found on PATH (needed to link static bundles)\n", .{});
    std.process.exit(1);
  };
  try argv.append(gpa, zig_exe);
  try argv.append(gpa, try gpa.dupe(u8, "build-exe"));
  try argv.append(gpa, try std.fmt.allocPrint(gpa, "{s}/glue.zig", .{dir}));
  try argv.append(gpa, try gpa.dupe(u8, core_a));
  var needs_frameworks = false;
  for (exts) |e| {
    const is_gpu = std.mem.eql(u8, e, "gpu");
    if (is_gpu) needs_frameworks = true;
    // gpu links a merged archive (gpu+Dawn+GLFW) plus the macOS frameworks.
    const libname = if (is_gpu) "gpu-bundle" else e;
    const a = findLib(gpa, libname, target) orelse {
      std.debug.print("error: lib{s}.a not found — `{s}` cannot be statically bundled{s}\n", .{ libname, e, if (is_gpu) " (gpu is macOS-only; run `zig build static` on macOS)" else "" });
      std.process.exit(1);
    };
    try argv.append(gpa, a);
  }
  // gpu (Dawn) is C++ — link libc++ — plus the macOS frameworks it needs
  // (OS-provided, so they can't live inside a .a).
  if (needs_frameworks) {
    try argv.append(gpa, try gpa.dupe(u8, "-lc++"));
    for ([_][]const u8{ "Metal", "QuartzCore", "Foundation", "IOKit", "IOSurface", "Cocoa" }) |fw| {
      try argv.append(gpa, try gpa.dupe(u8, "-framework"));
      try argv.append(gpa, try gpa.dupe(u8, fw));
    }
  }
  try argv.append(gpa, try gpa.dupe(u8, "-lc"));
  try argv.append(gpa, try gpa.dupe(u8, "-OReleaseFast"));
  // The spawned zig inherits no environment, so point it at cache dirs
  // explicitly (otherwise it fails to resolve its app-data cache dir).  Reuse
  // ~/.cache/zig as the global cache so the std build is shared (fast).
  try argv.append(gpa, try gpa.dupe(u8, "--global-cache-dir"));
  if (std.c.getenv("HOME")) |h| {
    try argv.append(gpa, try std.fmt.allocPrint(gpa, "{s}/.cache/zig", .{std.mem.span(h)}));
  } else {
    try argv.append(gpa, try std.fmt.allocPrint(gpa, "{s}/gcache", .{dir}));
  }
  try argv.append(gpa, try gpa.dupe(u8, "--cache-dir"));
  try argv.append(gpa, try std.fmt.allocPrint(gpa, "{s}/cache", .{dir}));
  // Pass -target only for a genuine cross build.  Targeting the host platform
  // builds natively, which keeps the macOS SDK framework search paths (an
  // explicit -target drops them, breaking the gpu link).
  if (target) |t| if (!std.mem.eql(u8, t, home.platform)) {
    try argv.append(gpa, try gpa.dupe(u8, "-target"));
    try argv.append(gpa, try gpa.dupe(u8, tripleOf(t) orelse {
      std.debug.print("error: unknown target platform {s}\n", .{t});
      std.process.exit(1);
    }));
  };
  try argv.append(gpa, try std.fmt.allocPrint(gpa, "-femit-bin={s}", .{outname}));

  // Spawning needs a heap-backed Io; the global single-threaded one uses a
  // failing allocator (fine for our file writes, not for process spawn).
  var threaded = std.Io.Threaded.init(gpa, .{});
  defer threaded.deinit();
  const pio = threaded.io();
  const result = std.process.run(gpa, pio, .{ .argv = argv.items }) catch |err| {
    std.debug.print("error: failed to run zig build-exe: {} (is `zig` on PATH?)\n", .{err});
    std.process.exit(1);
  };
  defer gpa.free(result.stdout);
  defer gpa.free(result.stderr);
  const ok = switch (result.term) { .exited => |c| c == 0, else => false };
  if (!ok) {
    std.debug.print("error: linking the bundle failed:\n{s}\n", .{result.stderr});
    std.process.exit(1);
  }
  makeExecutable(gpa, outname);

  var obuf: [256]u8 = undefined;
  var w = std.Io.File.stdout().writer(io, &obuf);
  try w.interface.print("Bundled {s} -> {s} (static; {d} module(s), {d} extension(s))\n", .{ sp, outname, nmods, exts.len });
  try w.interface.flush();
}

fn makeExecutable(gpa: std.mem.Allocator, outname: []const u8) void {
  if (builtin.os.tag != .windows) {
    const z = gpa.dupeZ(u8, outname) catch return;
    defer gpa.free(z);
    _ = std.c.chmod(z, 0o755);
  }
}

fn tmpRoot() []const u8 {
  if (std.c.getenv("TMPDIR")) |t| {
    var s: []const u8 = std.mem.span(t);
    if (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
  }
  return "/tmp";
}

fn writeAbs(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, name: []const u8, bytes: []const u8) !void {
  const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
  defer gpa.free(path);
  var f = try std.Io.Dir.createFileAbsolute(io, path, .{});
  defer f.close(io);
  try f.writeStreamingAll(io, bytes);
}

// platform tag (matches src/home.zig / the Makefile) → zig target triple.
fn tripleOf(platform: []const u8) ?[]const u8 {
  const map = .{
    .{ "macos-arm64", "aarch64-macos" },     .{ "macos-x64", "x86_64-macos" },
    .{ "linux-arm64", "aarch64-linux-musl" }, .{ "linux-x64", "x86_64-linux-musl" },
    .{ "windows-arm64", "aarch64-windows-gnu" }, .{ "windows-x64", "x86_64-windows-gnu" },
  };
  inline for (map) |m| if (std.mem.eql(u8, platform, m[0])) return m[1];
  return null;
}

// Resolve `zig`'s absolute path by scanning $PATH (the io we spawn with has no
// inherited environment, so we can't rely on arg0 expansion).  Owned by gpa.
fn findZig(gpa: std.mem.Allocator) ?[]const u8 {
  const io = std.Io.Threaded.global_single_threaded.io();
  const path = std.c.getenv("PATH") orelse return null;
  var it = std.mem.splitScalar(u8, std.mem.span(path), ':');
  while (it.next()) |dir| {
    if (dir.len == 0) continue;
    const cand = std.fmt.allocPrint(gpa, "{s}/zig", .{dir}) catch continue;
    if (fileExists(io, cand)) return cand;
    gpa.free(cand);
  }
  return null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
  var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
  f.close(io);
  return true;
}

// Locate the static lib for `name`: zig-out/lib for a host (dev-tree) build,
// else the installed ~/.ink/share/<platform>/.  The archive name follows the
// target's convention — `lib<name>.a` on unix, `<name>.lib` on Windows.
// Returns an owned path (caller frees).
fn findLib(gpa: std.mem.Allocator, name: []const u8, target: ?[]const u8) ?[]const u8 {
  const io = std.Io.Threaded.global_single_threaded.io();
  const win = if (target) |t| std.mem.startsWith(u8, t, "windows") else (builtin.os.tag == .windows);
  const fname = (if (win) std.fmt.allocPrint(gpa, "{s}.lib", .{name}) else std.fmt.allocPrint(gpa, "lib{s}.a", .{name})) catch return null;
  defer gpa.free(fname);
  if (target == null) {
    const p = std.fmt.allocPrint(gpa, "zig-out/lib/{s}", .{fname}) catch return null;
    if (fileExists(io, p)) return p;
    gpa.free(p);
  }
  var hbuf: [512]u8 = undefined;
  if (home.dir(&hbuf)) |hdir| {
    const platform = target orelse home.platform;
    const p = std.fmt.allocPrint(gpa, "{s}/share/{s}/{s}", .{ hdir, platform, fname }) catch return null;
    if (fileExists(io, p)) return p;
    gpa.free(p);
  }
  return null;
}

// Find the native extensions (lib<name>.dylib/.so/.dll references) used by the
// main script and its embedded modules, deduped, into `out` (owned by gpa).
fn collectExtNames(gpa: std.mem.Allocator, src: []const u8, deps: *std.StringHashMap([]const u8), out: *std.ArrayList([]const u8)) !void {
  var seen = std.StringHashMap(void).init(gpa);
  defer seen.deinit();
  try scanExts(gpa, src, &seen, out);
  var it = deps.iterator();
  while (it.next()) |e| try scanExts(gpa, e.value_ptr.*, &seen, out);
}

fn scanExts(gpa: std.mem.Allocator, text: []const u8, seen: *std.StringHashMap(void), out: *std.ArrayList([]const u8)) !void {
  var i: usize = 0;
  while (i + 3 < text.len) : (i += 1) {
    if (!(text[i] == 'l' and text[i + 1] == 'i' and text[i + 2] == 'b')) continue;
    var j = i + 3;
    while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
    const name = text[i + 3 .. j];
    if (name.len == 0) continue;
    const rest = text[j..];
    if (!(std.mem.startsWith(u8, rest, ".dylib") or std.mem.startsWith(u8, rest, ".so") or std.mem.startsWith(u8, rest, ".dll"))) continue;
    if (seen.contains(name)) continue;
    const dup = try gpa.dupe(u8, name);
    try seen.put(dup, {});
    try out.append(gpa, dup);
  }
}
