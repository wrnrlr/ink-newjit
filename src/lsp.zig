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
// `m` is the monadic sense, `d` the dyadic sense; either may be absent when the
// verb only has one valence.  Hover picks the one matching the syntactic arity
// at the cursor (see `dyadicHere`), so it never shows both at once.
const Doc = struct { k: []const u8, m: ?[]const u8 = null, d: ?[]const u8 = null };
const VERB_DOCS = [_]Doc{
  .{ .k = ":", .m = "**Identity / Return** `:x` — return x", .d = "**Right** `x:y` — return y (also assignment: `n:v`)" },
  .{ .k = "+", .m = "**Flip** `+x` — transpose", .d = "**Add** `x+y`" },
  .{ .k = "-", .m = "**Negate** `-x`", .d = "**Subtract** `x-y`" },
  .{ .k = "*", .m = "**First** `*x` — first item", .d = "**Multiply** `x*y`" },
  .{ .k = "%", .d = "**Divide** `x%y` — float division" },
  .{ .k = "!", .m = "**Iota** `!i` — 0..i-1; **Odometer** `!I`", .d = "**Key** `x!y` — make dictionary; **Mod** via `mod`" },
  .{ .k = "&", .m = "**Where** `&I` — counts → indices", .d = "**Min/And** `x&y`" },
  .{ .k = "|", .m = "**Reverse** `|x`", .d = "**Max/Or** `x|y`" },
  .{ .k = "<", .m = "**Ascend** `<X` — grade-up indices", .d = "**Less** `x<y`" },
  .{ .k = ">", .m = "**Descend** `>X` — grade-down indices", .d = "**Greater** `x>y`" },
  .{ .k = "=", .m = "**Group** `=X`; **Unit** `=i` — identity matrix", .d = "**Equal** `x=y`" },
  .{ .k = "~", .m = "**Not** `~x` — logical negation", .d = "**Match** `x~y` — identity check" },
  .{ .k = ",", .m = "**Enlist** `,x` — wrap in list", .d = "**Join** `x,y` — concatenate / merge dicts" },
  .{ .k = "^", .m = "**Null** `^x` — null mask", .d = "**Fill** `x^y` — replace nulls; **Without** `X^y`" },
  .{ .k = "#", .m = "**Tally** `#x` — count", .d = "**Take** `x#y` — reshape/cycle; **Reshape** `I#y`" },
  .{ .k = "_", .m = "**Floor** `_x`", .d = "**Drop** `i_Y`; **Cut** `I_Y`; **WeedOut** `f_Y`; **Delete** `X_i`" },
  .{ .k = "$", .m = "**String** `$x`", .d = "**Pad** `i$C`; **Cast** `` s$y `` (e.g. `` `I$\"12\" ``)" },
  .{ .k = "?", .m = "**Distinct** `?X`; **Uniform** `?i` — random floats", .d = "**Find** `x?y`; **Roll/Deal** `i?x`" },
  .{ .k = "@", .m = "**Type** `@x`", .d = "**At/Apply** `x@y` — index / apply" },
  .{ .k = ".", .m = "**Value/Get** `.x`", .d = "**Dot/ApplyN** `x.y` — deep index / multi-arg apply" },
  .{ .k = "sqrt", .m = "**Square root** `sqrt n`" },
  .{ .k = "sqr", .m = "**Square** `sqr n`" },
  .{ .k = "exp", .m = "**Exponential** `exp n`" },
  .{ .k = "log", .m = "**Natural log** `log n`" },
  .{ .k = "sin", .m = "**Sine** `sin n`" },
  .{ .k = "cos", .m = "**Cosine** `cos n`" },
  .{ .k = "abs", .m = "**Absolute value** `abs n`" },
  .{ .k = "first", .m = "**First** `first x`" },
  .{ .k = "last", .m = "**Last** `last x`" },
  .{ .k = "count", .m = "**Count** `count x`" },
  .{ .k = "in", .d = "**In** `x in Y` — membership" },
  .{ .k = "has", .d = "**Has** `Y has x` — membership" },
  .{ .k = "mod", .d = "**Modulo** `x mod y` — remainder" },
  .{ .k = "div", .d = "**Integer division** `x div y` — floor(x÷y)" },
  .{ .k = "parse", .m = "**Parse** `parse s` — source → value" },
  .{ .k = "exec", .m = "**Exec** `exec s` — evaluate source" },
};

// I/O verbs (`0:` `1:` `2:`…) — lexed as a single `.io` token.  Monadic reads,
// dyadic writes (see AGENT.md “IO Verbs”).
const IO_DOCS = [_]Doc{
  .{ .k = "0:", .m = "**Read line** `0:x` — read lines from stdin / a file", .d = "**Write line** `x 0:y` — write text (`` `0 0:\"Hi\" ``)" },
  .{ .k = "1:", .m = "**Read bytes** `1:x`", .d = "**Write bytes** `x 1:y`" },
  .{ .k = "2:", .m = "**Load code** `2:y` — import another file", .d = "**Load code** `2:y` — import another file" },
};

fn verbDoc(name: []const u8) ?Doc {
  for (VERB_DOCS) |d| if (std.mem.eql(u8, d.k, name)) return d;
  return null;
}
fn ioDoc(name: []const u8) ?Doc {
  for (IO_DOCS) |d| if (std.mem.eql(u8, d.k, name)) return d;
  return null;
}

// Pick the sense matching the syntactic arity, falling back to the other valence
// when the verb only documents one (e.g. monadic `sqrt`, dyadic `mod`).
fn senseFor(d: Doc, dyadic: bool) ?[]const u8 {
  return if (dyadic) (d.d orelse d.m) else (d.m orelse d.d);
}

// A verb is dyadic iff a noun value sits immediately to its left — exactly the
// lexer's `tag == .noun` rule (these token kinds terminate a noun phrase).
fn dyadicHere(prev: ?lex.Token) bool {
  const pt = prev orelse return false;
  return switch (pt.tt) {
    .int, .float, .bit, .bits, .string, .symbol, .iden,
    .@")", .@"}", .@"]", .adverb_val => true,
    else => false,
  };
}

// Adverbs are polysemic: the actual sense depends on whether the *derived* verb
// is applied monadically (`F/x` — no left argument) or dyadically (`x F/y` — a
// left argument is present), plus operand type.  We split the senses into those
// two groups so hover/definition can narrow by call-site (see `adverbApplication`)
// instead of always dumping every meaning.  `/:` and `\:` are inherently dyadic,
// so their `mono` group is empty.
const AForm = struct { name: []const u8, sig: []const u8 };
const AdverbInfo = struct { k: []const u8, mono: []const AForm, dyad: []const AForm };
const ADVERBS = [_]AdverbInfo{
  .{ .k = "'",
     .mono = &.{ .{ .name = "Each", .sig = "f'x" } },
     .dyad = &.{ .{ .name = "Zip", .sig = "x F'y" } } },
  .{ .k = "/",
     .mono = &.{ .{ .name = "Fold", .sig = "F/x" }, .{ .name = "Decode", .sig = "I/x" }, .{ .name = "Join", .sig = "C/x" }, .{ .name = "Converge", .sig = "f/x" } },
     .dyad = &.{ .{ .name = "SeededFold", .sig = "x F/y" }, .{ .name = "N-Do", .sig = "i f/y" }, .{ .name = "While", .sig = "f f/y" } } },
  .{ .k = "\\",
     .mono = &.{ .{ .name = "Scan", .sig = "F\\x" }, .{ .name = "Encode", .sig = "I\\x" }, .{ .name = "Split", .sig = "C\\x" }, .{ .name = "Converges", .sig = "f\\x" } },
     .dyad = &.{ .{ .name = "SeededScan", .sig = "x F\\y" }, .{ .name = "N-Dos", .sig = "i f\\y" }, .{ .name = "Whiles", .sig = "f f\\y" } } },
  .{ .k = "':",
     .mono = &.{ .{ .name = "Eachprior", .sig = "F':x" }, .{ .name = "Window", .sig = "i':x" } },
     .dyad = &.{ .{ .name = "Stencil", .sig = "i f':x" } } },
  .{ .k = "/:",
     .mono = &.{},
     .dyad = &.{ .{ .name = "Eachright", .sig = "x F/:y — fix the left arg, map over the right" } } },
  .{ .k = "\\:",
     .mono = &.{},
     .dyad = &.{ .{ .name = "Eachleft", .sig = "x F\\:y — fix the right arg, map over the left" } } },
};
fn adverbInfo(name: []const u8) ?AdverbInfo {
  for (ADVERBS) |a| if (std.mem.eql(u8, a.k, name)) return a;
  return null;
}

// How the derived verb at the cursor is being applied — drives which senses to
// surface.  `.dyadic` means a left argument is present (`x F/y`); `.monadic`
// means the adverb has an operand but no left arg (`F/x`); `.standalone` means
// it sits as a bare value / partial (`f: /`, `(+/;…)` head) where we can't tell.
const AdverbApp = enum { standalone, monadic, dyadic };

// Build the hover markdown for an adverb, narrowed to the senses possible at the
// call site.  Caller frees.
fn adverbHoverMd(gpa: Alloc, info: AdverbInfo, app: AdverbApp) ![]u8 {
  // Choose the sense group; fall back to the union when the chosen group is empty.
  const group: []const AForm = switch (app) {
    .dyadic => if (info.dyad.len > 0) info.dyad else info.mono,
    .monadic => if (info.mono.len > 0) info.mono else info.dyad,
    .standalone => &.{},
  };
  var md: std.ArrayList(u8) = .empty;
  errdefer md.deinit(gpa);
  const head: []const u8 = switch (app) {
    .dyadic => "— with a left argument it is one of:",
    .monadic => "— applied monadically it is one of:",
    .standalone => "— a bare adverb value; depending on use it is one of:",
  };
  try md.appendSlice(gpa, "**`");
  try md.appendSlice(gpa, info.k);
  try md.appendSlice(gpa, "`** ");
  try md.appendSlice(gpa, head);
  try md.appendSlice(gpa, "\n\n");
  if (app == .standalone) {
    try appendForms(gpa, &md, info.mono);
    if (info.mono.len > 0 and info.dyad.len > 0) try md.appendSlice(gpa, " · ");
    try appendForms(gpa, &md, info.dyad);
  } else {
    try appendForms(gpa, &md, group);
  }
  return md.toOwnedSlice(gpa);
}
fn appendForms(gpa: Alloc, md: *std.ArrayList(u8), forms: []const AForm) !void {
  for (forms, 0..) |f, i| {
    if (i > 0) try md.appendSlice(gpa, " · ");
    try md.appendSlice(gpa, "**");
    try md.appendSlice(gpa, f.name);
    try md.appendSlice(gpa, "** `");
    try md.appendSlice(gpa, f.sig);
    try md.appendSlice(gpa, "`");
  }
}

// Fused reduce idioms — verb immediately followed by `/` (see fuse.zig).
fn fusedReduceDoc(op: []const u8) ?[]const u8 {
  if (std.mem.eql(u8, op, "+")) return "**Sum** `+/x` — total of x *(fused reduce)*";
  if (std.mem.eql(u8, op, "*")) return "**Product** `*/x` — product of x *(fused reduce)*";
  if (std.mem.eql(u8, op, "&")) return "**Minimum / All** `&/x` — least element; logical all *(fused reduce)*";
  if (std.mem.eql(u8, op, "|")) return "**Maximum / Any** `|/x` — greatest element; logical any *(fused reduce)*";
  return null;
}

// ── builtin glyph reference ─────────────────────────────────────────────────
// Primitives have no source definition, so `workspace/symbol` (Zed's cmd-t)
// can't find them by scanning files.  We list them here with a one-line gloss
// and, on `initialize`, write them to a generated reference file so each glyph
// resolves to a real location the editor can open.  `doc` is matched by the
// query too, so the user can search by meaning ("last" → `*|`, "sum" → `+/`).
// The gloss is a single line: it becomes a `/`-comment in the reference file.
const Builtin = struct { sym: []const u8, doc: []const u8 };
const BUILTINS = [_]Builtin{
  // Operators (monadic · dyadic — arity is only known at a call site).
  .{ .sym = ":",  .doc = "Identity/Return :x · Right/Assign x:y" },
  .{ .sym = "+",  .doc = "Flip +x (transpose) · Add x+y" },
  .{ .sym = "-",  .doc = "Negate -x · Subtract x-y" },
  .{ .sym = "*",  .doc = "First *x · Multiply x*y" },
  .{ .sym = "%",  .doc = "Divide x%y (float division)" },
  .{ .sym = "!",  .doc = "Iota/Odometer !x · Key (dict) x!y" },
  .{ .sym = "&",  .doc = "Where &x · Min/And x&y" },
  .{ .sym = "|",  .doc = "Reverse |x · Max/Or x|y" },
  .{ .sym = "<",  .doc = "Ascend (grade up) <x · Less x<y" },
  .{ .sym = ">",  .doc = "Descend (grade down) >x · Greater x>y" },
  .{ .sym = "=",  .doc = "Group/Unit =x · Equal x=y" },
  .{ .sym = "~",  .doc = "Not ~x · Match x~y" },
  .{ .sym = ",",  .doc = "Enlist ,x · Join x,y" },
  .{ .sym = "^",  .doc = "Null ^x · Fill/Without x^y" },
  .{ .sym = "#",  .doc = "Tally #x · Take/Reshape x#y" },
  .{ .sym = "_",  .doc = "Floor _x · Drop/Cut/WeedOut/Delete x_y" },
  .{ .sym = "$",  .doc = "String $x · Pad/Cast x$y" },
  .{ .sym = "?",  .doc = "Distinct/Uniform ?x · Find/Roll x?y" },
  .{ .sym = "@",  .doc = "Type @x · At/Apply (index) x@y" },
  .{ .sym = ".",  .doc = "Value/Get .x · Dot/ApplyN (deep index) x.y" },
  // Keyword verbs.
  .{ .sym = "sqrt",  .doc = "Square root  sqrt n" },
  .{ .sym = "sqr",   .doc = "Square  sqr n" },
  .{ .sym = "exp",   .doc = "Exponential  exp n" },
  .{ .sym = "log",   .doc = "Natural log  log n" },
  .{ .sym = "sin",   .doc = "Sine  sin n" },
  .{ .sym = "cos",   .doc = "Cosine  cos n" },
  .{ .sym = "abs",   .doc = "Absolute value  abs n" },
  .{ .sym = "first", .doc = "First  first x" },
  .{ .sym = "last",  .doc = "Last  last x" },
  .{ .sym = "count", .doc = "Count  count x" },
  .{ .sym = "in",    .doc = "In (membership)  x in Y" },
  .{ .sym = "has",   .doc = "Has (membership)  Y has x" },
  .{ .sym = "mod",   .doc = "Modulo  x mod y" },
  .{ .sym = "div",   .doc = "Integer division  x div y" },
  .{ .sym = "parse", .doc = "Parse source → value  parse s" },
  .{ .sym = "exec",  .doc = "Evaluate source  exec s" },
  // Adverbs.
  .{ .sym = "'",  .doc = "Each f'x · Zip x F'y" },
  .{ .sym = "/",  .doc = "Fold/Decode/Join/N-do/While/Converge  F/" },
  .{ .sym = "\\", .doc = "Scan/Encode/Split/N-dos/Whiles/Converges  F\\" },
  .{ .sym = "':", .doc = "Eachprior/Window/Stencil  F':x" },
  .{ .sym = "/:", .doc = "Eachright (fix left, map right)  x F/:y" },
  .{ .sym = "\\:", .doc = "Eachleft (fix right, map left)  x F\\:y" },
  // I/O verbs.
  .{ .sym = "0:", .doc = "Read line 0:x · Write line x 0:y" },
  .{ .sym = "1:", .doc = "Read bytes 1:x · Write bytes x 1:y" },
  .{ .sym = "2:", .doc = "Load code (import file)  2:y" },
  // Fused reductions (verb glued to /, see fuse.zig).
  .{ .sym = "+/", .doc = "Sum +/x (fused reduce)" },
  .{ .sym = "*/", .doc = "Product */x (fused reduce)" },
  .{ .sym = "&/", .doc = "Minimum / All &/x (fused reduce)" },
  .{ .sym = "|/", .doc = "Maximum / Any |/x (fused reduce)" },
  // Idioms / trains.
  .{ .sym = "*|", .doc = "Last *|x — last element (first of reverse)" },
  .{ .sym = ",/", .doc = "Raze ,/x — flatten one level / join a list of lists" },
};

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
  root: ?[]u8 = null, // absolute workspace root path (for reference scans)
  indexed: bool = false,
  shutdown: bool = false,
  // Generated reference files.  `help.k` is the arity-agnostic glyph grid that
  // `workspace/symbol` (cmd-t) lands on; `verbs.k` is the per-form doc that
  // `textDocument/definition` lands on, picking the line for the call-site form.
  help_uri: ?[]u8 = null,
  verbs_uri: ?[]u8 = null,
  // sym → line number (0-based) within each generated file.
  help_line: std.StringHashMap(u32) = undefined,
  vmono_line: std.StringHashMap(u32) = undefined, // monadic / first-monadic-adverb form
  vdyad_line: std.StringHashMap(u32) = undefined, // dyadic / first-dyadic-adverb form

  fn init(gpa: Alloc) Server {
    return .{
      .gpa = gpa,
      .docs = std.StringHashMap([]u8).init(gpa),
      .inbuf = .empty,
      .out = .empty,
      .parser = Parser.init(gpa),
      .windex = std.StringHashMap(std.ArrayList(Loc)).init(gpa),
      .help_line = std.StringHashMap(u32).init(gpa),
      .vmono_line = std.StringHashMap(u32).init(gpa),
      .vdyad_line = std.StringHashMap(u32).init(gpa),
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

// The token under `off` plus its immediate neighbours (used to read fused
// verb+adverb pairs like `+/`).
const Tri = struct { prev: ?lex.Token = null, cur: ?lex.Token = null, next: ?lex.Token = null };
fn neighbors(src: []const u8, off: usize) Tri {
  var l = Lexer.init(src);
  var prev: ?lex.Token = null;
  while (true) {
    const t = l.next();
    if (t.tt == .eof) return .{ .prev = prev };
    if (off >= t.start and off < t.end) return .{ .prev = prev, .cur = t, .next = l.peekNext() };
    if (t.start > off) return .{ .prev = prev };
    prev = t;
  }
}

// A token that can terminate a noun phrase (i.e. supply a left argument).
fn isNounTerm(tt: TT) bool {
  return switch (tt) {
    .int, .float, .bit, .bits, .string, .symbol, .iden,
    .@")", .@"}", .@"]", .adverb_val => true,
    else => false,
  };
}

// Classify how the adverb token `adv` is applied, by a localized backward token
// scan inside its statement.  We find the operand the adverb post-modifies, then
// look at the token just left of that operand: a noun there means a left
// argument is present (dyadic application); otherwise it is a monadic
// application, and if there is no operand at all it is a bare value / partial.
fn adverbApplication(gpa: Alloc, src: []const u8, adv: lex.Token) AdverbApp {
  var toks: std.ArrayList(lex.Token) = .empty;
  defer toks.deinit(gpa);
  var l = Lexer.init(src);
  var ai: ?usize = null;
  while (true) {
    const t = l.next();
    if (t.tt == .eof) break;
    if (t.start == adv.start) ai = toks.items.len;
    toks.append(gpa, t) catch return .standalone;
  }
  const idx = ai orelse return .standalone;
  const items = toks.items;
  // Statement start = first token after the previous separator.
  var lo: usize = 0;
  if (idx > 0) {
    var j: usize = idx;
    while (j > 0) : (j -= 1) {
      if (items[j - 1].tt == .sep) { lo = j; break; }
    }
  }
  if (idx == lo) return .standalone; // adverb is first in its statement
  var pi = idx - 1; // last token of the operand
  switch (items[pi].tt) {
    // Not an operand the adverb can modify → bare value / partial.
    .@"(", .@"{", .@"[", .@"$[", .@"[[", .@"[[]", .@":", .sep, .comment => return .standalone,
    // Balanced group / lambda / apply result.
    .@")", .@"}", .@"]" => {
      var depth: i32 = 0;
      while (true) {
        switch (items[pi].tt) {
          .@")", .@"}", .@"]" => depth += 1,
          .@"(", .@"{", .@"[", .@"$[", .@"[[", .@"[[]" => depth -= 1,
          else => {},
        }
        if (depth == 0 or pi == lo) break;
        pi -= 1;
      }
    },
    // A verb train — run of verbs/adverbs.
    .op, .keyword, .io, .adverb, .adverb_val => {
      while (pi > lo) : (pi -= 1) switch (items[pi - 1].tt) {
        .op, .keyword, .io, .adverb, .adverb_val => {},
        else => break,
      };
    },
    // A noun-vector operand (decode/encode) — skip the contiguous literal run.
    .int, .float, .bit, .bits, .symbol, .string => {
      while (pi > lo) : (pi -= 1) switch (items[pi - 1].tt) {
        .int, .float, .bit, .bits, .symbol, .string => {},
        else => break,
      };
    },
    // A single named operand (function value).
    .iden => {},
    else => {},
  }
  if (pi <= lo) return .monadic; // operand starts the statement → no left arg
  return if (isNounTerm(items[pi - 1].tt)) .dyadic else .monadic;
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
  s.root = path; // keep ownership for later reference scans
  indexDir(s, path, 0);
}

// The glyph grid for the 20 core operators — the body of `help.k`.  cmd-t is
// arity-agnostic, so each row shows both valences side by side (MONAD · DYAD).
const GridRow = struct { sym: []const u8, mono: []const u8, dyad: []const u8 };
const GRID = [_]GridRow{
  .{ .sym = ":", .mono = "self",    .dyad = "assign" },
  .{ .sym = "+", .mono = "flip",    .dyad = "add" },
  .{ .sym = "-", .mono = "negate",  .dyad = "subtract" },
  .{ .sym = "*", .mono = "first",   .dyad = "multiply" },
  .{ .sym = "%", .mono = "",        .dyad = "divide" },
  .{ .sym = "!", .mono = "enum",    .dyad = "dict" },
  .{ .sym = "&", .mono = "where",   .dyad = "min|and" },
  .{ .sym = "|", .mono = "reverse", .dyad = "max|or" },
  .{ .sym = "<", .mono = "ascend",  .dyad = "less" },
  .{ .sym = ">", .mono = "descend", .dyad = "more" },
  .{ .sym = "=", .mono = "group",   .dyad = "equal" },
  .{ .sym = "~", .mono = "not",     .dyad = "match" },
  .{ .sym = ",", .mono = "enlist",  .dyad = "concat" },
  .{ .sym = "^", .mono = "null",    .dyad = "without" },
  .{ .sym = "#", .mono = "length",  .dyad = "reshape" },
  .{ .sym = "_", .mono = "floor",   .dyad = "drop|cut" },
  .{ .sym = "$", .mono = "string",  .dyad = "cast" },
  .{ .sym = "?", .mono = "uniq",    .dyad = "find|rnd" },
  .{ .sym = "@", .mono = "type",    .dyad = "apply(1)" },
  .{ .sym = ".", .mono = "eval",    .dyad = "apply(n)" },
};
fn gridRow(sym: []const u8) ?GridRow {
  for (GRID) |g| if (std.mem.eql(u8, g.sym, sym)) return g;
  return null;
}

const BUILTIN_COL: u32 = 2; // length of the `/ ` comment prefix; glyphs sit here

fn emitLine(s: *Server, buf: *std.ArrayList(u8), ln: *u32, text: []const u8) void {
  buf.appendSlice(s.gpa, text) catch {};
  buf.append(s.gpa, '\n') catch {};
  ln.* += 1;
}
fn emitFmt(s: *Server, buf: *std.ArrayList(u8), ln: *u32, comptime fmt: []const u8, args: anytype) void {
  const t = std.fmt.allocPrint(s.gpa, fmt, args) catch return;
  defer s.gpa.free(t);
  buf.appendSlice(s.gpa, t) catch {};
  buf.append(s.gpa, '\n') catch {};
  ln.* += 1;
}
// `/ {sym}  {valence}  {gloss}` with the markdown stripped out of `gloss`.
fn emitForm(s: *Server, buf: *std.ArrayList(u8), ln: *u32, sym: []const u8, val: []const u8, md: []const u8) void {
  buf.appendSlice(s.gpa, "/ ") catch {};
  buf.appendSlice(s.gpa, sym) catch {};
  buf.appendSlice(s.gpa, "  ") catch {};
  buf.appendSlice(s.gpa, val) catch {};
  buf.appendSlice(s.gpa, "  ") catch {};
  // Strip markdown: drop backticks and `**` bold markers, but keep lone `*`
  // (the multiply glyph) and other operators that appear in signatures.
  var i: usize = 0;
  while (i < md.len) : (i += 1) {
    const c = md[i];
    if (c == '`') continue;
    if (c == '*' and i + 1 < md.len and md[i + 1] == '*') { i += 1; continue; }
    buf.append(s.gpa, c) catch {};
  }
  buf.append(s.gpa, '\n') catch {};
  ln.* += 1;
}

fn writeRefFile(s: *Server, name: []const u8, text: []const u8) ?[]u8 {
  const tmp: []const u8 = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
  const path = std.fmt.allocPrint(s.gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, tmp, "/"), name }) catch return null;
  defer s.gpa.free(path);
  const io = std.Io.Threaded.global_single_threaded.io();
  const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return null;
  defer file.close(io);
  file.writePositionalAll(io, text, 0) catch return null;
  return std.fmt.allocPrint(s.gpa, "file://{s}", .{path}) catch null;
}

// help.k — the arity-agnostic glyph grid (workspace/symbol / cmd-t target).
fn buildHelpDoc(s: *Server) void {
  var buf: std.ArrayList(u8) = .empty;
  defer buf.deinit(s.gpa);
  var ln: u32 = 0;
  emitLine(s, &buf, &ln, "/ Ink glyph reference (cmd-t lands here) — arity is unknown at search time,");
  emitLine(s, &buf, &ln, "/ so each glyph shows BOTH valences.  See ink-verbs.k for per-form docs.");
  emitLine(s, &buf, &ln, "/   MONAD     DYAD");
  for (GRID) |g| {
    s.help_line.put(g.sym, ln) catch {};
    buf.appendSlice(s.gpa, "/ ") catch {};
    buf.appendSlice(s.gpa, g.sym) catch {};
    buf.appendSlice(s.gpa, "  ") catch {};
    buf.appendSlice(s.gpa, g.mono) catch {};
    var k: usize = g.mono.len;
    while (k < 9) : (k += 1) buf.append(s.gpa, ' ') catch {};
    buf.append(s.gpa, ' ') catch {};
    buf.appendSlice(s.gpa, g.dyad) catch {};
    buf.append(s.gpa, '\n') catch {};
    ln += 1;
  }
  emitLine(s, &buf, &ln, "/");
  emitLine(s, &buf, &ln, "/ === keyword verbs · adverbs · i/o · idioms ===");
  for (BUILTINS) |b| {
    if (gridRow(b.sym) != null) continue; // already in the grid
    s.help_line.put(b.sym, ln) catch {};
    emitFmt(s, &buf, &ln, "/ {s}  — {s}", .{ b.sym, b.doc });
  }
  s.help_uri = writeRefFile(s, "ink-help.k", buf.items);
}

// verbs.k — one line per (ad)verb FORM (textDocument/definition target).  The
// definition handler picks the monadic or dyadic line by the call-site arity.
fn buildVerbsDoc(s: *Server) void {
  var buf: std.ArrayList(u8) = .empty;
  defer buf.deinit(s.gpa);
  var ln: u32 = 0;
  emitLine(s, &buf, &ln, "/ Ink per-form reference — jump-to-definition lands on the form for the call site.");
  emitLine(s, &buf, &ln, "/");
  emitLine(s, &buf, &ln, "/ === verbs (monadic / dyadic) ===");
  for (VERB_DOCS) |d| {
    if (d.m) |m| { s.vmono_line.put(d.k, ln) catch {}; emitForm(s, &buf, &ln, d.k, "monad", m); }
    if (d.d) |dd| { s.vdyad_line.put(d.k, ln) catch {}; emitForm(s, &buf, &ln, d.k, "dyad ", dd); }
  }
  emitLine(s, &buf, &ln, "/");
  emitLine(s, &buf, &ln, "/ === i/o verbs ===");
  for (IO_DOCS) |d| {
    if (d.m) |m| { s.vmono_line.put(d.k, ln) catch {}; emitForm(s, &buf, &ln, d.k, "monad", m); }
    if (d.d) |dd| { s.vdyad_line.put(d.k, ln) catch {}; emitForm(s, &buf, &ln, d.k, "dyad ", dd); }
  }
  emitLine(s, &buf, &ln, "/");
  emitLine(s, &buf, &ln, "/ === adverbs (monadic-derived / dyadic-applied) ===");
  for (ADVERBS) |a| {
    for (a.mono, 0..) |f, i| {
      if (i == 0) s.vmono_line.put(a.k, ln) catch {};
      emitFmt(s, &buf, &ln, "/ {s}  {s} (monadic)  {s}", .{ a.k, f.name, f.sig });
    }
    for (a.dyad, 0..) |f, i| {
      if (i == 0) s.vdyad_line.put(a.k, ln) catch {};
      emitFmt(s, &buf, &ln, "/ {s}  {s} (dyadic)  {s}", .{ a.k, f.name, f.sig });
    }
  }
  s.verbs_uri = writeRefFile(s, "ink-verbs.k", buf.items);
}

fn buildRefDocs(s: *Server) void {
  buildHelpDoc(s);
  buildVerbsDoc(s);
}

// Resolve a builtin symbol to its per-form line in verbs.k for the given arity.
fn verbsLineFor(s: *Server, sym: []const u8, dyadic: bool) ?u32 {
  if (dyadic) return s.vdyad_line.get(sym) orelse s.vmono_line.get(sym);
  return s.vmono_line.get(sym) orelse s.vdyad_line.get(sym);
}

// Append every reference (any `iden` matching `word`) in `src` to `out`.
fn collectRefsInText(s: *Server, src: []const u8, word: []const u8, uri: []const u8, out: *std.ArrayList(Loc)) void {
  var l = Lexer.init(src);
  while (true) {
    const t = l.next();
    if (t.tt == .eof) break;
    if (t.tt == .iden and std.mem.eql(u8, t.slice(src), word)) {
      const a = offsetToPos(src, t.start);
      const b = offsetToPos(src, t.end);
      const u = s.gpa.dupe(u8, uri) catch return;
      out.append(s.gpa, .{ .uri = u, .sl = a.line, .sc = a.col, .el = b.line, .ec = b.col, .kind = .variable }) catch s.gpa.free(u);
    }
  }
}

fn collectRefsDir(s: *Server, abs_dir: []const u8, word: []const u8, skip_path: ?[]const u8, out: *std.ArrayList(Loc), depth: u8) void {
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
      collectRefsDir(s, child, word, skip_path, out, depth + 1);
    } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".k")) {
      if (skip_path != null and std.mem.eql(u8, child, skip_path.?)) continue; // current doc: use live text
      const text = std.Io.Dir.cwd().readFileAlloc(io, child, s.gpa, std.Io.Limit.limited(4 * 1024 * 1024)) catch continue;
      defer s.gpa.free(text);
      const uri = std.fmt.allocPrint(s.gpa, "file://{s}", .{child}) catch continue;
      defer s.gpa.free(uri);
      collectRefsInText(s, text, word, uri, out);
    }
  }
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
  buildRefDocs(s);
  try replyResult(s, id,
    \\{{"capabilities":{{"textDocumentSync":1,"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true,"referencesProvider":true,"workspaceSymbolProvider":true,"renameProvider":{{"prepareProvider":true}}}},"serverInfo":{{"name":"ink-lsp","version":"0.1.0"}}}}
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
  const tri = neighbors(src, off);
  const t = tri.cur orelse return replyResult(s, id, "null", .{});
  const word = t.slice(src);

  // Adverb: narrow the senses to those possible at the call site (monadic vs
  // dyadic application), and prepend the fused-reduce idiom if it's `verb/`.
  if (t.tt == .adverb) {
    const info = adverbInfo(word) orelse return replyResult(s, id, "null", .{});
    const app = adverbApplication(s.gpa, src, t);
    const base = try adverbHoverMd(s.gpa, info, app);
    defer s.gpa.free(base);
    if (std.mem.eql(u8, word, "/")) if (tri.prev) |pv| if (pv.tt == .op) {
      if (fusedReduceDoc(pv.slice(src))) |fr| {
        const md = try std.fmt.allocPrint(s.gpa, "{s}\n\n---\n{s}", .{ fr, base });
        defer s.gpa.free(md);
        return replyHoverMd(s, id, md);
      }
    };
    return replyHoverMd(s, id, base);
  }

  // `:\`  `:'` — the Zig lexer splits `:` then makes `\`/`'` an `.adverb_val`
  // (because `:` resets the lexer tag to `.phrase`).  Detect the pair and show
  // the adverb's senses (standalone — the `:` monadic-force gives no left arg
  // context to narrow on).  Also handle hovering over the `:` half of the pair.
  if (t.tt == .adverb_val) if (tri.prev) |pv| if (pv.tt == .@":" and pv.end == t.start) {
    const ch = word[0];
    const adv_key: []const u8 = if (ch == '\\') "\\" else if (ch == '\'') "'" else return replyResult(s, id, "null", .{});
    const info = adverbInfo(adv_key) orelse return replyResult(s, id, "null", .{});
    const md = try adverbHoverMd(s.gpa, info, .standalone);
    defer s.gpa.free(md);
    return replyHoverMd(s, id, md);
  };
  if (t.tt == .@":") if (tri.next) |nx| if (nx.tt == .adverb_val and nx.start == t.end) {
    const ch = src[nx.start];
    const adv_key: []const u8 = if (ch == '\\') "\\" else if (ch == '\'') "'" else return replyResult(s, id, "null", .{});
    const info = adverbInfo(adv_key) orelse return replyResult(s, id, "null", .{});
    const md = try adverbHoverMd(s.gpa, info, .standalone);
    defer s.gpa.free(md);
    return replyHoverMd(s, id, md);
  };

  if (t.tt == .op or t.tt == .keyword or t.tt == .io) {
    const dyadic = dyadicHere(tri.prev);
    const vd: ?Doc = if (t.tt == .io) ioDoc(word) else verbDoc(word);
    // If this verb is immediately followed by `/`, lead with the fused idiom.
    // The reduced verb applies dyadically, so show its dyadic sense after it.
    if (tri.next) |nx| if (nx.tt == .adverb and std.mem.eql(u8, nx.slice(src), "/")) {
      if (fusedReduceDoc(word)) |fr| {
        const sense = if (vd) |d| senseFor(d, true) else null;
        const md = if (sense) |sv|
          try std.fmt.allocPrint(s.gpa, "{s}\n\n---\n{s}", .{ fr, sv })
        else
          try s.gpa.dupe(u8, fr);
        defer s.gpa.free(md);
        return replyHoverMd(s, id, md);
      }
    };
    if (vd) |d| if (senseFor(d, dyadic)) |md| return replyHoverMd(s, id, md);
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

  // Operators, keywords and io verbs — jump to the FORM line in verbs.k that
  // matches the call-site arity (monadic vs dyadic).
  if (t.tt == .op or t.tt == .io or t.tt == .keyword) {
    const word = t.slice(src);
    if (s.verbs_uri) |vuri| {
      const dyadic = dyadicHere(neighbors(src, off).prev);
      if (verbsLineFor(s, word, dyadic)) |line| {
        const endc: u32 = BUILTIN_COL + @as(u32, @intCast(word.len));
        return replyLocation(s, id, vuri, line, BUILTIN_COL, line, endc);
      }
    }
  }
  // Adverbs — jump to the monadic-derived or dyadic-applied form by call site.
  if (t.tt == .adverb) {
    const word = t.slice(src);
    if (s.verbs_uri) |vuri| {
      const dyadic = adverbApplication(s.gpa, src, t) == .dyadic;
      if (verbsLineFor(s, word, dyadic)) |line| {
        const endc: u32 = BUILTIN_COL + @as(u32, @intCast(word.len));
        return replyLocation(s, id, vuri, line, BUILTIN_COL, line, endc);
      }
    }
  }
  // `:\` / `:'` — the adverb_val half resolves via the base adverb char.
  if (t.tt == .adverb_val) if (s.verbs_uri) |vuri| {
    const ch = src[t.start];
    const adv_key: []const u8 = if (ch == '\\') "\\" else if (ch == '\'') "'" else return replyResult(s, id, "null", .{});
    if (verbsLineFor(s, adv_key, false)) |line| {
      return replyLocation(s, id, vuri, line, BUILTIN_COL, line, BUILTIN_COL + @as(u32, @intCast(adv_key.len)));
    }
  };

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

fn handleReferences(s: *Server, id: ?json.Value, params: ?json.Value) !void {
  const uri = str(obj(obj(params, "textDocument"), "uri")) orelse return replyResult(s, id, "[]", .{});
  const src = docText(s, uri) orelse return replyResult(s, id, "[]", .{});
  const pos = obj(params, "position");
  const off = posToOffset(src, int(obj(pos, "line")) orelse 0, int(obj(pos, "character")) orelse 0);
  const t = tokenAt(src, off) orelse return replyResult(s, id, "[]", .{});
  if (t.tt != .iden) return replyResult(s, id, "[]", .{});
  const word = t.slice(src);

  var out: std.ArrayList(Loc) = .empty;
  defer {
    for (out.items) |l| s.gpa.free(l.uri);
    out.deinit(s.gpa);
  }
  // Current document uses live (unsaved) text…
  collectRefsInText(s, src, word, uri, &out);
  // …every other .k file is scanned from disk.
  if (s.root) |root| {
    const cur = uriToPath(s.gpa, uri) catch null;
    defer if (cur) |c| s.gpa.free(c);
    collectRefsDir(s, root, word, cur, &out, 0);
  }

  try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
  try writeId(s, id);
  try s.out.appendSlice(s.gpa, ",\"result\":[");
  for (out.items, 0..) |l, idx| {
    if (idx > 0) try s.out.append(s.gpa, ',');
    try s.out.appendSlice(s.gpa, "{\"uri\":\"");
    try escapeInto(&s.out, s.gpa, l.uri);
    try p(s, "\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
      .{ l.sl, l.sc, l.el, l.ec });
  }
  try s.out.appendSlice(s.gpa, "]}");
  try flush(s);
}

fn handleWorkspaceSymbol(s: *Server, id: ?json.Value, params: ?json.Value) !void {
  const query = str(obj(params, "query")) orelse "";
  try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
  try writeId(s, id);
  try s.out.appendSlice(s.gpa, ",\"result\":[");
  var first = true;
  var count: usize = 0;
  var it = s.windex.iterator();
  outer: while (it.next()) |e| {
    const name = e.key_ptr.*;
    if (query.len > 0 and std.ascii.indexOfIgnoreCase(name, query) == null) continue;
    for (e.value_ptr.items) |l| {
      if (count >= 500) break :outer; // keep the response bounded
      count += 1;
      if (!first) try s.out.append(s.gpa, ',');
      first = false;
      const kind: u8 = if (l.kind == .function) 12 else 13;
      try s.out.appendSlice(s.gpa, "{\"name\":\"");
      try escapeInto(&s.out, s.gpa, name);
      try p(s, "\",\"kind\":{d},\"location\":{{\"uri\":\"", .{kind});
      try escapeInto(&s.out, s.gpa, l.uri);
      try p(s, "\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}}}",
        .{ l.sl, l.sc, l.el, l.ec });
    }
  }
  // Builtins: glyphs/idioms point at the arity-agnostic glyph grid (help.k).
  // Match the query against the symbol *and* its gloss, so a search by meaning
  // ("sum" → `+/`, "last" → `*|`) works too.
  if (s.help_uri) |buri| {
    for (BUILTINS) |b| {
      if (count >= 500) break;
      if (query.len > 0 and
          std.ascii.indexOfIgnoreCase(b.sym, query) == null and
          std.ascii.indexOfIgnoreCase(b.doc, query) == null) continue;
      const line = s.help_line.get(b.sym) orelse continue;
      count += 1;
      if (!first) try s.out.append(s.gpa, ',');
      first = false;
      const endc: u32 = BUILTIN_COL + @as(u32, @intCast(b.sym.len));
      try s.out.appendSlice(s.gpa, "{\"name\":\"");
      try escapeInto(&s.out, s.gpa, b.sym);
      try s.out.appendSlice(s.gpa, "\",\"kind\":25,\"location\":{\"uri\":\""); // SymbolKind.Operator
      try escapeInto(&s.out, s.gpa, buri);
      try p(s, "\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}}}",
        .{ line, BUILTIN_COL, line, endc });
    }
  }
  try s.out.appendSlice(s.gpa, "]}");
  try flush(s);
}

fn handlePrepareRename(s: *Server, id: ?json.Value, params: ?json.Value) !void {
  const uri = str(obj(obj(params, "textDocument"), "uri")) orelse return replyResult(s, id, "null", .{});
  const src = docText(s, uri) orelse return replyResult(s, id, "null", .{});
  const pos = obj(params, "position");
  const off = posToOffset(src, int(obj(pos, "line")) orelse 0, int(obj(pos, "character")) orelse 0);
  const t = tokenAt(src, off) orelse return replyResult(s, id, "null", .{});
  if (t.tt != .iden) return replyResult(s, id, "null", .{});
  const a = offsetToPos(src, t.start);
  const b = offsetToPos(src, t.end);
  const word = t.slice(src);
  try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
  try writeId(s, id);
  try s.out.appendSlice(s.gpa, ",\"result\":{\"range\":{\"start\":{\"line\":");
  try p(s, "{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"placeholder\":\"",
    .{ a.line, a.col, b.line, b.col });
  try escapeInto(&s.out, s.gpa, word);
  try s.out.appendSlice(s.gpa, "\"}}");
  try flush(s);
}

fn handleRename(s: *Server, id: ?json.Value, params: ?json.Value) !void {
  const uri = str(obj(obj(params, "textDocument"), "uri")) orelse return replyResult(s, id, "null", .{});
  const src = docText(s, uri) orelse return replyResult(s, id, "null", .{});
  const pos = obj(params, "position");
  const off = posToOffset(src, int(obj(pos, "line")) orelse 0, int(obj(pos, "character")) orelse 0);
  const t = tokenAt(src, off) orelse return replyResult(s, id, "null", .{});
  if (t.tt != .iden) return replyResult(s, id, "null", .{});
  const word = t.slice(src);
  const new_name = str(obj(params, "newName")) orelse return replyResult(s, id, "null", .{});

  var locs: std.ArrayList(Loc) = .empty;
  defer {
    for (locs.items) |l| s.gpa.free(l.uri);
    locs.deinit(s.gpa);
  }
  collectRefsInText(s, src, word, uri, &locs);
  if (s.root) |root| {
    const cur = uriToPath(s.gpa, uri) catch null;
    defer if (cur) |c| s.gpa.free(c);
    collectRefsDir(s, root, word, cur, &locs, 0);
  }

  // Group locations by URI so we can emit one array of edits per file.
  var groups = std.StringHashMap(std.ArrayList(usize)).init(s.gpa);
  defer {
    var it = groups.valueIterator();
    while (it.next()) |v| v.deinit(s.gpa);
    groups.deinit();
  }
  for (locs.items, 0..) |l, i| {
    const gop = try groups.getOrPut(l.uri);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(s.gpa, i);
  }

  try s.out.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
  try writeId(s, id);
  try s.out.appendSlice(s.gpa, ",\"result\":{\"changes\":{");
  var first_file = true;
  var git = groups.iterator();
  while (git.next()) |e| {
    if (!first_file) try s.out.append(s.gpa, ',');
    first_file = false;
    try s.out.append(s.gpa, '"');
    try escapeInto(&s.out, s.gpa, e.key_ptr.*);
    try s.out.appendSlice(s.gpa, "\":[");
    for (e.value_ptr.items, 0..) |li, idx| {
      const l = locs.items[li];
      if (idx > 0) try s.out.append(s.gpa, ',');
      try p(s, "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":\"",
        .{ l.sl, l.sc, l.el, l.ec });
      try escapeInto(&s.out, s.gpa, new_name);
      try s.out.appendSlice(s.gpa, "\"}");
    }
    try s.out.append(s.gpa, ']');
  }
  try s.out.appendSlice(s.gpa, "}}}");
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
  } else if (std.mem.eql(u8, method, "textDocument/references")) {
    try handleReferences(s, id, params);
  } else if (std.mem.eql(u8, method, "workspace/symbol")) {
    try handleWorkspaceSymbol(s, id, params);
  } else if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
    try handlePrepareRename(s, id, params);
  } else if (std.mem.eql(u8, method, "textDocument/rename")) {
    try handleRename(s, id, params);
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
