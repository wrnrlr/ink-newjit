/// Compress extension for ink — DEFLATE (and its gzip/zlib framings) over Zig's
/// `std.compress.flate`, loaded via lib/compress.k.  Bytes in, bytes out (C
/// vectors), so it composes with the other modules.
///
/// Build first:  zig build compress
/// Load with:    2:"lib/compress.k"   (or reference any `compress.*` name)
///
/// K API (registered name → what lib/compress.k binds it to):
///   compress.deflate / inflate   — raw DEFLATE stream (no header/footer)
///   compress.gzip    / gunzip     — gzip container (RFC 1952)
///   compress.zlib    / unzlib     — zlib container (RFC 1950)
///   compress.crc32 bytes → i32    — CRC-32 (as used by gzip/zip)
///   compress.adler32 bytes → i32  — Adler-32 (as used by zlib)
/// Decompressors return an error `' on malformed/corrupt input.

const std = @import("std");
const flate = std.compress.flate;
const K = *anyopaque;

const KRegistry = @import("kabi").KRegistry(K);

const KApi = struct {
  ki:   *const fn (i32)   callconv(.c) ?K,
  kerr: *const fn ()      callconv(.c) ?K,
  KC:   *const fn (i32)   callconv(.c) ?K,
  kn:   *const fn (?K)    callconv(.c) i32,
  kcp:  *const fn (?K)    callconv(.c) ?[*]u8,
  ku:   *const fn (?K)    callconv(.c) void,
};
var g_api: ?KApi = null;

fn ki(n: i32) ?K       { return g_api.?.ki(n); }
fn kerr() ?K           { return g_api.?.kerr(); }
fn kn(x: ?K) i32       { return g_api.?.kn(x); }
fn kcp(x: ?K) ?[*]u8   { return g_api.?.kcp(x); }
fn ku(x: ?K) void      { g_api.?.ku(x); }

fn bytes(x: ?K) ?[]const u8 {
  const n = kn(x);
  if (n < 0) return null;
  if (n == 0) return &[_]u8{};
  const p = kcp(x) orelse return null;
  return p[0..@intCast(n)];
}

fn outBytes(data: []const u8) ?K {
  const out = g_api.?.KC(@intCast(data.len)) orelse return null;
  if (data.len > 0) @memcpy(kcp(out).?[0..data.len], data);
  return out;
}

const alloc = std.heap.c_allocator;

// ── Compression ─────────────────────────────────────────────────────────────
// Deflate `input` into a fresh C vector, wrapped in the given container framing.
fn deflate(input: []const u8, container: flate.Container) ?K {
  const window = alloc.alloc(u8, flate.max_window_len) catch return null;
  defer alloc.free(window);
  // Growable sink for the compressed output; needs >8 bytes of initial capacity.
  var sink = std.Io.Writer.Allocating.initCapacity(alloc, @max(64, input.len / 2)) catch return null;
  defer sink.deinit();
  // `c` holds a Writer whose vtable resolves back to `&c` via @fieldParentPtr,
  // so it must stay put — don't copy it after init.
  var c = flate.Compress.init(&sink.writer, window, container, .default) catch return null;
  c.writer.writeAll(input) catch return null;
  c.finish() catch return null;
  return outBytes(sink.writer.buffered());
}

// Inflate `input` (with the given container framing) into a fresh C vector.
fn inflate(input: []const u8, container: flate.Container) ?K {
  const window = alloc.alloc(u8, flate.max_window_len) catch return null;
  defer alloc.free(window);
  var src = std.Io.Reader.fixed(input);
  var d = flate.Decompress.init(&src, container, window);
  const out = d.reader.allocRemaining(alloc, .unlimited) catch return kerr();
  defer alloc.free(out);
  return outBytes(out);
}

fn deflateFn(comptime container: flate.Container) fn (?K) callconv(.c) ?K {
  return struct {
    fn f(x: ?K) callconv(.c) ?K {
      const in = bytes(x) orelse return null;
      return deflate(in, container);
    }
  }.f;
}

fn inflateFn(comptime container: flate.Container) fn (?K) callconv(.c) ?K {
  return struct {
    fn f(x: ?K) callconv(.c) ?K {
      const in = bytes(x) orelse return null;
      return inflate(in, container);
    }
  }.f;
}

export const compDeflate = deflateFn(.raw);
export const compInflate = inflateFn(.raw);
export const compGzip    = deflateFn(.gzip);
export const compGunzip  = inflateFn(.gzip);
export const compZlib    = deflateFn(.zlib);
export const compUnzlib  = inflateFn(.zlib);

// ── Checksums ────────────────────────────────────────────────────────────────
// Returned bit-reinterpreted into i32 (ink has no u32 tier-1 type); compare the
// values directly or re-cast — e.g. a 0xFFFFFFFF CRC reads back as -1.
export fn compCrc32(x: ?K) callconv(.c) ?K {
  const b = bytes(x) orelse return null;
  const crc = std.hash.crc.Crc32.hash(b);
  return ki(@bitCast(crc));
}

export fn compAdler32(x: ?K) callconv(.c) ?K {
  const b = bytes(x) orelse return null;
  const sum = std.hash.Adler32.hash(b);
  return ki(@bitCast(sum));
}

// ── Init ────────────────────────────────────────────────────────────────────
fn inkInit(reg: *anyopaque) void {
  const r: *const KRegistry = @ptrCast(@alignCast(reg));
  g_api = .{ .ki = r.ki, .kerr = r.kerr, .KC = r.KC, .kn = r.kn, .kcp = r.kcp, .ku = r.ku };
  inline for (.{
    .{ "compDeflate", &compDeflate }, .{ "compInflate", &compInflate },
    .{ "compGzip", &compGzip },       .{ "compGunzip", &compGunzip },
    .{ "compZlib", &compZlib },       .{ "compUnzlib", &compUnzlib },
    .{ "compCrc32", &compCrc32 },     .{ "compAdler32", &compAdler32 },
  }) |e| {
    r.k_register(e[0], @ptrCast(e[1]), 1);
  }
}

export fn terse_init(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
export fn ink_ext_init_compress(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
