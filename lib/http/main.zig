/// HTTP client extension for ink — over Zig's `std.http.Client`, loaded via
/// lib/http.k.  For talking to web/JSON APIs: TLS (https), redirects and
/// gzip/deflate/zstd response decompression are handled automatically.
///
/// Build first:  zig build http
/// Load with:    2:"lib/http.k"   (or reference any `http.*` name)
///
/// The one registered primitive is `HttpRequest (method; url; headers; body)`,
/// a 4-element list:
///   method   — C, e.g. "GET" "POST" "PUT" "DELETE" "PATCH" "HEAD"
///   url      — C, e.g. "https://api.example.com/v1/things"
///   headers  — L of C, flat name/value pairs ("accept";"application/json";…)
///   body     — C request body ("" for none)
/// It returns a dict:
///   status   — i   HTTP status code (200, 404, …)
///   headers  — dict  lowercased response header name → value (C)
///   body     — C   response body (already decompressed)
/// or an error `' if the request could not be completed (DNS/TLS/connection).
/// lib/http.k wraps this as http.get / post / put / del / request.

const std = @import("std");
const http = std.http;
const Uri = std.Uri;
const K = *anyopaque;

const KRegistry = @import("kabi").KRegistry(K);

const KApi = struct {
  ki:          *const fn (i32)                                       callconv(.c) ?K,
  kerr:        *const fn ()                                          callconv(.c) ?K,
  KC:          *const fn (i32)                                       callconv(.c) ?K,
  kn:          *const fn (?K)                                        callconv(.c) i32,
  kcp:         *const fn (?K)                                        callconv(.c) ?[*]u8,
  ku:          *const fn (?K)                                        callconv(.c) void,
  k_list_get:  *const fn (?K, i32)                                   callconv(.c) ?K,
  k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K)  callconv(.c) ?K,
  k_call:      *const fn (?K, ?K)                                    callconv(.c) ?K,
};
var g_api: ?KApi = null;

fn ki(n: i32) ?K        { return g_api.?.ki(n); }
fn kerr() ?K            { return g_api.?.kerr(); }
fn KC(n: i32) ?K        { return g_api.?.KC(n); }
fn kn(x: ?K) i32        { return g_api.?.kn(x); }
fn kcp(x: ?K) ?[*]u8    { return g_api.?.kcp(x); }
fn ku(x: ?K) void       { g_api.?.ku(x); }
fn klg(l: ?K, i: i32) ?K { return g_api.?.k_list_get(l, i); }
fn kcall(f: ?K, a: ?K) ?K { return g_api.?.k_call(f, a); }

const alloc = std.heap.c_allocator;
const Alloc = std.mem.Allocator;

fn bytes(x: ?K) []const u8 {
  const n = kn(x);
  if (n <= 0) return &[_]u8{};
  const p = kcp(x) orelse return &[_]u8{};
  return p[0..@intCast(n)];
}

fn outBytes(data: []const u8) ?K {
  const out = KC(@intCast(data.len)) orelse return null;
  if (data.len > 0) @memcpy(kcp(out).?[0..data.len], data);
  return out;
}

// Parsed request pieces, all arena-owned so they outlive the borrowed K args.
const Req = struct { method: http.Method, uri: Uri, extra: []const http.Header, body: []const u8 };

// Copy the byte payload of list element `i` into the arena (releasing the ref).
fn dupeField(arena: Alloc, list_k: ?K, i: i32) ?[]const u8 {
  const el = klg(list_k, i);
  defer ku(el);
  return arena.dupe(u8, bytes(el)) catch null;
}

// Parse a 4-element (method; url; headers; body) request list into a Req.
fn parseReq(arena: Alloc, arg_k: ?K) ?Req {
  if (kn(arg_k) < 4) return null;
  const method_s = dupeField(arena, arg_k, 0) orelse return null;
  const url_s    = dupeField(arena, arg_k, 1) orelse return null;
  const body_s   = dupeField(arena, arg_k, 3) orelse return null;
  const method = std.meta.stringToEnum(http.Method, method_s) orelse return null;
  const uri = Uri.parse(url_s) catch return null;

  const hdr_k = klg(arg_k, 2);
  defer ku(hdr_k);
  const nh: usize = @intCast(@max(0, kn(hdr_k)));
  var extra: std.ArrayList(http.Header) = .empty;
  var i: usize = 0;
  while (i + 1 < nh) : (i += 2) {
    const name = dupeField(arena, hdr_k, @intCast(i)) orelse return null;
    const value = dupeField(arena, hdr_k, @intCast(i + 1)) orelse return null;
    extra.append(arena, .{ .name = name, .value = value }) catch return null;
  }
  return .{ .method = method, .uri = uri, .extra = extra.items, .body = body_s };
}

// Send the request on an already-constructed client+request pair.
fn sendBody(req: *http.Client.Request, body: []const u8) !void {
  if (body.len > 0) {
    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();
  } else {
    try req.sendBodiless();
  }
}

// Response headers → dict K (names lowercased for predictable lookup).
fn headersDict(arena: Alloc, response: *http.Client.Response) !?K {
  var hkeys: std.ArrayList([*:0]const u8) = .empty;
  var hvals: std.ArrayList(?K) = .empty;
  errdefer for (hvals.items) |v| ku(v);
  var it = response.head.iterateHeaders();
  while (it.next()) |h| {
    const key = try arena.allocSentinel(u8, h.name.len, 0);
    for (h.name, 0..) |c, j| key[j] = std.ascii.toLower(c);
    const val = outBytes(h.value) orelse return error.OutOfMemory;
    try hkeys.append(arena, key.ptr);
    try hvals.append(arena, val);
  }
  const d = g_api.?.k_make_dict(@intCast(hkeys.items.len), hkeys.items.ptr, hvals.items.ptr);
  for (hvals.items) |v| ku(v); // dict took its own refs
  return d;
}

// HttpRequest (method; url; headers; body) → dict[status;headers;body] | error
export fn HttpRequest(arg_k: ?K) callconv(.c) ?K {
  var arena_state = std.heap.ArenaAllocator.init(alloc);
  defer arena_state.deinit();
  const arena = arena_state.allocator();
  const rq = parseReq(arena, arg_k) orelse return kerr();
  return doRequest(arena, rq) catch return kerr();
}

fn doRequest(arena: Alloc, rq: Req) !?K {
  const io = std.Io.Threaded.global_single_threaded.io();
  var client: http.Client = .{ .allocator = alloc, .io = io };
  defer client.deinit();
  const redirect: http.Client.Request.RedirectBehavior =
    if (rq.body.len > 0) .unhandled else @enumFromInt(3);
  var req = try client.request(rq.method, rq.uri, .{ .extra_headers = rq.extra, .redirect_behavior = redirect });
  defer req.deinit();
  try sendBody(&req, rq.body);

  var redirect_buffer: [8192]u8 = undefined;
  var response = try req.receiveHead(&redirect_buffer);
  const status: i32 = @intFromEnum(response.head.status);
  const hdict = (try headersDict(arena, &response)) orelse return error.OutOfMemory;

  const enc = response.head.content_encoding;
  const dbuf: []u8 = if (enc.minBufferCapacity() == 0) &.{} else try arena.alloc(u8, enc.minBufferCapacity());
  var transfer_buffer: [64]u8 = undefined;
  var decompress: http.Decompress = undefined;
  const reader = response.readerDecompressing(&transfer_buffer, &decompress, dbuf);
  const body_bytes = reader.allocRemaining(alloc, .unlimited) catch { ku(hdict); return error.ReadFailed; };
  defer alloc.free(body_bytes);
  const body_k = outBytes(body_bytes) orelse { ku(hdict); return error.OutOfMemory; };

  const rkeys = [_][*:0]const u8{ "status", "headers", "body" };
  const rvals = [_]?K{ ki(status), hdict, body_k };
  const result = g_api.?.k_make_dict(3, &rkeys, &rvals);
  ku(rvals[0]); ku(hdict); ku(body_k);
  return result orelse error.OutOfMemory;
}

// HttpStream [(method; url; headers; body); callback] — streams the response
// body to `callback` one line at a time (each C vector is a complete line, the
// trailing newline stripped; a final unterminated line is delivered too), then
// returns dict[status;headers] (no body — it went to the callback). The
// callback's return value is discarded. Line framing is done here (not in k) so
// the callback stays a simple per-line handler — this is what SSE wants, and it
// keeps the reentrant k_call callback allocation-light. Used for LLM streaming.
export fn HttpStream(arg_k: ?K, cb_k: ?K) callconv(.c) ?K {
  var arena_state = std.heap.ArenaAllocator.init(alloc);
  defer arena_state.deinit();
  const arena = arena_state.allocator();
  const rq = parseReq(arena, arg_k) orelse return kerr();
  return doStream(arena, rq, cb_k) catch return kerr();
}

fn doStream(arena: Alloc, rq: Req, cb_k: ?K) !?K {
  const io = std.Io.Threaded.global_single_threaded.io();
  var client: http.Client = .{ .allocator = alloc, .io = io };
  defer client.deinit();
  var req = try client.request(rq.method, rq.uri, .{ .extra_headers = rq.extra, .redirect_behavior = .unhandled });
  defer req.deinit();
  try sendBody(&req, rq.body);

  var redirect_buffer: [8192]u8 = undefined;
  var response = try req.receiveHead(&redirect_buffer);
  const status: i32 = @intFromEnum(response.head.status);
  const hdict = (try headersDict(arena, &response)) orelse return error.OutOfMemory;

  const enc = response.head.content_encoding;
  const dbuf: []u8 = if (enc.minBufferCapacity() == 0) &.{} else try arena.alloc(u8, enc.minBufferCapacity());
  var transfer_buffer: [64]u8 = undefined;
  var decompress: http.Decompress = undefined;
  const reader = response.readerDecompressing(&transfer_buffer, &decompress, dbuf);

  // Reframe the byte stream into lines and hand each complete line to the k
  // callback (newline stripped). Partial lines accumulate in `line` until their
  // terminator arrives.
  var line: std.ArrayList(u8) = .empty;
  defer line.deinit(alloc);
  while (reader.peekGreedy(1)) |chunk| {
    for (chunk) |byte| {
      if (byte == '\n') {
        const trimmed = std.mem.trimEnd(u8, line.items, "\r");
        const ck = outBytes(trimmed) orelse continue;
        const r = kcall(cb_k, ck);
        ku(ck);
        if (r) |rr| ku(rr);
        line.clearRetainingCapacity();
      } else {
        line.append(alloc, byte) catch {};
      }
    }
    reader.toss(chunk.len);
  } else |e| switch (e) {
    error.EndOfStream => {},
    else => { ku(hdict); return error.ReadFailed; },
  }
  // Flush a final unterminated line.
  if (line.items.len > 0) {
    const ck = outBytes(std.mem.trimEnd(u8, line.items, "\r"));
    if (ck) |c| { const r = kcall(cb_k, c); ku(c); if (r) |rr| ku(rr); }
  }

  const rkeys = [_][*:0]const u8{ "status", "headers" };
  const rvals = [_]?K{ ki(status), hdict };
  const result = g_api.?.k_make_dict(2, &rkeys, &rvals);
  ku(rvals[0]); ku(hdict);
  return result orelse error.OutOfMemory;
}

fn inkInit(reg: *anyopaque) void {
  const r: *const KRegistry = @ptrCast(@alignCast(reg));
  g_api = .{
    .ki = r.ki, .kerr = r.kerr, .KC = r.KC, .kn = r.kn, .kcp = r.kcp, .ku = r.ku,
    .k_list_get = r.k_list_get, .k_make_dict = r.k_make_dict, .k_call = r.k_call,
  };
  r.k_register("HttpRequest", @ptrCast(&HttpRequest), 1);
  r.k_register("HttpStream", @ptrCast(&HttpStream), 2);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
export fn ink_ext_init_http(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
