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

pub const ParseError = error{ OutOfMemory, Overflow, InvalidCharacter, UnexpectedToken };

pub const Parser = struct {
  arena: std.heap.ArenaAllocator,
  src: []const u8,
  lex: Lexer,
  tok: Token,

  pub fn init(backing: Alloc) Parser {
    var l = Lexer.init("");
    const t = l.next();
    return .{ .arena = std.heap.ArenaAllocator.init(backing), .src = "", .lex = l, .tok = t };
  }
  fn eat(self: *Parser, tt: TT) bool {
    if (self.tok.tt == tt) { self.advance(); return true; }
    return false;
  }
  pub fn deinit(self: *Parser) void { self.arena.deinit(); }
  pub fn free(_: Parser, _: *Node) void {}
  fn al(self: *Parser) Alloc { return self.arena.allocator(); }
  fn advance(self: *Parser) void { self.tok = self.lex.next(); }
  fn skipComments(self: *Parser) void { while (self.tok.tt == .comment) self.advance(); }
  fn is(self: *Parser, tt: TT) bool { return self.tok.tt == tt; }
  fn slice(self: *Parser) []const u8 { return self.tok.slice(self.src); }
  fn isNounStart(self: *Parser) bool {
    return switch (self.tok.tt) {
      .int, .float, .bit, .bits, .string, .symbol, .iden,
      .@"(", .@"{", .@"[", .@"$[", .@"[[]", .@"[[", .adverb_val => true,
      else => false,
    };
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
      verb = try self.node(.{ .term = .{ .f = verb, .a = self.slice() } });
      self.advance();
    }
    return verb;
  }
  // Wrap verb in a single term node if an adverb follows (used in infix position).
  fn applyAdverb(self: *Parser, v: *Node) ParseError!*Node {
    if (!self.is(.adverb)) return v;
    const t = try self.node(.{ .term = .{ .f = v, .a = self.slice() } });
    self.advance();
    return t;
  }
  fn verbNode(self: *Parser, tok: Token) ParseError!*Node {
    const v: Node = switch (tok.tt) {
      .op, .keyword => .{ .op = tok.slice(self.src) },
      .io => .{ .io = tok.slice(self.src) },
      else => .blank,
    };
    return self.node(v);
  }

  pub fn parse(self: *Parser, src: []const u8) ParseError!*Node {
    _ = self.arena.reset(.retain_capacity);
    self.src = src;
    self.lex = Lexer.init(src);
    self.tok = self.lex.next();
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
    return switch (self.tok.tt) {
      .int, .float, .bit, .bits, .string, .symbol, .iden => self.parseLiteralOrVector(),
      .@"(" => self.parseGroupOrList(),
      .@"{" => self.parseLambda(),
      .@"[" => self.parseDictOrArgs(),
      .@"[[]" => self.parseTable(),
      .@"[[" => self.parseUTable(),
      .@"$[" => self.parseCond(),
      .adverb_val => blk: {
        const adv = self.slice(); self.advance();
        break :blk self.node(.{ .adverb_val = adv });
      },
      else => self.node(.blank),
    };
  }

  fn parseLiteralOrVector(self: *Parser) ParseError!*Node {
    const tok = self.tok;
    self.advance();
    switch (tok.tt) {
      .int => {
        var list = try std.ArrayList(i32).initCapacity(self.al(), 4);
        try list.append(self.al(), try parseIntLit(tok.slice(self.src)));
        var last = tok.end;
        while (true) {
          while (self.is(.int)) { try list.append(self.al(), try parseIntLit(self.slice())); last = self.tok.end; self.advance(); }
          if (!self.is(.op) or !eql(u8, self.slice(), "-")) break;
          const ms = self.tok.start; const me = self.tok.end; const nt = self.lex.peekNext();
          if (nt.tt != .int or nt.start != me or ms <= last) break;
          self.advance();
          try list.append(self.al(), -(try parseIntLit(self.slice())));
          last = self.tok.end; self.advance();
        }
        const items = try list.toOwnedSlice(self.al());
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

  fn parseGroupOrList(self: *Parser) ParseError!*Node {
    self.advance(); // consume '('
    if (self.eat(.@")")) return self.node(.{ .list = .{ .seq = null } });
    if (self.is(.adverb_val) and self.lex.peekNext().tt == .@")") {
      const adv = self.slice(); self.advance(); _ = self.eat(.@")");
      return self.node(.{ .group = .{ .stmt = try self.node(.{ .adverb_val = adv }) } });
    }
    const seq = try self.parseSeq(.@")");
    _ = self.eat(.@")");
    if (seq.len == 1) {
      defer self.al().free(seq);
      return self.node(.{ .group = .{ .stmt = seq[0] } });
    }
    return self.node(.{ .list = .{ .seq = seq } });
  }

  fn parseSeq(self: *Parser, end_tt: TT) ParseError!ast.Seq {
    var stmts = try std.ArrayList(*Node).initCapacity(self.al(), 0);
    var last_sep = false;
    while (!self.is(end_tt) and !self.is(.eof)) {
      self.skipComments();
      if (self.is(end_tt) or self.is(.eof)) break;
      if (self.is(.sep)) {
        if (last_sep) try stmts.append(self.al(), try self.node(.blank));
        self.advance(); last_sep = true; continue;
      }
      last_sep = false;
      try stmts.append(self.al(), try self.parseStmt());
      self.skipComments();
    }
    if (last_sep) try stmts.append(self.al(), try self.node(.blank));
    return stmts.toOwnedSlice(self.al());
  }

  fn parseLambda(self: *Parser) ParseError!*Node {
    const start = self.tok.start;
    self.advance(); // consume '{'
    var args: ?ast.Args = null;
    if (self.is(.@"[")) { self.advance(); args = try self.parseArgList(); }
    var seq: ?ast.Seq = null;
    if (!self.is(.@"}")) seq = try self.parseSeq(.@"}");
    const end = self.tok.end;
    _ = self.eat(.@"}");
    return self.node(.{ .lambda = .{ .a = args, .b = seq, .start = start, .end = end } });
  }

  fn parseArgList(self: *Parser) ParseError!ast.Args {
    var args = try std.ArrayList(ast.Arg).initCapacity(self.al(), 0);
    var awaiting = true;
    while (!self.is(.@"]") and !self.is(.eof)) {
      self.skipComments();
      if (self.is(.sep)) {
        if (awaiting) try args.append(self.al(), .{ .is_some = false, .value = "" });
        awaiting = true; self.advance(); continue;
      }
      if (self.is(.iden) and awaiting) {
        try args.append(self.al(), .{ .is_some = true, .value = self.slice() });
        awaiting = false;
      }
      self.advance();
    }
    if (awaiting and args.items.len > 0)
      try args.append(self.al(), .{ .is_some = false, .value = "" });
    _ = self.eat(.@"]");
    return args.toOwnedSlice(self.al());
  }

  fn parseDictOrArgs(self: *Parser) ParseError!*Node {
    self.advance(); // consume '['
    if (self.is(.@"]")) { self.advance(); return self.node(.{ .dict = .{ .items = null } }); }
    const items = try self.parseItems(.@"]");
    _ = self.eat(.@"]");
    return self.node(.{ .dict = .{ .items = if (items.len > 0) items else null } });
  }

  fn parseTable(self: *Parser) ParseError!*Node {
    self.advance(); // consume '[[]'
    const items = try self.parseItems(.@"]");
    _ = self.eat(.@"]");
    return self.node(.{ .table = .{ .items = if (items.len > 0) items else null } });
  }

  fn parseUTable(self: *Parser) ParseError!*Node {
    self.advance(); // consume '[['
    const keys = try self.parseItems(.@"]");
    _ = self.eat(.@"]");
    const vals = try self.parseItems(.@"]");
    _ = self.eat(.@"]");
    return self.node(.{ .utable = .{
      .keys = if (keys.len > 0) keys else null,
      .items = if (vals.len > 0) vals else null,
    } });
  }

  fn parseItems(self: *Parser, end_tt: TT) ParseError!ast.Items {
    var items = try std.ArrayList(ast.Item).initCapacity(self.al(), 0);
    while (!self.is(end_tt) and !self.is(.eof)) {
      self.skipComments();
      if (self.is(end_tt) or self.is(.eof)) break;
      if (self.is(.sep)) { self.advance(); continue; }
      const key = try self.parseItemKey() orelse break;
      if (!self.eat(.@":")) break;
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
    self.advance(); // consume '['
    if (self.eat(.@"]")) return self.node(.{ .apply = .{ .f = f, .a = null } });
    const seq = try self.parseSeq(.@"]");
    _ = self.eat(.@"]");
    return self.node(.{ .apply = .{ .f = f, .a = seq } });
  }

  fn parseCond(self: *Parser) ParseError!*Node {
    self.advance(); // consume '$['
    var stmts = try std.ArrayList(*Node).initCapacity(self.al(), 0);
    while (!self.is(.@"]") and !self.is(.eof)) {
      self.skipComments();
      if (self.is(.@"]")) break;
      if (self.is(.sep)) { self.advance(); continue; }
      try stmts.append(self.al(), try self.parseStmt());
    }
    _ = self.eat(.@"]");
    return self.node(.{ .cond = .{ .stmts = try stmts.toOwnedSlice(self.al()) } });
  }

  fn parseIntLit(s: []const u8) ParseError!i32 {
    if (eql(u8, s, "0N") or eql(u8, s, "-0N")) return std.math.minInt(i32);
    return std.fmt.parseInt(i32, s, 0) catch error.InvalidCharacter;
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
  const n2 = try p.parse("[name:\"Bob\";age:42]");
  const s2 = n2.terse.stmts[0].node;
  try std.testing.expect(s2.* == .dict);
  try std.testing.expect(s2.dict.items.?.len == 2);
  const n3 = try p.parse("*:1 2 3");
  const s3 = n3.terse.stmts[0].node;
  try std.testing.expect(s3.* == .apposit);
  try std.testing.expect(s3.apposit.f.* == .monad);
}
