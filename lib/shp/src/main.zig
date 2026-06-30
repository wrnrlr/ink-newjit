/// Shapefile extension for ink — loaded via lib/shp/shp.k.
///
/// K API (after loading):
///   ReadShp "file.shp"  → dict: flat CSR geometry (type,box,x,y[,z,m],part,shape)
///   ReadShx "file.shx"  → dict: `offset`len!(I;I) record byte offsets/lengths
///   ReadDbf "file.dbf"  → table: one column per attribute field
///   ReadPrj "file.prj"  → C: projection WKT string
///   ReadCpg "file.cpg"  → C: codepage / encoding name
///   ReadSbn "file.sbn"  → table: per-feature MBRs (best-effort; see sbn.zig)
///
/// Geometry is kept fully columnar (single contiguous x/y/z/m buffers + CSR
/// part/shape offset arrays) so coordinates upload to the GPU without reshaping.
/// .shp records and .dbf rows align by position (record i ↔ row i).

const std = @import("std");
const k = @import("kbuild.zig");
const rd = @import("read.zig");
const shp = @import("shp.zig");
const shx = @import("shx.zig");
const dbf = @import("dbf.zig");
const sbn = @import("sbn.zig");

const alloc = std.heap.c_allocator;

// Copy a K char-vector path into a null-terminated stack buffer.
fn pathOf(path_k: ?*anyopaque, buf: []u8) ?[*:0]const u8 {
  const cp = k.reg.?.kcp(path_k) orelse return null;
  const n: usize = @intCast(@max(0, k.reg.?.kn(path_k)));
  if (n == 0 or n >= buf.len) return null;
  @memcpy(buf[0..n], cp[0..n]);
  buf[n] = 0;
  return @ptrCast(buf.ptr);
}

const Parser = *const fn (std.mem.Allocator, []const u8) anyerror!?k.K;

fn readWith(path_k: ?*anyopaque, parser: Parser) ?k.K {
  var buf: [4096]u8 = undefined;
  const path = pathOf(path_k, &buf) orelse return null;
  const data = rd.readFile(alloc, path) catch return null;
  defer alloc.free(data);
  return (parser(alloc, data) catch return null) orelse null;
}

export fn ReadShp(path_k: ?*anyopaque) callconv(.c) ?*anyopaque {
  return @ptrCast(readWith(path_k, shp.parse));
}
export fn ReadShx(path_k: ?*anyopaque) callconv(.c) ?*anyopaque {
  return @ptrCast(readWith(path_k, shx.parse));
}
export fn ReadDbf(path_k: ?*anyopaque) callconv(.c) ?*anyopaque {
  return @ptrCast(readWith(path_k, dbf.parse));
}
export fn ReadSbn(path_k: ?*anyopaque) callconv(.c) ?*anyopaque {
  return @ptrCast(readWith(path_k, sbn.parse));
}

// .prj / .cpg are plain text. Return the file contents as a C string; trim
// trailing whitespace (codepage files in particular carry a trailing newline).
fn readText(path_k: ?*anyopaque, trimText: bool) ?k.K {
  var buf: [4096]u8 = undefined;
  const path = pathOf(path_k, &buf) orelse return null;
  const data = rd.readFile(alloc, path) catch return null;
  defer alloc.free(data);
  var s: []const u8 = data;
  if (trimText) s = std.mem.trim(u8, s, " \t\r\n");
  return k.str(s);
}

export fn ReadPrj(path_k: ?*anyopaque) callconv(.c) ?*anyopaque {
  return @ptrCast(readText(path_k, false));
}
export fn ReadCpg(path_k: ?*anyopaque) callconv(.c) ?*anyopaque {
  return @ptrCast(readText(path_k, true));
}

fn inkInit(reg: *anyopaque) void {
  k.init(@ptrCast(@alignCast(reg)));
  // Register callable functions by name (loader-independent resolution).
  const kr: *const @import("kabi").KRegistry(*anyopaque) = @ptrCast(@alignCast(reg));
  kr.k_register("ReadShp", @ptrCast(&ReadShp), 1);
  kr.k_register("ReadShx", @ptrCast(&ReadShx), 1);
  kr.k_register("ReadDbf", @ptrCast(&ReadDbf), 1);
  kr.k_register("ReadSbn", @ptrCast(&ReadSbn), 1);
  kr.k_register("ReadPrj", @ptrCast(&ReadPrj), 1);
  kr.k_register("ReadCpg", @ptrCast(&ReadCpg), 1);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
export fn ink_ext_init_shp(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
