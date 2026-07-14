/// Zip extension for ink — read and write ZIP archives, loaded via lib/zip.k.
/// Parses the archive in memory using the struct layouts from Zig's `std.zip`
/// and (de)compresses entries with `std.compress.flate`, so it composes with
/// the `compress` module.
///
/// Build first:  zig build zip
/// Load with:    2:"lib/zip.k"   (or reference any `zip.*` name)
///
/// K API (registered name → what lib/zip.k binds it to):
///   zip.list  "a.zip"          → table [name;size;csize;method;crc] of entries
///   zip.read  "a.zip"          → dict  name → decompressed bytes
///   zip.entry ["a.zip"; name]  → decompressed bytes of one entry (error if absent)
///   zip.write ["a.zip"; names; datas] → create an archive (deflate each) → 1b
///
/// Supported: store (method 0) and deflate (method 8), non-encrypted, non-zip64
/// archives.  Anything else yields an error `'.  Little-endian hosts only (all
/// current ink targets).

const std = @import("std");
const zip = std.zip;
const flate = std.compress.flate;
const K = *anyopaque;

const KRegistry = @import("kabi").KRegistry(K);

const KApi = struct {
  ki:           *const fn (i32)                                       callconv(.c) ?K,
  kb:           *const fn (c_int)                                     callconv(.c) ?K,
  kerr:         *const fn ()                                          callconv(.c) ?K,
  KC:           *const fn (i32)                                       callconv(.c) ?K,
  KI:           *const fn (i32)                                       callconv(.c) ?K,
  KL:           *const fn (i32)                                       callconv(.c) ?K,
  kn:           *const fn (?K)                                        callconv(.c) i32,
  kcp:          *const fn (?K)                                        callconv(.c) ?[*]u8,
  kip:          *const fn (?K)                                        callconv(.c) ?[*]i32,
  ku:           *const fn (?K)                                        callconv(.c) void,
  k_list_set:   *const fn (?K, i32, ?K)                               callconv(.c) i32,
  k_list_get:   *const fn (?K, i32)                                   callconv(.c) ?K,
  k_make_dict:  *const fn (i32, [*]const [*:0]const u8, [*]const ?K)  callconv(.c) ?K,
  k_make_table: *const fn (i32, [*]const [*:0]const u8, [*]const ?K)  callconv(.c) ?K,
};
var g_api: ?KApi = null;

fn ki(n: i32) ?K        { return g_api.?.ki(n); }
fn kb(v: bool) ?K       { return g_api.?.kb(if (v) 1 else 0); }
fn kerr() ?K            { return g_api.?.kerr(); }
fn KC(n: i32) ?K        { return g_api.?.KC(n); }
fn KI(n: i32) ?K        { return g_api.?.KI(n); }
fn KL(n: i32) ?K        { return g_api.?.KL(n); }
fn kn(x: ?K) i32        { return g_api.?.kn(x); }
fn kcp(x: ?K) ?[*]u8    { return g_api.?.kcp(x); }
fn kip(x: ?K) ?[*]i32   { return g_api.?.kip(x); }
fn ku(x: ?K) void       { g_api.?.ku(x); }
fn kls(l: ?K, i: i32, v: ?K) i32 { return g_api.?.k_list_set(l, i, v); }
fn klg(l: ?K, i: i32) ?K         { return g_api.?.k_list_get(l, i); }

const alloc = std.heap.c_allocator;
const CDFH = zip.CentralDirectoryFileHeader;
const LFH = zip.LocalFileHeader;

fn bytes(x: ?K) ?[]const u8 {
  const n = kn(x);
  if (n < 0) return null;
  if (n == 0) return &[_]u8{};
  const p = kcp(x) orelse return null;
  return p[0..@intCast(n)];
}

fn outBytes(data: []const u8) ?K {
  const out = KC(@intCast(data.len)) orelse return null;
  if (data.len > 0) @memcpy(kcp(out).?[0..data.len], data);
  return out;
}

fn readFile(path_k: ?K) ?[]u8 {
  const p = bytes(path_k) orelse return null;
  if (p.len == 0) return null;
  const io = std.Io.Threaded.global_single_threaded.io();
  return std.Io.Dir.cwd().readFileAlloc(io, p, alloc, std.Io.Limit.limited(1 << 30)) catch null;
}

// ── Central-directory walk ──────────────────────────────────────────────────
const Entry = struct {
  name: []const u8,
  method: u16,
  crc32: u32,
  csize: u32,
  usize: u32,
  local_off: u32,
};

// Call `cb(entry)` for each central-directory record; returns false on a
// malformed archive.
// Locate the End-Of-Central-Directory record by scanning for its signature
// (std.zip.EndRecord.findBuffer has a bad error set in this Zig version, so we
// parse it directly).  Little-endian host assumed.
fn findEnd(buf: []const u8) ?zip.EndRecord {
  if (buf.len < @sizeOf(zip.EndRecord)) return null;
  const pos = std.mem.lastIndexOf(u8, buf, &zip.end_record_sig) orelse return null;
  if (pos + @sizeOf(zip.EndRecord) > buf.len) return null;
  const rec: *align(1) const zip.EndRecord = @ptrCast(buf[pos..].ptr);
  return rec.*;
}

fn eachEntry(buf: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Entry) bool) bool {
  const end = findEnd(buf) orelse return false;
  if (end.need_zip64()) return false; // zip64 unsupported
  var off: usize = end.central_directory_offset;
  var i: usize = 0;
  while (i < end.record_count_total) : (i += 1) {
    if (off + @sizeOf(CDFH) > buf.len) return false;
    const h: *align(1) const CDFH = @ptrCast(buf[off..].ptr);
    if (!std.mem.eql(u8, &h.signature, &zip.central_file_header_sig)) return false;
    const name_start = off + @sizeOf(CDFH);
    if (name_start + h.filename_len > buf.len) return false;
    const e = Entry{
      .name = buf[name_start..][0..h.filename_len],
      .method = @intFromEnum(h.compression_method),
      .crc32 = h.crc32,
      .csize = h.compressed_size,
      .usize = h.uncompressed_size,
      .local_off = h.local_file_header_offset,
    };
    if (!cb(ctx, e)) return false;
    off = name_start + h.filename_len + h.extra_len + h.comment_len;
  }
  return true;
}

// Decompress one entry's payload into a freshly allocated buffer (caller frees).
fn extract(buf: []const u8, e: Entry) ?[]u8 {
  if (e.local_off + @sizeOf(LFH) > buf.len) return null;
  const lh: *align(1) const LFH = @ptrCast(buf[e.local_off..].ptr);
  if (!std.mem.eql(u8, &lh.signature, &zip.local_file_header_sig)) return null;
  const data_start = e.local_off + @sizeOf(LFH) + lh.filename_len + lh.extra_len;
  if (data_start + e.csize > buf.len) return null;
  const comp = buf[data_start..][0..e.csize];
  switch (e.method) {
    0 => return alloc.dupe(u8, comp) catch null, // store
    8 => {
      var src = std.Io.Reader.fixed(comp);
      const window = alloc.alloc(u8, flate.max_window_len) catch return null;
      defer alloc.free(window);
      var d = flate.Decompress.init(&src, .raw, window);
      return d.reader.allocRemaining(alloc, .unlimited) catch null;
    },
    else => return null, // unsupported method
  }
}

// ── zip.list ────────────────────────────────────────────────────────────────
const ListCtx = struct {
  names: ?K, sizes: ?K, csizes: ?K, methods: ?K, crcs: ?K,
  cap: usize, i: usize = 0, ok: bool = true,
};

fn listCb(ctx: *ListCtx, e: Entry) bool {
  if (ctx.i >= ctx.cap) return false;
  const nm = outBytes(e.name) orelse { ctx.ok = false; return false; };
  _ = kls(ctx.names, @intCast(ctx.i), nm);
  kip(ctx.sizes).?[ctx.i]   = @bitCast(e.usize);
  kip(ctx.csizes).?[ctx.i]  = @bitCast(e.csize);
  kip(ctx.methods).?[ctx.i] = @intCast(e.method);
  kip(ctx.crcs).?[ctx.i]    = @bitCast(e.crc32);
  ctx.i += 1;
  return true;
}

fn countCb(ctx: *usize, _: Entry) bool { ctx.* += 1; return true; }

export fn ZipList(path_k: ?K) callconv(.c) ?K {
  const buf = readFile(path_k) orelse return null;
  defer alloc.free(buf);

  var n: usize = 0;
  if (!eachEntry(buf, &n, countCb)) return kerr();

  var ctx = ListCtx{
    .names = KL(@intCast(n)), .sizes = KI(@intCast(n)), .csizes = KI(@intCast(n)),
    .methods = KI(@intCast(n)), .crcs = KI(@intCast(n)), .cap = n,
  };
  if (ctx.names == null or ctx.sizes == null or ctx.csizes == null or
      ctx.methods == null or ctx.crcs == null) return null;
  if (!eachEntry(buf, &ctx, listCb) or !ctx.ok) {
    ku(ctx.names); ku(ctx.sizes); ku(ctx.csizes); ku(ctx.methods); ku(ctx.crcs);
    return kerr();
  }

  const cols = [_][*:0]const u8{ "name", "size", "csize", "method", "crc" };
  const vals = [_]?K{ ctx.names, ctx.sizes, ctx.csizes, ctx.methods, ctx.crcs };
  const t = g_api.?.k_make_table(5, &cols, &vals);
  ku(ctx.names); ku(ctx.sizes); ku(ctx.csizes); ku(ctx.methods); ku(ctx.crcs);
  return t orelse kerr();
}

// ── zip.read → dict name→bytes ──────────────────────────────────────────────
const ReadCtx = struct {
  buf: []const u8,
  names: std.ArrayList([*:0]const u8) = .empty,
  vals: std.ArrayList(?K) = .empty,
  ok: bool = true,
};

fn readCb(ctx: *ReadCtx, e: Entry) bool {
  const data = extract(ctx.buf, e) orelse { ctx.ok = false; return false; };
  defer alloc.free(data);
  const v = outBytes(data) orelse { ctx.ok = false; return false; };
  const name_z = alloc.dupeZ(u8, e.name) catch { ku(v); ctx.ok = false; return false; };
  ctx.names.append(alloc, name_z.ptr) catch { ku(v); ctx.ok = false; return false; };
  ctx.vals.append(alloc, v) catch { ku(v); ctx.ok = false; return false; };
  return true;
}

export fn ZipRead(path_k: ?K) callconv(.c) ?K {
  const buf = readFile(path_k) orelse return null;
  defer alloc.free(buf);
  var ctx = ReadCtx{ .buf = buf };
  defer {
    for (ctx.names.items) |nm| alloc.free(std.mem.span(nm));
    ctx.names.deinit(alloc);
    ctx.vals.deinit(alloc);
  }
  if (!eachEntry(buf, &ctx, readCb) or !ctx.ok) {
    for (ctx.vals.items) |v| ku(v);
    return kerr();
  }
  const d = g_api.?.k_make_dict(@intCast(ctx.names.items.len), ctx.names.items.ptr, ctx.vals.items.ptr);
  for (ctx.vals.items) |v| ku(v); // dict took its own refs
  return d orelse kerr();
}

// ── zip.entry[path; name] → bytes of one entry ──────────────────────────────
const FindCtx = struct { buf: []const u8, want: []const u8, result: ?K = null, found: bool = false };

fn findCb(ctx: *FindCtx, e: Entry) bool {
  if (ctx.found) return true; // keep walking; already have it
  if (!std.mem.eql(u8, e.name, ctx.want)) return true;
  const data = extract(ctx.buf, e) orelse return false;
  defer alloc.free(data);
  ctx.result = outBytes(data);
  ctx.found = true;
  return true;
}

export fn ZipEntry(path_k: ?K, name_k: ?K) callconv(.c) ?K {
  const buf = readFile(path_k) orelse return null;
  defer alloc.free(buf);
  const want = bytes(name_k) orelse return null;
  var ctx = FindCtx{ .buf = buf, .want = want };
  if (!eachEntry(buf, &ctx, findCb)) return kerr();
  if (!ctx.found) return kerr();
  return ctx.result;
}

// ── zip.write[path; names; datas] → create an archive ───────────────────────
fn appendInt(list: *std.ArrayList(u8), comptime T: type, v: T) void {
  var b: [@sizeOf(T)]u8 = undefined;
  std.mem.writeInt(T, &b, v, .little);
  list.appendSlice(alloc, &b) catch {};
}

const WriteRec = struct { crc: u32, csize: u32, usize: u32, name: []const u8, local_off: u32 };

export fn ZipWrite(path_k: ?K, names_k: ?K, datas_k: ?K) callconv(.c) ?K {
  const n = kn(names_k);
  if (n < 0 or kn(datas_k) != n) return kb(false);

  var out: std.ArrayList(u8) = .empty;
  defer out.deinit(alloc);
  var recs: std.ArrayList(WriteRec) = .empty;
  defer {
    for (recs.items) |r| alloc.free(r.name);
    recs.deinit(alloc);
  }

  var i: i32 = 0;
  while (i < n) : (i += 1) {
    const name_k = klg(names_k, i);
    defer ku(name_k);
    const data_k = klg(datas_k, i);
    defer ku(data_k);
    const name = bytes(name_k) orelse return kb(false);
    const data = bytes(data_k) orelse return kb(false);

    const crc = std.hash.crc.Crc32.hash(data);
    const comp = deflateRaw(data) orelse return kb(false);
    defer alloc.free(comp);
    // Store uncompressed if deflate didn't help (keeps tiny/incompressible small).
    const store = comp.len >= data.len;
    const payload = if (store) data else comp;

    const local_off: u32 = @intCast(out.items.len);
    const name_copy = alloc.dupe(u8, name) catch return kb(false);
    recs.append(alloc, .{
      .crc = crc, .csize = @intCast(payload.len), .usize = @intCast(data.len),
      .name = name_copy, .local_off = local_off,
    }) catch { alloc.free(name_copy); return kb(false); };

    // Local file header (30 bytes) + name + payload.
    out.appendSlice(alloc, &zip.local_file_header_sig) catch return kb(false);
    appendInt(&out, u16, 20);                          // version needed
    appendInt(&out, u16, 0);                           // flags
    appendInt(&out, u16, if (store) 0 else 8);         // method
    appendInt(&out, u16, 0);                           // mod time
    appendInt(&out, u16, 0);                           // mod date
    appendInt(&out, u32, crc);
    appendInt(&out, u32, @intCast(payload.len));       // compressed size
    appendInt(&out, u32, @intCast(data.len));          // uncompressed size
    appendInt(&out, u16, @intCast(name.len));          // filename length
    appendInt(&out, u16, 0);                           // extra length
    out.appendSlice(alloc, name) catch return kb(false);
    out.appendSlice(alloc, payload) catch return kb(false);
  }

  // Central directory.
  const cd_start: u32 = @intCast(out.items.len);
  for (recs.items) |r| {
    out.appendSlice(alloc, &zip.central_file_header_sig) catch return kb(false);
    appendInt(&out, u16, 20);                          // version made by
    appendInt(&out, u16, 20);                          // version needed
    appendInt(&out, u16, 0);                           // flags
    appendInt(&out, u16, methodOf(r));                 // method
    appendInt(&out, u16, 0);                           // mod time
    appendInt(&out, u16, 0);                           // mod date
    appendInt(&out, u32, r.crc);
    appendInt(&out, u32, r.csize);
    appendInt(&out, u32, r.usize);
    appendInt(&out, u16, @intCast(r.name.len));        // filename length
    appendInt(&out, u16, 0);                           // extra length
    appendInt(&out, u16, 0);                           // comment length
    appendInt(&out, u16, 0);                           // disk number
    appendInt(&out, u16, 0);                           // internal attrs
    appendInt(&out, u32, 0);                           // external attrs
    appendInt(&out, u32, r.local_off);                 // local header offset
    out.appendSlice(alloc, r.name) catch return kb(false);
  }
  const cd_size: u32 = @intCast(out.items.len - cd_start);

  // End of central directory record.
  out.appendSlice(alloc, &zip.end_record_sig) catch return kb(false);
  appendInt(&out, u16, 0);                             // disk number
  appendInt(&out, u16, 0);                             // cd start disk
  appendInt(&out, u16, @intCast(recs.items.len));      // records on this disk
  appendInt(&out, u16, @intCast(recs.items.len));      // total records
  appendInt(&out, u32, cd_size);
  appendInt(&out, u32, cd_start);
  appendInt(&out, u16, 0);                             // comment length

  const p = bytes(path_k) orelse return kb(false);
  if (p.len == 0) return kb(false);
  const io = std.Io.Threaded.global_single_threaded.io();
  var f = std.Io.Dir.cwd().createFile(io, p, .{}) catch return kb(false);
  defer f.close(io);
  f.writeStreamingAll(io, out.items) catch return kb(false);
  return kb(true);
}

// The write records only track sizes; recover the method by re-checking whether
// the payload was stored (csize==usize means it was, since deflate output that
// ties the input is stored instead).
fn methodOf(r: WriteRec) u16 { return if (r.csize == r.usize) 0 else 8; }

fn deflateRaw(input: []const u8) ?[]u8 {
  const window = alloc.alloc(u8, flate.max_window_len) catch return null;
  defer alloc.free(window);
  var sink = std.Io.Writer.Allocating.initCapacity(alloc, @max(64, input.len / 2)) catch return null;
  defer sink.deinit();
  var c = flate.Compress.init(&sink.writer, window, .raw, .default) catch return null;
  c.writer.writeAll(input) catch return null;
  c.finish() catch return null;
  return alloc.dupe(u8, sink.writer.buffered()) catch null;
}

// ── Init ────────────────────────────────────────────────────────────────────
fn inkInit(reg: *anyopaque) void {
  const r: *const KRegistry = @ptrCast(@alignCast(reg));
  g_api = .{
    .ki = r.ki, .kb = r.kb, .kerr = r.kerr, .KC = r.KC, .KI = r.KI, .KL = r.KL,
    .kn = r.kn, .kcp = r.kcp, .kip = r.kip, .ku = r.ku,
    .k_list_set = r.k_list_set, .k_list_get = r.k_list_get,
    .k_make_dict = r.k_make_dict, .k_make_table = r.k_make_table,
  };
  r.k_register("ZipList", @ptrCast(&ZipList), 1);
  r.k_register("ZipRead", @ptrCast(&ZipRead), 1);
  r.k_register("ZipEntry", @ptrCast(&ZipEntry), 2);
  r.k_register("ZipWrite", @ptrCast(&ZipWrite), 3);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
export fn ink_ext_init_zip(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
