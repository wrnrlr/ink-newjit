// Recursive-descent parser, evaluation order in K is right-to-left, so the parser is right-recursive.

const std = @import("std");
const Alloc = std.mem.Allocator;
const ast = @import("ast.zig");
const lex = @import("lexer.zig");
const Node = ast.Node;
const TT = lex.TT;
const Token = lex.Token;
const Lexer = lex.Lexer;
const eql = std.mem.eql;
const trim = std.mem.trim;

pub const ParseError = error{ OutOfMemory, Overflow, InvalidCharacter, UnexpectedToken, AssignInParens };

const TableForm = enum { plain, keyed };

pub const Parser = struct {
  arena: std.heap.ArenaAllocator,
  src: []const u8,
  lex: Lexer,
  tok: Token,
  // End byte-offset of the most recently consumed token (updated in advance).
  // Lets a production close its span at the last token it ate without threading
  // positions through every callee.
  prev_end: u32 = 0,
  // Optional per-node source spans (byte offsets [start,end]) for the CST table
  // serializer. Populated only at leaf/bracketed/adverb producers; interior
  // spans are composed from children. Arena-backed, cleared each parse().
  spans: std.AutoHashMapUnmanaged(*Node, [2]u32) = .{},
  // Comment token spans (byte offsets), in source order. The parser drops
  // comments from the tree, so they are captured here for the CST table / doc
  // tooling. Arena-backed, cleared each parse().
  comments: std.ArrayList([2]u32) = .empty,
  // Byte offset of the token a failed parse stopped on. Set by parse()'s errdefer,
  // so every error site gets a position for free without threading one through.
  // Compile-time only — nothing here reaches the VM.
  err_pos: u32 = 0,

  pub fn init(backing: Alloc) Parser {
    var l = Lexer.init("");
    const t = l.next();
    return .{ .arena = std.heap.ArenaAllocator.init(backing), .src = "", .lex = l, .tok = t };
  }
  fn eat(self: *Parser, tt: TT) bool {
    if (self.tok.tt == tt) { self.advance(); return true; }
    return false;
  }
  // Consume a closing bracket. Missing it MID-SOURCE is a real desync — the
  // production would otherwise return with the cursor parked on someone else's
  // token, silently swallowing the statements that follow (an extra `)` used to
  // truncate the rest of the file with exit 0). Missing it at EOF is just
  // half-typed input, which `parse` must tolerate: lib/syntax.k re-parses on every
  // keystroke to highlight, so `f:{[a;` has to yield a partial tree, not an error.
  fn close(self: *Parser, tt: TT) ParseError!void {
    if (self.eat(tt) or self.is(.eof)) return;
    return error.UnexpectedToken;
  }
  pub fn deinit(self: *Parser) void { self.arena.deinit(); }
  pub fn free(_: Parser, _: *Node) void {}
  fn al(self: *Parser) Alloc { return self.arena.allocator(); }
  fn advance(self: *Parser) void {
    if (self.tok.tt == .comment) self.comments.append(self.al(), .{ self.tok.start, self.tok.end }) catch {};
    self.prev_end = self.tok.end;
    self.tok = self.lex.next();
  }
  // Record node n's source span [start, prev_end] (prev_end = end of the last
  // token this production consumed). recEnd sets the end explicitly.
  fn rec(self: *Parser, n: *Node, start: u32) *Node {
    self.spans.put(self.al(), n, .{ start, self.prev_end }) catch {};
    return n;
  }
  fn recEnd(self: *Parser, n: *Node, start: u32, end: u32) *Node {
    self.spans.put(self.al(), n, .{ start, end }) catch {};
    return n;
  }
  fn startOf(self: *Parser, n: *Node) ?u32 { return if (self.spans.get(n)) |s| s[0] else null; }
  fn skipComments(self: *Parser) void { while (self.tok.tt == .comment) self.advance(); }
  fn is(self: *Parser, tt: TT) bool { return self.tok.tt == tt; }
  fn slice(self: *Parser) []const u8 { return self.tok.slice(self.src); }
  fn isNounStart(self: *Parser) bool {
    return switch (self.tok.tt) {
      .int, .float, .bit, .bits, .nat, .dbl, .hlf, .string, .symbol, .iden,
      .@"(", .@"{", .@"[", .@"$[", .adverb_val => true,
      else => false,
    };
  }
  // Token types that can spell a dict/table column name in `k:v`.
  fn isKeyTok(tt: TT) bool { return switch (tt) { .iden, .symbol, .string, .int => true, else => false }; }
  // Pure lookahead: does the stream at the cursor start a `key:` entry? Copies
  // the lexer rather than advancing, so no token is consumed and no comment is
  // double-recorded. `a::1` is a global assign, not an entry, hence the third
  // token check.
  fn peeksItem(self: *Parser) bool {
    if (!isKeyTok(self.tok.tt)) return false;
    var lx = self.lex;
    if (lx.next().tt != .@":") return false;
    return lx.next().tt != .@":";
  }
  // Pure lookahead for the `(`-productions that begin with '['. `.plain` is
  // `([]col:…)`, `.keyed` is `([key:…]col:…)`; null means the '[' merely opens a
  // progn as the list's first item, as in `([1;2];3)`.
  fn peeksTable(self: *Parser) ?TableForm {
    if (self.tok.tt != .@"[") return null;
    var lx = self.lex;
    const t2 = lx.next();
    if (t2.tt == .@"]") return .plain;
    if (!isKeyTok(t2.tt)) return null;
    if (lx.next().tt != .@":") return null;
    if (lx.next().tt == .@":") return null;
    return .keyed;
  }
  fn isVerbStart(self: *Parser) bool { return switch (self.tok.tt) { .op, .keyword, .io => true, else => false }; }
  fn isEnd(self: *Parser) bool { return switch (self.tok.tt) { .sep, .eof, .@"}", .@"]", .@")" => true, else => false }; }
  fn node(self: *Parser, val: Node) ParseError!*Node {
    const m = try self.al().create(Node);
    m.* = val;
    return m;
  }
  // Build intrans or transit depending on whether a RHS follows.
  fn rhs(self: *Parser, lhs: *Node, v: *Node) ParseError!*Node {
    if (self.isEnd() or self.is(.comment))
      return self.node(.{ .intrans = .{ .a = lhs, .v = v, .z = null } });
    return self.node(.{ .transit = .{ .a = lhs, .v = v, .b = try self.parseStmt() } });
  }
  // Wrap verb in term nodes for each consecutive adverb.
  fn chainAdverbs(self: *Parser, v: *Node) ParseError!*Node {
    var verb = v;
    while (self.is(.adverb)) {
      const st = self.startOf(verb) orelse self.tok.start;
      const adv_end = self.tok.end;
      verb = self.recEnd(try self.node(.{ .term = .{ .f = verb, .a = self.slice() } }), st, adv_end);
      self.advance();
    }
    return verb;
  }
  // Wrap verb in a single term node if an adverb follows (used in infix position).
  fn applyAdverb(self: *Parser, v: *Node) ParseError!*Node {
    if (!self.is(.adverb)) return v;
    const st = self.startOf(v) orelse self.tok.start;
    const adv_end = self.tok.end;
    const t = self.recEnd(try self.node(.{ .term = .{ .f = v, .a = self.slice() } }), st, adv_end);
    self.advance();
    return t;
  }
  fn verbNode(self: *Parser, tok: Token) ParseError!*Node {
    const v: Node = switch (tok.tt) {
      .op, .keyword => .{ .op = tok.slice(self.src) },
      .io => .{ .io = tok.slice(self.src) },
      else => .blank,
    };
    return self.recEnd(try self.node(v), tok.start, tok.end);
  }

  pub fn parse(self: *Parser, src: []const u8) ParseError!*Node {
    _ = self.arena.reset(.retain_capacity);
    self.spans = .{}; // arena reset above freed its backing store
    self.comments = .empty;
    self.prev_end = 0;
    self.src = src;
    self.lex = Lexer.init(src);
    self.tok = self.lex.next();
    self.err_pos = 0;
    // Errors propagate without touching parser state, so on the way out `tok` is
    // still sitting on the token that could not be consumed.
    errdefer self.err_pos = self.tok.start;
    return self.parseTerse();
  }

  fn parseTerse(self: *Parser) ParseError!*Node {
    var stmts = try std.ArrayList(ast.Stmt).initCapacity(self.al(), 0);
    while (self.is(.sep) or self.is(.comment)) self.advance();
    while (!self.is(.eof)) {
      if (self.is(.sep)) {
        const s = self.slice();
        const sc = s.len > 0 and s[0] == ';';
        self.advance(); self.skipComments();
        if (sc) try stmts.append(self.al(), .{ .node = try self.node(.blank), .source = ";" });
        continue;
      }
      const start = self.tok.start;
      const n = try self.parseStmt();
      try stmts.append(self.al(), .{ .node = n, .source = trim(u8, self.src[start..self.tok.start], " \t\n") });
      self.skipComments();
      if (self.is(.sep)) {
        const s = self.slice();
        const sc = s.len > 0 and s[0] == ';';
        self.advance(); self.skipComments();
        if (sc) try stmts.append(self.al(), .{ .node = try self.node(.blank), .source = ";" });
      } else break;
    }
    return self.node(.{ .terse = .{ .stmts = try stmts.toOwnedSlice(self.al()) } });
  }

  // Statement position: a leading ':' is an early return from the enclosing
  // lambda (`{$[x<0;:0;x]}`), and `:` on its own returns null. Anywhere else the
  // token keeps its verb reading, so this is a thin wrapper over parseStmt rather
  // than a flag threaded through it.
  fn parseStmtPos(self: *Parser) ParseError!*Node {
    self.skipComments();
    if (!self.is(.@":")) return self.parseStmt();
    const start = self.tok.start;
    self.advance();
    const clause: ?*Node = if (self.isEnd() or self.is(.comment)) null else try self.parseStmt();
    return self.rec(try self.node(.{ .ret = .{ .clause = clause } }), start);
  }

  fn parseStmt(self: *Parser) ParseError!*Node {
    self.skipComments();

    if (self.is(.command)) {
      const raw = self.slice();
      var text = if (raw.len > 0 and raw[0] == '\\') raw[1..] else raw;
      var verb_end: usize = 0;
      while (verb_end < text.len and std.ascii.isAlphabetic(text[verb_end])) verb_end += 1;
      const verb = text[0..verb_end];
      text = text[verb_end..];
      var n: u32 = 1;
      if (text.len > 0 and text[0] == ':') {
        text = text[1..];
        var ne: usize = 0;
        while (ne < text.len and text[ne] >= '0' and text[ne] <= '9') ne += 1;
        if (ne > 0) { n = std.fmt.parseInt(u32, text[0..ne], 10) catch 1; text = text[ne..]; }
      }
      var ai: usize = 0;
      while (ai < text.len and (text[ai] == ' ' or text[ai] == '\t')) ai += 1;
      const m = try self.node(.{ .command = .{ .verb = verb, .n = n, .args = text[ai..] } });
      self.advance();
      return m;
    }

    // ':' alone (at stmt end) → standalone ':' op; otherwise → right clause
    if (self.is(.@":")) {
      const ctok = self.tok;
      self.advance();
      if (self.isEnd() or self.is(.comment)) return self.node(.{ .op = ctok.slice(self.src) });
      return self.node(.{ .right = .{ .clause = try self.parseStmt() } });
    }

    if (self.isVerbStart()) return self.parseVerbLedStmt();
    if (!self.isNounStart()) return self.node(.blank);
    return self.parseAfterNoun(try self.parseNoun());
  }

  fn parseAfterNoun(self: *Parser, noun: *Node) ParseError!*Node {
    self.skipComments();
    if (self.is(.@"[")) return self.parseAfterNoun(try self.parseApply(noun));
    if (self.is(.@":")) return self.parseBind(noun, null);

    if (self.is(.op) or self.is(.keyword)) {
      const op_tok = self.tok;
      self.advance();
      if (self.is(.@":")) {
        // '1<:\' style: op: immediately followed by adverb char → monad + adverb
        const next_is_adverb = self.tok.end < self.src.len and
          (self.src[self.tok.end] == '\\' or self.src[self.tok.end] == '/' or self.src[self.tok.end] == '\'');
        if (next_is_adverb) {
          self.advance(); // consume ':'
          const mv = try self.node(.{ .monad = .{ .f = op_tok.slice(self.src) } });
          const adv: *Node = if (self.is(.adverb_val) or self.is(.adverb)) blk: {
            const t = try self.node(.{ .term = .{ .f = mv, .a = self.slice() } });
            self.advance(); break :blk t;
          } else mv;
          return self.rhs(noun, adv);
        }
        return self.parseBind(noun, op_tok.slice(self.src));
      }
      const verb = try self.applyAdverb(try self.verbNode(op_tok));
      return self.rhs(noun, verb);
    }

    if (self.is(.io)) {
      const vn = try self.verbNode(self.tok);
      self.advance();
      return self.rhs(noun, vn);
    }

    if (self.is(.adverb)) {
      const term = try self.chainAdverbs(noun);
      if (self.is(.@"[")) return self.parseAfterNoun(try self.parseApply(term));
      if (self.isNounStart() or self.isVerbStart())
        return self.node(.{ .apposit = .{ .f = term, .a = try self.parseStmt() } });
      return term;
    }

    // noun noun [adverb+] → digram transit, or simple apposit
    if (self.isNounStart()) {
      var inner = try self.parseNoun();
      while (self.is(.@"[")) inner = try self.parseApply(inner);
      if (self.is(.adverb)) {
        const verb = try self.chainAdverbs(inner);
        if (self.is(.@"[")) return self.parseAfterNoun(try self.parseApply(verb));
        return self.rhs(noun, verb);
      }
      return self.node(.{ .apposit = .{ .f = noun, .a = try self.parseAfterNoun(inner) } });
    }

    return noun;
  }

  fn parseBind(self: *Parser, noun: *Node, op_str: ?[]const u8) ParseError!*Node {
    self.advance(); // consume ':'
    const rhs_node: ?*Node = if (!self.isEnd() and !self.is(.comment)) try self.parseStmt() else null;
    return self.node(.{ .bind = .{ .v = noun, .f = op_str, .a = rhs_node } });
  }

  fn parseVerbLedStmt(self: *Parser) ParseError!*Node {
    const op_tok = self.tok;
    const vn = try self.verbNode(op_tok);
    self.advance();

    // op ':' → first-class monad value, optionally followed by adverb then apposit
    if (self.is(.@":")) {
      self.advance();
      const op_str = if (vn.* == .op) vn.op else "";
      self.al().destroy(vn);
      const mv = try self.node(.{ .monad = .{ .f = op_str } });
      const verb: *Node = if (self.is(.adverb_val) or self.is(.adverb)) blk: {
        const t = try self.node(.{ .term = .{ .f = mv, .a = self.slice() } });
        self.advance(); break :blk t;
      } else mv;
      if (!self.isEnd() and !self.is(.comment) and (self.isNounStart() or self.isVerbStart()))
        return self.node(.{ .apposit = .{ .f = verb, .a = try self.parseStmt() } });
      return verb;
    }

    const verb = try self.chainAdverbs(vn);
    if (self.is(.@"[")) return self.parseAfterNoun(try self.parseApply(verb));
    if (!self.isEnd() and !self.is(.comment) and (self.isNounStart() or self.isVerbStart()))
      return self.node(.{ .apposit = .{ .f = verb, .a = try self.parseStmt() } });
    return verb;
  }

  fn parseNoun(self: *Parser) ParseError!*Node {
    const start = self.tok.start;
    const n: *Node = switch (self.tok.tt) {
      .int, .float, .bit, .bits, .nat, .dbl, .hlf, .string, .symbol, .iden => try self.parseLiteralOrVector(),
      .@"(" => try self.parseGroupOrList(),
      .@"{" => try self.parseLambda(),
      .@"[" => try self.parseProgn(),
      .@"$[" => try self.parseCond(),
      .adverb_val => blk: {
        const adv = self.slice(); self.advance();
        break :blk try self.node(.{ .adverb_val = adv });
      },
      else => try self.node(.blank),
    };
    // Every noun (literal or bracketed form) spans from its first token to the
    // last token consumed — for brackets that includes the closing delimiter.
    return self.rec(n, start);
  }

  fn parseLiteralOrVector(self: *Parser) ParseError!*Node {
    const tok = self.tok;
    self.advance();
    switch (tok.tt) {
      .int => {
        // Start as an int run; if a decimal element appears anywhere in the run
        // (`1 2 3.5`, `1 -2.5`), PROMOTE the accumulated ints to floats and finish as
        // an F vector — matching the .float branch (which already accepts int tokens).
        var ilist = try std.ArrayList(i32).initCapacity(self.al(), 4);
        try ilist.append(self.al(), try parseIntLit(tok.slice(self.src)));
        var flist: std.ArrayList(f32) = .empty;
        var promoted = false;
        var last = tok.end;
        while (true) {
          while (self.is(.int) or self.is(.float)) {
            if (self.is(.float) and !promoted) { try self.promoteInts(&ilist, &flist); promoted = true; }
            if (promoted) {
              try flist.append(self.al(), if (self.is(.float)) try parseFloatLit(self.slice()) else @floatFromInt(try parseIntLit(self.slice())));
            } else try ilist.append(self.al(), try parseIntLit(self.slice()));
            last = self.tok.end; self.advance();
          }
          // interior-negative re-gluing: `1 -2 3`, and now `1 -2.5 3` too.
          if (!self.is(.op) or !eql(u8, self.slice(), "-")) break;
          const ms = self.tok.start; const me = self.tok.end; const nt = self.lex.peekNext();
          if ((nt.tt != .int and nt.tt != .float) or nt.start != me or ms <= last) break;
          self.advance();
          if (self.is(.float) and !promoted) { try self.promoteInts(&ilist, &flist); promoted = true; }
          if (promoted) {
            const v: f32 = if (self.is(.float)) try parseFloatLit(self.slice()) else @floatFromInt(try parseIntLit(self.slice()));
            try flist.append(self.al(), -v);
          } else try ilist.append(self.al(), -(try parseIntLit(self.slice())));
          last = self.tok.end; self.advance();
        }
        if (promoted) {
          const items = try flist.toOwnedSlice(self.al());
          if (items.len == 1) { defer self.al().free(items); return self.node(.{ .literal = .{ .f = items[0] } }); }
          return self.node(.{ .literal = .{ .F = items } });
        }
        const items = try ilist.toOwnedSlice(self.al());
        if (items.len == 1) { defer self.al().free(items); return self.node(.{ .literal = .{ .i = items[0] } }); }
        return self.node(.{ .literal = .{ .I = items } });
      },
      .float => {
        var list = try std.ArrayList(f32).initCapacity(self.al(), 4);
        try list.append(self.al(), try parseFloatLit(tok.slice(self.src)));
        var last = tok.end;
        while (true) {
          while (self.is(.float) or self.is(.int)) {
            const v: f32 = if (self.is(.float)) try parseFloatLit(self.slice()) else @floatFromInt(try parseIntLit(self.slice()));
            try list.append(self.al(), v); last = self.tok.end; self.advance();
          }
          if (!self.is(.op) or !eql(u8, self.slice(), "-")) break;
          const ms = self.tok.start; const me = self.tok.end; const nt = self.lex.peekNext();
          if ((nt.tt != .float and nt.tt != .int) or nt.start != me or ms <= last) break;
          self.advance();
          const v: f32 = if (self.is(.float)) try parseFloatLit(self.slice()) else @floatFromInt(try parseIntLit(self.slice()));
          try list.append(self.al(), -v); last = self.tok.end; self.advance();
        }
        const items = try list.toOwnedSlice(self.al());
        if (items.len == 1) { defer self.al().free(items); return self.node(.{ .literal = .{ .f = items[0] } }); }
        return self.node(.{ .literal = .{ .F = items } });
      },
      .nat => {
        // Natural (u32) run: `3u`, `1u 2u 3u`. Unsigned → no interior-negative re-gluing.
        var list = try std.ArrayList(u32).initCapacity(self.al(), 4);
        try list.append(self.al(), try parseNatLit(tok.slice(self.src)));
        while (self.is(.nat)) { try list.append(self.al(), try parseNatLit(self.slice())); self.advance(); }
        const items = try list.toOwnedSlice(self.al());
        if (items.len == 1) { defer self.al().free(items); return self.node(.{ .literal = .{ .n = items[0] } }); }
        return self.node(.{ .literal = .{ .N = items } });
      },
      .dbl => {
        // f64 run: `2.3d`, `1.0d 2.0d`. Isolated precise type — groups only with
        // its own suffix (no int promotion, no interior-`-` re-gluing).
        var list = try std.ArrayList(f64).initCapacity(self.al(), 4);
        try list.append(self.al(), try parseDblLit(tok.slice(self.src)));
        while (self.is(.dbl)) { try list.append(self.al(), try parseDblLit(self.slice())); self.advance(); }
        const items = try list.toOwnedSlice(self.al());
        if (items.len == 1) { defer self.al().free(items); return self.node(.{ .literal = .{ .d = items[0] } }); }
        return self.node(.{ .literal = .{ .D = items } });
      },
      .hlf => {
        var list = try std.ArrayList(f16).initCapacity(self.al(), 4);
        try list.append(self.al(), try parseHlfLit(tok.slice(self.src)));
        while (self.is(.hlf)) { try list.append(self.al(), try parseHlfLit(self.slice())); self.advance(); }
        const items = try list.toOwnedSlice(self.al());
        if (items.len == 1) { defer self.al().free(items); return self.node(.{ .literal = .{ .h = items[0] } }); }
        return self.node(.{ .literal = .{ .H = items } });
      },
      .bit, .bits => {
        var list = try std.ArrayList(bool).initCapacity(self.al(), 4);
        try appendBools(self.al(), &list, tok.slice(self.src), tok.tt == .bits);
        while (self.is(.bit) or self.is(.bits)) {
          const t = self.tok; self.advance();
          try appendBools(self.al(), &list, t.slice(self.src), t.tt == .bits);
        }
        const items = try list.toOwnedSlice(self.al());
        if (items.len == 1) { defer self.al().free(items); return self.node(.{ .literal = .{ .b = items[0] } }); }
        return self.node(.{ .literal = .{ .B = items } });
      },
      .symbol => {
        if (!self.is(.symbol)) return self.node(.{ .literal = .{ .s = symbolBody(tok.slice(self.src)) } });
        var syms = try std.ArrayList([]const u8).initCapacity(self.al(), 4);
        try syms.append(self.al(), symbolBody(tok.slice(self.src)));
        while (self.is(.symbol)) { try syms.append(self.al(), symbolBody(self.slice())); self.advance(); }
        return self.node(.{ .literal = .{ .S = try syms.toOwnedSlice(self.al()) } });
      },
      .string => {
        const full = tok.slice(self.src);
        return self.node(.{ .literal = .{ .c = if (full.len >= 2) full[1 .. full.len - 1] else "" } });
      },
      .iden => return self.node(.{ .literal = .{ .@"var" = tok.slice(self.src) } }),
      else => unreachable,
    }
  }

  // Everything spelled with round brackets: group, list, dict, table, keyed table.
  //
  //   ()                  empty list          (x)            group
  //   (1;2)               list                (a:1;b:2)       dict
  //   ([]a:1 2;b:3 4)     table               ([a:1 2]b:3 4)  keyed table
  //
  // A dict is decided by the FIRST item alone: `(` + `key:` (and not `key::`)
  // commits to a dict, after which every item must be `key:value` or parseItems
  // errors. One rule, two tokens of lookahead, no backtracking — and the two
  // mixed shapes `(a:1;2)` and `(1;a:2)` are both rejected rather than quietly
  // meaning something else.
  fn parseGroupOrList(self: *Parser) ParseError!*Node {
    self.advance(); // consume '('
    self.skipComments();
    if (self.eat(.@")")) return self.node(.{ .list = .{ .seq = null } });
    if (self.is(.adverb_val) and self.lex.peekNext().tt == .@")") {
      const adv = self.slice(); self.advance(); try self.close(.@")");
      return self.node(.{ .group = .{ .stmt = try self.node(.{ .adverb_val = adv }) } });
    }
    if (self.peeksTable()) |form| return self.parseTableLit(form);
    if (self.peeksItem()) {
      const items = try self.parseItems(.@")");
      try self.close(.@")");
      return self.node(.{ .dict = .{ .items = if (items.len > 0) items else null } });
    }
    const seq = try self.parseSeq(.@")", false);
    try self.close(.@")");
    // A bind as a top-level item means someone wrote `(1;a:2)` — either a
    // half-formed dict or the old sequence-inside-parens idiom. Both belong in a
    // progn now, so say so instead of silently building a list of assignments.
    for (seq) |it| if (it.* == .bind or it.* == .pending) return error.AssignInParens;
    if (seq.len == 1) {
      defer self.al().free(seq);
      return self.node(.{ .group = .{ .stmt = seq[0] } });
    }
    return self.node(.{ .list = .{ .seq = seq } });
  }

  // `([]col:…)` and `([keycol:…]col:…)`. The cursor sits on the inner '['.
  fn parseTableLit(self: *Parser, form: TableForm) ParseError!*Node {
    self.advance(); // consume '['
    if (form == .plain) {
      try self.close(.@"]");
      const items = try self.parseItems(.@")");
      try self.close(.@")");
      return self.node(.{ .table = .{ .items = if (items.len > 0) items else null } });
    }
    const keys = try self.parseItems(.@"]");
    try self.close(.@"]");
    const vals = try self.parseItems(.@")");
    try self.close(.@")");
    return self.node(.{ .utable = .{
      .keys = if (keys.len > 0) keys else null,
      .items = if (vals.len > 0) vals else null,
    } });
  }

  // `[a;b;c]` in noun position — a statement block. Runs every statement, yields
  // the last one's value. (After a noun, '[' is still apply/index; see
  // parseAfterNoun.)
  fn parseProgn(self: *Parser) ParseError!*Node {
    self.advance(); // consume '['
    if (self.eat(.@"]")) return self.node(.{ .progn = .{ .seq = null } });
    const seq = try self.parseSeq(.@"]", true);
    try self.close(.@"]");
    return self.node(.{ .progn = .{ .seq = if (seq.len > 0) seq else null } });
  }

  // `stmt_pos` marks the elements as STATEMENTS rather than values, which is what
  // licenses a leading ':' to mean early-return (lambda bodies, progn blocks).
  // List elements and call arguments are values, so there `:` keeps its old
  // reading as the bare right/assign verb — `@[v;`px;:;99.]` still works.
  fn parseSeq(self: *Parser, end_tt: TT, stmt_pos: bool) ParseError!ast.Seq {
    // Consecutive expressions become separate elements regardless of what
    // delimits them, so a newline always separates items. What differs is
    // null-injection: only a ';' (`counts`) can add a blank (`;;`, a trailing
    // ';'). Inside a lambda body ('}') a newline also counts, so blank
    // statements are possible; inside (...) / [...] a newline never injects a
    // null — items may be written one-per-line with or without a trailing ';'.
    const nl_is_sep = end_tt == .@"}";
    var stmts = try std.ArrayList(*Node).initCapacity(self.al(), 0);
    var last_sep = false;
    var last_sep_is_sc = false;
    while (!self.is(end_tt) and !self.is(.eof)) {
      self.skipComments();
      if (self.is(end_tt) or self.is(.eof)) break;
      if (self.is(.sep)) {
        const is_sc = self.slice().len > 0 and self.slice()[0] == ';';
        const counts = is_sc or nl_is_sep;
        if (counts) {
          if (last_sep and last_sep_is_sc) try stmts.append(self.al(), try self.node(.blank));
          last_sep = true;
          last_sep_is_sc = is_sc;
        }
        self.advance();
        continue;
      }
      last_sep = false;
      last_sep_is_sc = false;
      const before = self.tok.start;
      try stmts.append(self.al(), if (stmt_pos) try self.parseStmtPos() else try self.parseStmt());
      // Guard against a non-advancing parseStmt (stray closer / unexpected
      // token) spinning the loop forever before `end_tt`/eof is reached.
      if (self.tok.start == before) break;
      self.skipComments();
    }
    if (last_sep and last_sep_is_sc) try stmts.append(self.al(), try self.node(.blank));
    return stmts.toOwnedSlice(self.al());
  }

  fn parseLambda(self: *Parser) ParseError!*Node {
    const start = self.tok.start;
    self.advance(); // consume '{'
    var args: ?ast.Args = null;
    if (self.is(.@"[")) { self.advance(); args = try self.parseArgList(); }
    var seq: ?ast.Seq = null;
    if (!self.is(.@"}")) seq = try self.parseSeq(.@"}", true);
    const end = self.tok.end;
    try self.close(.@"}");
    return self.node(.{ .lambda = .{ .a = args, .b = seq, .start = start, .end = end } });
  }

  fn parseArgList(self: *Parser) ParseError!ast.Args {
    var args = try std.ArrayList(ast.Arg).initCapacity(self.al(), 0);
    var awaiting = true;
    while (!self.is(.@"]") and !self.is(.eof)) {
      self.skipComments();
      if (self.is(.sep)) {
        if (awaiting) try args.append(self.al(), .{ .is_some = false, .value = "", .start = self.tok.start, .end = self.tok.start });
        awaiting = true; self.advance(); continue;
      }
      // A keyword verb (`in has mod div`) cannot be a parameter name: the lexer
      // always tokenises it as a verb, so the body reference would rebind to the
      // verb (silent miscompile). Reject it loudly instead. (triage #14)
      if (self.is(.keyword) and awaiting) return error.UnexpectedToken;
      if (self.is(.iden) and awaiting) {
        try args.append(self.al(), .{ .is_some = true, .value = self.slice(), .start = self.tok.start, .end = self.tok.end });
        awaiting = false;
      }
      self.advance();
    }
    if (awaiting and args.items.len > 0)
      try args.append(self.al(), .{ .is_some = false, .value = "", .start = self.tok.start, .end = self.tok.start });
    try self.close(.@"]");
    return args.toOwnedSlice(self.al());
  }

  fn parseItems(self: *Parser, end_tt: TT) ParseError!ast.Items {
    var items = try std.ArrayList(ast.Item).initCapacity(self.al(), 0);
    while (!self.is(end_tt) and !self.is(.eof)) {
      self.skipComments();
      if (self.is(end_tt) or self.is(.eof)) break;
      if (self.is(.sep)) { self.advance(); continue; }
      // A malformed entry used to `break` silently, leaving the cursor mid-bracket:
      // `[3;4]` yielded an EMPTY dict plus a stray `4` statement, and inside `$[…]`
      // it swallowed the `]` and absorbed the following statement, so trailing code
      // vanished with exit 0. Refuse it instead — a dict entry is always `key: value`.
      const key = try self.parseItemKey() orelse
        { if (self.is(.eof)) break; return error.UnexpectedToken; };
      if (!self.eat(.@":")) { if (self.is(.eof)) break; return error.UnexpectedToken; }
      const val: *Node = if (self.is(end_tt) or self.is(.sep) or self.is(.eof))
        try self.node(.blank) else try self.parseStmt();
      try items.append(self.al(), .{ .k = key, .v = val });
    }
    return items.toOwnedSlice(self.al());
  }

  fn parseItemKey(self: *Parser) ParseError!?[]const u8 {
    const s = self.slice();
    const key: ?[]const u8 = switch (self.tok.tt) {
      .iden, .int => s,
      .string => if (s.len >= 2) s[1 .. s.len - 1] else s,
      .symbol => symbolBody(s),
      else => return null,
    };
    self.advance();
    return key;
  }

  fn parseApply(self: *Parser, f: *Node) ParseError!*Node {
    const st = self.startOf(f) orelse self.tok.start;
    self.advance(); // consume '['
    if (self.eat(.@"]")) return self.recEnd(try self.node(.{ .apply = .{ .f = f, .a = null } }), st, self.prev_end);
    const seq = try self.parseSeq(.@"]", false);
    try self.close(.@"]");
    return self.recEnd(try self.node(.{ .apply = .{ .f = f, .a = seq } }), st, self.prev_end);
  }

  fn parseCond(self: *Parser) ParseError!*Node {
    self.advance(); // consume '$['
    var stmts = try std.ArrayList(*Node).initCapacity(self.al(), 0);
    while (!self.is(.@"]") and !self.is(.eof)) {
      self.skipComments();
      if (self.is(.@"]")) break;
      if (self.is(.sep)) { self.advance(); continue; }
      const before = self.tok.start;
      try stmts.append(self.al(), try self.parseStmtPos());
      // parseStmt yields a .blank without consuming on a token it can't start a
      // statement from (a stray ')'/'}'/'[' or other closer). Without this guard
      // the loop would spin forever, never reaching ']' or eof — e.g. a '[...]'
      // block written as a $[] branch. Stop on no forward progress.
      if (self.tok.start == before) break;
    }
    try self.close(.@"]");
    return self.node(.{ .cond = .{ .stmts = try stmts.toOwnedSlice(self.al()) } });
  }

  // Promote an int-vector accumulator to floats in place (int run met a decimal
  // element). Copies every collected i32 into `flist` as f32, then frees `ilist`.
  fn promoteInts(self: *Parser, ilist: *std.ArrayList(i32), flist: *std.ArrayList(f32)) ParseError!void {
    try flist.ensureTotalCapacity(self.al(), ilist.items.len + 4);
    for (ilist.items) |iv| flist.appendAssumeCapacity(@floatFromInt(iv));
    ilist.deinit(self.al());
  }
  fn parseIntLit(s: []const u8) ParseError!i32 {
    if (eql(u8, s, "0N") or eql(u8, s, "-0N")) return std.math.minInt(i32);
    if (eql(u8, s, "0W")) return std.math.maxInt(i32);
    if (eql(u8, s, "-0W")) return std.math.minInt(i32) + 1;
    return std.fmt.parseInt(i32, s, 0) catch error.InvalidCharacter;
  }
  fn parseNatLit(s: []const u8) ParseError!u32 {
    // Strip the trailing 'u' suffix; `0Nu` is the natural null.
    const body = if (s.len > 0 and s[s.len - 1] == 'u') s[0 .. s.len - 1] else s;
    if (eql(u8, body, "0N")) return std.math.maxInt(u32);
    return std.fmt.parseInt(u32, body, 0) catch error.InvalidCharacter;
  }
  fn parseDblLit(s: []const u8) ParseError!f64 {
    const body = if (s.len > 0 and s[s.len - 1] == 'd') s[0 .. s.len - 1] else s;
    if (eql(u8, body, "0n") or eql(u8, body, "-0n")) return std.math.nan(f64);
    if (eql(u8, body, "0w")) return std.math.inf(f64);
    if (eql(u8, body, "-0w")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, body) catch error.InvalidCharacter;
  }
  fn parseHlfLit(s: []const u8) ParseError!f16 {
    const body = if (s.len > 0 and s[s.len - 1] == 'h') s[0 .. s.len - 1] else s;
    if (eql(u8, body, "0n") or eql(u8, body, "-0n")) return std.math.nan(f16);
    if (eql(u8, body, "0w")) return std.math.inf(f16);
    if (eql(u8, body, "-0w")) return -std.math.inf(f16);
    return std.fmt.parseFloat(f16, body) catch error.InvalidCharacter;
  }
  fn parseFloatLit(s: []const u8) ParseError!f32 {
    if (eql(u8, s, "0n") or eql(u8, s, "-0n")) return std.math.nan(f32);
    if (eql(u8, s, "0w")) return std.math.inf(f32);
    if (eql(u8, s, "-0w")) return -std.math.inf(f32);
    return std.fmt.parseFloat(f32, s) catch error.InvalidCharacter;
  }
  fn appendBools(alloc: Alloc, list: *std.ArrayList(bool), s: []const u8, is_vec: bool) !void {
    if (is_vec) { for (s[0 .. s.len - 1]) |d| try list.append(alloc, d == '1'); }
    else try list.append(alloc, s[0] == '1');
  }
  fn symbolBody(s: []const u8) []const u8 {
    if (s.len <= 1) return "";
    var body = s[1..];
    if (body.len >= 2 and body[0] == '"' and body[body.len - 1] == '"') body = body[1 .. body.len - 1];
    return body;
  }
};

test "parser" {
  var p = Parser.init(std.testing.allocator); defer p.deinit();
  const n1 = try p.parse("1+1");
  const s1 = n1.terse.stmts[0].node;
  try std.testing.expect(s1.* == .transit);
  try std.testing.expectEqualStrings("+", s1.transit.v.op);
  const n2 = try p.parse("(name:\"Bob\";age:42)");
  const s2 = n2.terse.stmts[0].node;
  try std.testing.expect(s2.* == .dict);
  try std.testing.expect(s2.dict.items.?.len == 2);
  const n3 = try p.parse("*:1 2 3");
  const s3 = n3.terse.stmts[0].node;
  try std.testing.expect(s3.* == .apposit);
  try std.testing.expect(s3.apposit.f.* == .monad);
}
