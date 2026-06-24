/// Font extension for ink — native sfnt parser FFI boundary.
///
/// Exports:
///   ReadFont  "path"  →  L of face dicts (one per face; TTC yields several).
///
/// Each face dict is keyed by normalized table name → that table's normalized
/// K value (see lib/font/sfnt.zig and lib/font/table/*.zig). No tatfi, no
/// global handle table, no auto-registration — pure read of the font file.

const std = @import("std");
const sfnt = @import("sfnt.zig");
const k = @import("kbuild.zig");
const cffo = @import("cff_outline.zig");

const alloc = std.heap.c_allocator;

/// Read an entire file into a heap slice (caller frees).
fn readFile(path: [*:0]const u8) ![]u8 {
  const io = std.Io.Threaded.global_single_threaded.io();
  return std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(path), alloc, std.Io.Limit.limited(256 << 20));
}

// ── ReadFont ──────────────────────────────────────────────────────────────────
//
// x = C (file path) → L of face dicts. Table parsers copy everything they need
// out of the file buffer, so the buffer is freed before returning.

export fn ReadFont(path_k: ?*anyopaque) callconv(.c) ?*anyopaque {
  const cp = k.reg.?.kcp(path_k) orelse return null;
  const n: usize = @intCast(@max(0, k.reg.?.kn(path_k)));
  var buf: [1024]u8 = undefined;
  if (n >= buf.len) return null;
  @memcpy(buf[0..n], cp[0..n]);
  buf[n] = 0;
  const path: [*:0]const u8 = @ptrCast(&buf);

  const data = readFile(path) catch return null;
  defer alloc.free(data);

  return sfnt.readFont(data);
}

// ── cffOutline ──────────────────────────────────────────────────────────────────
//
// x = (charstring_C; globalSubrs_L; localSubrs_L; scale_f)
//   → L of flat F contours [x,y,…], pixel-scaled and y-flipped (matches the
//     glyf FontOutline shape). Type 2 charstring → flattened outline.

// Read a list of C vectors into slices. The element slices alias the list's
// buffers, which stay alive while the parent list (`listk`) is held by the
// caller — so we release each per-element box immediately.
fn readSubrs(listk: ?*anyopaque) ![][]const u8 {
  const m: usize = @intCast(@max(0, k.kn(listk)));
  const out = try alloc.alloc([]const u8, m);
  for (0..m) |i| {
    const e = k.listGet(listk, @intCast(i));
    const len: usize = @intCast(@max(0, k.kn(e)));
    out[i] = if (k.cp(e)) |p| p[0..len] else &.{};
    k.unref(e);
  }
  return out;
}

export fn cffOutline(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
  if (k.kn(arg) < 4) return null;

  const csk = k.listGet(arg, 0);
  defer k.unref(csk);
  const gk = k.listGet(arg, 1);
  defer k.unref(gk);
  const lk = k.listGet(arg, 2);
  defer k.unref(lk);
  const sk = k.listGet(arg, 3);
  defer k.unref(sk);

  const csn: usize = @intCast(@max(0, k.kn(csk)));
  const charstring = if (k.cp(csk)) |p| p[0..csn] else return null;

  const gsubrs = readSubrs(gk) catch return null;
  defer alloc.free(gsubrs);
  const lsubrs = readSubrs(lk) catch return null;
  defer alloc.free(lsubrs);

  const scale: f64 = k.kfval(sk);
  return cffo.outline(charstring, gsubrs, lsubrs, scale);
}

// ── terse_init ──────────────────────────────────────────────────────────────────

export fn terse_init(reg: *anyopaque) callconv(.c) void {
  k.init(@ptrCast(@alignCast(reg)));
}
