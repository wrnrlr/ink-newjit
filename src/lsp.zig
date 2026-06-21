// Minimal Language Server for ink, speaking LSP over stdio (JSON-RPC).
//
// Reuses the real lexer/parser (src/parser) so positions and tokenisation
// match the interpreter exactly.  Features:
//   - diagnostics      (parse errors, on open/change)
//   - documentSymbol   (top-level definitions)
//   - definition       (jump to a name's binding / lambda parameter)
//   - hover            (verb documentation; variable's defining line)
//
// Launch with:  ink lsp
const std = @import("std");
const lex = @import("parser/lexer.zig");
const Parser = @import("parser/parser.zig").Parser;
const Lexer = lex.Lexer;
const TT = lex.TT;
const Alloc = std.mem.Allocator;
const json = std.json;

// ── Verb documentation ──────────────────────────────────────────────────────
// Concise markdown for each primitive, distilled from AGENT.md.  Looked up by
// the operator glyph or keyword name under the cursor.
const Doc = struct { k: []const u8, v: []const u8 };
const VERB_DOCS = [_]Doc{
  .{ .k = ":", .v = "**Identity / Return** `:x` — return x  \n**Right** `x:y` — return y (also assignment: `n:v`)" },
  .{ .k = "+", .v = "**Flip** `+x` — transpose  \n**Add** `x+y`" },
  .{ .k = "-", .v = "**Negate** `-x`  \n**Subtract** `x-y`" },
  .{ .k = "*", .v = "**First** `*x` — first item  \n**Multiply** `x*y`" },
  .{ .k = "%", .v = "**Divide** `x%y` — float division" },
  .{ .k = "!", .v = "**Iota** `!i` — 0..i-1; **Odometer** `!I`  \n**Key** `x!y` — make dictionary; **Mod** via `mod`" },
  .{ .k = "&", .v = "**Where** `&I` — counts → indices  \n**Min/And** `x&y`" },
  .{ .k = "|", .v = "**Reverse** `|x`  \n**Max/Or** `x|y`" },
  .{ .k = "<", .v = "**Ascend** `<X` — grade-up indices  \n**Less** `x<y`" },
  .{ .k = ">", .v = "**Descend** `>X` — grade-down indices  \n**Greater** `x>y`" },
  .{ .k = "=", .v = "**Group** `=X`; **Unit** `=i` — identity matrix  \n**Equal** `x=y`" },
  .{ .k = "~", .v = "**Not** `~x` — logical negation  \n**Match** `x~y` — identity check" },
  .{ .k = ",", .v = "**Enlist** `,x` — wrap in list  \n**Join** `x,y` — concatenate / merge dicts" },
  .{ .k = "^", .v = "**Null** `^x` — null mask  \n**Fill** `x^y` — replace nulls; **Without** `X^y`" },
  .{ .k = "#", .v = "**Tally** `#x` — count  \n**Take** `x#y` — reshape/cycle; **Reshape** `I#y`" },
  .{ .k = "_", .v = "**Floor** `_x`  \n**Drop** `i_Y`; **Cut** `I_Y`; **WeedOut** `f_Y`; **Delete** `X_i`" },
  .{ .k = "$", .v = "**String** `$x`  \n**Pad** `i$C`; **Cast** `` s$y `` (e.g. `` `I$\"12\" ``)" },
  .{ .k = "?", .v = "**Distinct** `?X`; **Uniform** `?i` — random floats  \n**Find** `x?y`; **Roll/Deal** `i?x`" },
  .{ .k = "@", .v = "**Type** `@x`  \n**At/Apply** `x@y` — index / apply" },
  .{ .k = ".", .v = "**Value/Get** `.x`  \n**Dot/ApplyN** `x.y` — deep index / multi-arg apply" },
  .{ .k = "sqrt", .v = "**Square root** `sqrt n`" },
  .{ .k = "sqr", .v = "**Square** `sqr n`" },
  .{ .k = "exp", .v = "**Exponential** `exp n`" },
  .{ .k = "log", .v = "**Natural log** `log n`" },
  .{ .k = "sin", .v = "**Sine** `sin n`" },
  .{ .k = "cos", .v = "**Cosine** `cos n`" },
  .{ .k = "abs", .v = "**Absolute value** `abs n`" },
  .{ .k = "first", .v = "**First** `first x`" },
  .{ .k = "last", .v = "**Last** `last x`" },
  .{ .k = "count", .v = "**Count** `count x`" },
  .{ .k = "in", .v = "**In** `x in Y` — membership" },
  .{ .k = "has", .v = "**Has** `Y has x` — membership" },
  .{ .k = "mod", .v = "**Modulo** `x mod y` — remainder" },
  .{ .k = "div", .v = "**Integer division** `x div y` — floor(x÷y)" },
  .{ .k = "parse", .v = "**Parse** `parse s` — source → value" },
  .{ .k = "exec", .v = "**Exec** `exec s` — evaluate source" },
};
fn verbDoc(name: []const u8) ?[]const u8 {
  for (VERB_DOCS) |d| if (std.mem.eql(u8, d.k, name)) return d.v;
  return null;
}

// ── Server state ────────────────────────────────────────────────────────────
// A definition discovered in some workspace file (line/col precomputed).
const Loc = struct { uri: []u8, sl: u32, sc: u32, el: u32, ec: u32, kind: DefKind };

const Server = struct {
  gpa: Alloc,
  docs: std.StringHashMap([]u8),
  inbuf: std.ArrayList(u8),
  out: std.ArrayList(u8),
  parser: Parser,
  // Workspace-wide top-level definitions: name → locations across all .k files.
  windex: std.StringHashMap(std.ArrayList(Loc)),
  indexed: bool = false,
  shutdown: bool = false,

  fn init(gpa: Alloc) Server {
    return .{
      .gpa = gpa,
      .docs = std.StringHashMap([]u8).init(gpa),
      .inbuf = .empty,
      .out = .empty,
      .parser = Parser.init(gpa),
      .windex = std.StringHashMap(std.ArrayList(Loc)).init(gpa),
    };
  }
};

// ── stdio framing ───────────────────────────────────────────────────────────
fn readChunk(s: *Server) !bool {
  var tmp: [4096]u8 = undefined;
  const n = std.posix.read(std.posix.STDIN_FILENO, &tmp) catch |e| {
    if (e == error.Interrupted) return true;
    return e;
  };
  if (n == 0) return false; // EOF
  try s.inbuf.appendSlice(s.gpa, tmp[0..n]);
  return true;
}

// Pull one complete LSP message body out of inbuf, reading more as needed.
// Returns an owned slice (caller frees) or null on EOF.
fn nextMessage(s: *Server) !?[]u8 {
  while (true) {
    if (std.mem.indexOf(u8, s.inbuf.items, "\r\n\r\n")) |hdr_end| {
      // Parse Content-Length from the header block.
      var len: usize = 0;
      var line_it = std.mem.splitSequence(u8, s.inbuf.items[0..hdr_end], "\r\n");
      while (line_it.next()) |line| {
        const pfx = "Content-Length:";
        if (std.ascii.startsWithIgnoreCase(line, pfx)) {
          const v = std.mem.trim(u8, line[pfx.len..], " \t");
          len = std.fmt.parseInt(usize, v, 10) catch 0;
        }
      }
      const body_start = hdr_end + 4;
      if (s.inbuf.items.len >= body_start + len) {
        const body = try s.gpa.dupe(u8, s.inbuf.items[body_start .. body_start + len]);
        // Drop consumed bytes from the front of inbuf.
        const rest = s.inbuf.items[body_start + len ..];
        std.mem.copyForwards(u8, s.inbuf.items[0..rest.len], rest);
        s.inbuf.shrinkRetainingCapacity(rest.len);
        return body;
      }
    }
    if (!try readChunk(s)) return null;
  }
}

fn writeAll(bytes: []const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

// Send a framed message whose body is the current contents of s.out.
fn flush(s: *Server) !void {
  var hdr: [64]u8 = undefined;
  const h = try std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{s.out.items.len});
  try writeAll(h);
  try writeAll(s.out.items);
  s.out.clearRetainingCapacity();
}

// ── JSON helpers ────────────────────────────────────────────────────────────
fn obj(v: ?json.Value, key: []const u8) ?json.Value {
  const vv = v orelse return null;
  if (vv != .object) return null;
  return vv.object.get(key);
}
fn str(v: ?json.Value) ?[]const u8 {
  const vv = v orelse return null;
  return if (vv == .string) vv.string else null;
}
fn int(v: ?json.Value) ?i64 {
  const vv = v orelse return null;
  return if (vv == .integer) vv.integer else null;
}

fn escapeInto(out: *std.ArrayList(u8), gpa: Alloc, sIn: []const u8) !void {
  for (sIn) |c| switch (c) {
    '"' => try out.appendSlice(gpa, "\\\""),
    '\\' => try out.appendSlice(gpa, "\\\\"),
    '\n' => try out.appendSlice(gpa, "\\n"),
    '\r' => try out.appendSlice(gpa, "\\r"),
    '\t' => try out.appendSlice(gpa, "\\t"),
    else => if (c < 0x20) {
      var b: [8]u8 = undefined;
      try out.appendSlice(gpa, try std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}));
    } else try out.append(gpa, c),
  };
}

fn p(s: *Server, comptime fmt: []const u8, args: anytype) !void {
  const txt = try std.fmt.allocPrint(s.gpa, fmt, args);
  defer s.gpa.free(txt);
  try s.out.appendSlice(s.gpa, txt);
}

// Append the request id verbatim (number or string).
fn writeId(s: *Server, id: ?json.Value) !void {
  const v = id orelse { try s.out.appendSlice(s.gpa, "null"); return; };
  switch (v) {
    .integer => |n| try p(s, "{d}", .{n}),
    .string => |st| { try s.out.append(s.gpa, '"'); try escapeInto(&s.out, s.gpa, st); try s.out.append(s.gpa, '"'); },
    else => try s.out.appendSlice(s.gpa, "null"),
  }
}

// ── position mapping (ASCII; k source is ASCII) ─────────────────────────────
fn posToOffset(src: []const u8, line: i64, character: i64) usize {
  var ln: i64 = 0;
  var i: usize = 0;
  while (i < src.len and ln < line) : (i += 1) {
    if (src[i] == '\n') ln += 1;
  }
  var col: i64 = 0;
  while (i < src.len and col < character and src[i] != '\n') : (i += 1) col += 1;
  return i;
}
const LineCol = struct { line: u32, col: u32 };
fn offsetToPos(src: []const u8, off: usize) LineCol {
  var line: u32 = 0;
  var last_nl: usize = 0;
  var i: usize = 0;
  while (i < off and i < src.len) : (i += 1) {
    if (src[i] == '\n') { line += 1; last_nl = i + 1; }
  }
  return .{ .line = line, .col = @intCast(off - last_nl) };
}

// ── token scanning ──────────────────────────────────────────────────────────
fn isIdentChar(c: u8) bool { return std.ascii.isAlphanumeric(c) or c == '.'; }

// Find the lexer token whose span covers byte offset `off`.
fn tokenAt(src: []const u8, off: usize) ?lex.Token {
  var l = Lexer.init(src);
  while (true) {
    const t = l.next();
    if (t.tt == .eof) return null;
    if (off >= t.start and off < t.end) return t;
    if (t.start > off) return null;
  }
}

const DefKind = enum { variable, function };
const Def = struct { name: []const u8, start: usize, end: usize, kind: DefKind, toplevel: bool };

// Collect bindings: an `iden` immediately followed by `:` (or `::`).  Also marks
// whether the binding is at top level (statement head, bracket depth 0) and
// whether the value is a lambda (→ function).
fn collectDefs(gpa: Alloc, src: []const u8) !std.ArrayList(Def) {
  var defs: std.ArrayList(Def) = .empty;
  var l = Lexer.init(src);
  var depth: i32 = 0;
  var prev: ?lex.Token = null;
  var prev_head = false; // was `prev` the first token of its statement?
  var first = true;
  while (true) {
    const t = l.next();
    if (t.tt == .eof) break;
    const head = first or (prev != null and prev.?.tt == .sep);
    first = false;
    switch (t.tt) {
      .@"(", .@"{", .@"[", .@"$[", .@"[[]", .@"[[" => depth += 1,
      .@")", .@"}", .@"]" => depth -= 1,
      else => {},
    }
    if (t.tt == .@":") {
      if (prev) |pt| if (pt.tt == .iden) {
        // Peek whether the value is a lambda → classify as a function.
        const is_fn = l.peekNext().tt == .@"{";
        try defs.append(gpa, .{
          .name = pt.slice(src),
          .start = pt.start,
          .end = pt.end,
          .kind = if (is_fn) .function else .variable,
          .toplevel = prev_head and depth == 0,
        });
      };
    }
    prev = t;
    prev_head = head;
  }
  return defs;
}

// ── workspace definition index ──────────────────────────────────────────────
// Decode a file:// URI to a filesystem path (minimal percent-decoding).
fn uriToPath(gpa: Alloc, uri: []const u8) ![]u8 {
  var raw = uri;
  if (std.mem.startsWith(u8, raw, "file://")) raw = raw[7..];
  var out: std.ArrayList(u8) = .empty;
  var i: usize = 0;
  while (i < raw.len) : (i += 1) {
    if (raw[i] == '%' and i + 2 < raw.len) {
      const hi = std.fmt.charToDigit(raw[i + 1], 16) catch { try out.append(gpa, raw[i]); continue; };
      const lo = std.fmt.charToDigit(raw[i + 2], 16) catch { try out.append(gpa, raw[i]); continue; };
      try out.append(gpa, hi * 16 + lo);
      i += 2;
    } else try out.append(gpa, raw[i]);
  }
  return out.toOwnedSlice(gpa);
}

fn shouldSkipDir(name: []const u8) bool {
  const skip = [_][]const u8{ ".git", "zig-cache", ".zig-cache", "zig-out", "node_modules", "target", ".jj" };
  for (skip) |sd| if (std.mem.eql(u8, name, sd)) return true;
  return name.len > 0 and name[0] == '.';
}

fn indexFile(s: *Server, abs_path: []const u8) void {
  const io = std.Io.Threaded.global_single_threaded.io();
  const text = std.Io.Dir.cwd().readFileAlloc(io, abs_path, s.gpa, std.Io.Limit.limited(4 * 1024 * 1024)) catch return;
  defer s.gpa.free(text);
  var defs = collectDefs(s.gpa, text) catch return;
  defer defs.deinit(s.gpa);
  const uri = std.fmt.allocPrint(s.gpa, "file://{s}", .{abs_path}) catch return;
  var uri_used = false;
  defer if (!uri_used) s.gpa.free(uri);
  for (defs.items) |d| {
    if (!d.toplevel) continue;
    const gop = s.windex.getOrPut(d.name) catch continue;
    if (!gop.found_existing) {
      gop.key_ptr.* = s.gpa.dupe(u8, d.name) catch continue;
      gop.value_ptr.* = .empty;
    }
    const loc_uri = if (uri_used) (s.gpa.dupe(u8, uri) catch continue) else uri;
    uri_used = true;
    const a = offsetToPos(text, d.start);
    const b = offsetToPos(text, d.end);
    gop.value_ptr.append(s.gpa, .{ .uri = loc_uri, .sl = a.line, .sc = a.col, .el = b.line, .ec = b.col, .kind = d.kind }) catch {};
  }
}

fn indexDir(s: *Server, abs_dir: []const u8, depth: u8) void {
  if (depth > 8) return;
  const io = std.Io.Threaded.global_single_threaded.io();
  var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, abs_dir, .{ .iterate = true }) catch return;
  defer dir.close(io);
  var it = dir.iterate();
  while (it.next(io) catch null) |entry| {
    const child = std.fmt.allocPrint(s.gpa, "{s}/{s}", .{ abs_dir, entry.name }) catch continue;
    defer s.gpa.free(child);
    if (entry.kind == .directory) {
      if (shouldSkipDir(entry.name)) continue;
      indexDir(s, child, depth + 1);
    } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".k")) {
      indexFile(s, child);
    }
  }
}

fn buildWorkspaceIndex(s: *Server, root_uri: ?[]const u8) void {
  if (s.indexed) return;
  s.indexed = true;
  const uri = root_uri orelse return;
  const path = uriToPath(s.gpa, uri) catch return;
  defer s.gpa.free(path);
  indexDir(s, path, 0);
}

// ── request handlers ────────────────────────────────────────────────────────
fn replyResult(s: *Server, id: ?json.Value, comptime result_fmt: []const u8, args: anytype) !void {
  try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
  try writeId(s, id);
  try s.out.appendSlice(s.gpa, ",\"result\":");
  try p(s, result_fmt, args);
  try s.out.append(s.gpa, '}');
  try flush(s);
}

fn handleInitialize(s: *Server, id: ?json.Value, params: ?json.Value) !void {
  // Build the cross-file definition index from the workspace root.
  var root = str(obj(params, "rootUri"));
  if (root == null) {
    if (obj(params, "workspaceFolders")) |wf| if (wf == .array and wf.array.items.len > 0)
      { root = str(obj(wf.array.items[0], "uri")); };
  }
  buildWorkspaceIndex(s, root);
  try replyResult(s, id,
    \\{{"capabilities":{{"textDocumentSync":1,"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true}},"serverInfo":{{"name":"ink-lsp","version":"0.1.0"}}}}
  , .{});
}

fn docText(s: *Server, uri: []const u8) ?[]const u8 {
  return s.docs.get(uri);
}

fn upsertDoc(s: *Server, uri: []const u8, text: []const u8) !void {
  const gop = try s.docs.getOrPut(uri);
  if (gop.found_existing) {
    s.gpa.free(gop.value_ptr.*);
  } else {
    gop.key_ptr.* = try s.gpa.dupe(u8, uri);
  }
  gop.value_ptr.* = try s.gpa.dupe(u8, text);
}

fn publishDiagnostics(s: *Server, uri: []const u8) !void {
  const src = docText(s, uri) orelse return;
  try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
  try escapeInto(&s.out, s.gpa, uri);
  try s.out.appendSlice(s.gpa, "\",\"diagnostics\":[");
  if (s.parser.parse(src)) |_| {
    // ok — no diagnostics
  } else |_| {
    const t = s.parser.tok;
    const a = offsetToPos(src, t.start);
    const b = offsetToPos(src, if (t.end > t.start) t.end else t.start + 1);
    try p(s, "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":1,\"source\":\"ink\",\"message\":\"unexpected token\"}}",
      .{ a.line, a.col, b.line, b.col });
  }
  try s.out.appendSlice(s.gpa, "]}}");
  try flush(s);
}

fn handleHover(s: *Server, id: ?json.Value, params: ?json.Value) !void {
  const uri = str(obj(obj(params, "textDocument"), "uri")) orelse return replyResult(s, id, "null", .{});
  const src = docText(s, uri) orelse return replyResult(s, id, "null", .{});
  const pos = obj(params, "position");
  const off = posToOffset(src, int(obj(pos, "line")) orelse 0, int(obj(pos, "character")) orelse 0);
  const t = tokenAt(src, off) orelse return replyResult(s, id, "null", .{});
  const word = t.slice(src);
  if (t.tt == .op or t.tt == .keyword) {
    if (verbDoc(word)) |md| {
      try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
      try writeId(s, id);
      try s.out.appendSlice(s.gpa, ",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
      try escapeInto(&s.out, s.gpa, md);
      try s.out.appendSlice(s.gpa, "\"}}}");
      return flush(s);
    }
  }
  if (t.tt == .iden) {
    var defs = try collectDefs(s.gpa, src);
    defer defs.deinit(s.gpa);
    for (defs.items) |d| if (std.mem.eql(u8, d.name, word)) {
      const ln = offsetToPos(src, d.start).line;
      const kindstr = if (d.kind == .function) "function" else "variable";
      var b: [256]u8 = undefined;
      return replyHoverMd(s, id, try std.fmt.bufPrint(&b, "**{s}** `{s}` — defined at line {d}", .{ kindstr, d.name, ln + 1 }));
    };
    // Cross-file: report where the workspace index found it.
    if (s.windex.get(word)) |locs| if (locs.items.len > 0) {
      const l0 = locs.items[0];
      const file = std.fs.path.basename(l0.uri);
      const kindstr = if (l0.kind == .function) "function" else "variable";
      var b: [512]u8 = undefined;
      return replyHoverMd(s, id, try std.fmt.bufPrint(&b, "**{s}** `{s}` — defined in `{s}` (line {d})", .{ kindstr, word, file, l0.sl + 1 }));
    };
  }
  return replyResult(s, id, "null", .{});
}

fn replyHoverMd(s: *Server, id: ?json.Value, md: []const u8) !void {
  try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
  try writeId(s, id);
  try s.out.appendSlice(s.gpa, ",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
  try escapeInto(&s.out, s.gpa, md);
  try s.out.appendSlice(s.gpa, "\"}}}");
  try flush(s);
}

fn replyLocation(s: *Server, id: ?json.Value, uri: []const u8, sl: u32, sc: u32, el: u32, ec: u32) !void {
  try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
  try writeId(s, id);
  try s.out.appendSlice(s.gpa, ",\"result\":{\"uri\":\"");
  try escapeInto(&s.out, s.gpa, uri);
  try p(s, "\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}}}",
    .{ sl, sc, el, ec });
  try flush(s);
}

fn handleDefinition(s: *Server, id: ?json.Value, params: ?json.Value) !void {
  const uri = str(obj(obj(params, "textDocument"), "uri")) orelse return replyResult(s, id, "null", .{});
  const src = docText(s, uri) orelse return replyResult(s, id, "null", .{});
  const pos = obj(params, "position");
  const off = posToOffset(src, int(obj(pos, "line")) orelse 0, int(obj(pos, "character")) orelse 0);
  const t = tokenAt(src, off) orelse return replyResult(s, id, "null", .{});
  if (t.tt != .iden) return replyResult(s, id, "null", .{});
  const word = t.slice(src);

  // 1. In-file: prefer the nearest definition at or before the cursor.
  var defs = try collectDefs(s.gpa, src);
  defer defs.deinit(s.gpa);
  var best: ?Def = null;
  for (defs.items) |d| {
    if (!std.mem.eql(u8, d.name, word)) continue;
    if (best == null or d.start <= t.start) best = d;
  }
  if (best) |d| {
    const a = offsetToPos(src, d.start);
    const b = offsetToPos(src, d.end);
    return replyLocation(s, id, uri, a.line, a.col, b.line, b.col);
  }

  // 2. Cross-file: consult the workspace index (modules, libs, other files).
  if (s.windex.get(word)) |locs| {
    if (locs.items.len > 0) {
      const l0 = locs.items[0];
      return replyLocation(s, id, l0.uri, l0.sl, l0.sc, l0.el, l0.ec);
    }
  }
  return replyResult(s, id, "null", .{});
}

fn handleDocumentSymbol(s: *Server, id: ?json.Value, params: ?json.Value) !void {
  const uri = str(obj(obj(params, "textDocument"), "uri")) orelse return replyResult(s, id, "[]", .{});
  const src = docText(s, uri) orelse return replyResult(s, id, "[]", .{});
  var defs = try collectDefs(s.gpa, src);
  defer defs.deinit(s.gpa);
  try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
  try writeId(s, id);
  try s.out.appendSlice(s.gpa, ",\"result\":[");
  var first = true;
  for (defs.items) |d| {
    if (!d.toplevel) continue;
    const a = offsetToPos(src, d.start);
    const b = offsetToPos(src, d.end);
    if (!first) try s.out.append(s.gpa, ',');
    first = false;
    // SymbolKind: Function=12, Variable=13
    const kind: u8 = if (d.kind == .function) 12 else 13;
    try s.out.appendSlice(s.gpa, "{\"name\":\"");
    try escapeInto(&s.out, s.gpa, d.name);
    try p(s, "\",\"kind\":{d},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
      .{ kind, a.line, a.col, b.line, b.col, a.line, a.col, b.line, b.col });
  }
  try s.out.appendSlice(s.gpa, "]}");
  try flush(s);
}

fn handle(s: *Server, root: json.Value) !void {
  const method = str(obj(root, "method")) orelse return;
  const id = obj(root, "id");
  const params = obj(root, "params");

  if (std.mem.eql(u8, method, "initialize")) {
    try handleInitialize(s, id, params);
  } else if (std.mem.eql(u8, method, "initialized")) {
    // no-op
  } else if (std.mem.eql(u8, method, "shutdown")) {
    s.shutdown = true;
    try replyResult(s, id, "null", .{});
  } else if (std.mem.eql(u8, method, "exit")) {
    s.shutdown = true;
  } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
    const td = obj(params, "textDocument");
    if (str(obj(td, "uri"))) |uri| if (str(obj(td, "text"))) |text| {
      try upsertDoc(s, uri, text);
      try publishDiagnostics(s, uri);
    };
  } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
    const uri = str(obj(obj(params, "textDocument"), "uri"));
    const changes = obj(params, "contentChanges");
    if (uri != null and changes != null and changes.? == .array) {
      const arr = changes.?.array;
      if (arr.items.len > 0) {
        // full sync: last change holds the whole document
        if (str(obj(arr.items[arr.items.len - 1], "text"))) |text| {
          try upsertDoc(s, uri.?, text);
          try publishDiagnostics(s, uri.?);
        }
      }
    }
  } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
    if (str(obj(obj(params, "textDocument"), "uri"))) |uri| {
      if (s.docs.fetchRemove(uri)) |kv| { s.gpa.free(kv.key); s.gpa.free(kv.value); }
    }
  } else if (std.mem.eql(u8, method, "textDocument/hover")) {
    try handleHover(s, id, params);
  } else if (std.mem.eql(u8, method, "textDocument/definition")) {
    try handleDefinition(s, id, params);
  } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
    try handleDocumentSymbol(s, id, params);
  } else if (id != null) {
    // Unknown request — reply null so the client doesn't hang.
    try replyResult(s, id, "null", .{});
  }
}

pub fn run(gpa: Alloc) !void {
  var s = Server.init(gpa);
  while (!s.shutdown) {
    const body = (try nextMessage(&s)) orelse break;
    defer gpa.free(body);
    var parsed = json.parseFromSlice(json.Value, gpa, body, .{}) catch continue;
    defer parsed.deinit();
    handle(&s, parsed.value) catch |e| {
      std.log.scoped(.lsp).err("handler error: {s}", .{@errorName(e)});
    };
  }
}
