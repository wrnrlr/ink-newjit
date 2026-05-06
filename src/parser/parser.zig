// Hand-written recursive-descent parser for the terse/ink language.
// Evaluation order in K is right-to-left, so the parser is right-recursive.

const std = @import("std");
const Alloc = std.mem.Allocator;
const ast = @import("ast.zig");
const lex = @import("lexer.zig");

const Node = ast.Node;
const Literal = ast.Literal;
const Seq = ast.Seq;
const Args = ast.Args;
const Items = ast.Items;
const Item = ast.Item;
const Arg = ast.Arg;

const TT = lex.TT;
const Token = lex.Token;
const Lexer = lex.Lexer;

const parseInt = std.fmt.parseInt;
const parseFloat = std.fmt.parseFloat;
const eql = std.mem.eql;
const trim = std.mem.trim;

pub const ParseError = error{
  OutOfMemory,
  Overflow,
  InvalidCharacter,
  UnexpectedToken,
};

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

  pub fn deinit(self: *Parser) void { self.arena.deinit(); }

  fn advance(self: *Parser) void {
    self.tok = self.lex.next();
  }

  // Advance past comment and sep tokens.
  fn skipComments(self: *Parser) void {
    while (self.tok.tt == .comment) self.advance();
  }

  fn is(self: *Parser, tt: TT) bool {
    return self.tok.tt == tt;
  }

  fn eat(self: *Parser, tt: TT) bool {
    if (self.tok.tt == tt) { self.advance(); return true; }
    return false;
  }

  fn tokSlice(self: *Parser) []const u8 {
    return self.tok.slice(self.src);
  }

  // True if the current token can begin a noun.
  fn isNounStart(self: *Parser) bool {
    return switch (self.tok.tt) {
      .int, .float, .bit, .bits,
      .string, .symbol, .var_,
      .@"(", .@"{", .@"[",
      .@"$[",
      .@"[[]", .@"[[",
      .adverb_val,
      => true,
      else => false,
    };
  }

  // True if the current token can begin a verb.
  fn isVerbStart(self: *Parser) bool {
    return switch (self.tok.tt) {
      .op, .keyword_op, .verb_io => true,
      else => false,
    };
  }

  // True if we are at a statement boundary.
  fn isStmtEnd(self: *Parser) bool {
    return switch (self.tok.tt) {
      .sep, .eof, .@"}", .@"]", .@")" => true,
      else => false,
    };
  }

  // ---- Top-level ----

  pub fn parse(self: *Parser, src: []const u8) ParseError!*Node {
    _ = self.arena.reset(.retain_capacity);
    self.src = src;
    self.lex = Lexer.init(src);
    self.tok = self.lex.next();
    return self.parseTerse();
  }

  fn parseTerse(self: *Parser) ParseError!*Node {
    var stmts = try std.ArrayList(ast.Stmt).initCapacity(self.arena.allocator(), 0);
    // Skip leading comments/seps
    while (self.tok.tt == .sep or self.tok.tt == .comment) self.advance();

    while (self.tok.tt != .eof) {
      if (self.tok.tt == .sep) {
        // Explicit semicolon produces a blank if this is not a newline separator
        // between statements. We mimic tree-sitter: only `;` (not `\n`) at top
        // level produces a blank statement.
        const sep_slice = self.tok.slice(self.src);
        const is_semicolon = sep_slice.len > 0 and sep_slice[0] == ';';
        self.advance();
        self.skipComments();
        if (is_semicolon) {
          const m = try self.arena.allocator().create(Node);
          m.* = .blank;
          try stmts.append(self.arena.allocator(), .{ .node = m, .source = ";" });
        }
        continue;
      }

      const stmt_start = self.tok.start;
      const node = try self.parseStmt();
      // tok.start now points just past the statement (at sep, comment, eof, etc.)
      const raw_end = self.tok.start;
      const source = trim(u8, self.src[stmt_start..raw_end], " \t\n");
      try stmts.append(self.arena.allocator(), .{ .node = node, .source = source });

      self.skipComments();
      // After a statement, consume a sep if present
      if (self.tok.tt == .sep) {
        self.advance();
        self.skipComments();
      } else {
        break;
      }
    }

    const m = try self.arena.allocator().create(Node);
    m.* = .{ .terse = .{ .stmts = try stmts.toOwnedSlice(self.arena.allocator()) } };
    return m;
  }

  // ---- Statement ----

  fn parseStmt(self: *Parser) ParseError!*Node {
    self.skipComments();

    // ':' clause  →  right  (or defer with adjunct, compiled identically)
    // ':' alone (followed by sep/end) → standalone ':' op (e.g. in @[arr; i; :; val])
    if (self.is(.@":")) {
      const colon_tok = self.tok;
      self.advance();
      if (self.isStmtEnd() or self.is(.comment)) {
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .verb_op = colon_tok.slice(self.src) };
        return m;
      }
      const clause = try self.parseStmt();
      const m = try self.arena.allocator().create(Node);
      m.* = .{ .right = .{ .clause = clause } };
      return m;
    }

    // Verb at start (no left noun)
    if (self.isVerbStart()) {
      return self.parseVerbLedStmt();
    }

    if (!self.isNounStart()) {
      const m = try self.arena.allocator().create(Node);
      m.* = .blank;
      return m;
    }

    // Parse a noun
    const noun = try self.parseNoun();

    // What follows?
    self.skipComments();
    return self.parseAfterNoun(noun);
  }

  // After parsing a noun, decide what the overall expression is.
  fn parseAfterNoun(self: *Parser, noun: *Node) ParseError!*Node {
    self.skipComments();

    // Explicit apply: noun[...] — chains (f[1][2] works)
    if (self.is(.@"[")) {
      const applied = try self.parseApply(noun);
      return self.parseAfterNoun(applied);
    }

    // Check for bind: noun (op)? ':' (clause)?
    if (self.is(.@":")) {
      return self.parseBind(noun, null);
    }

    // op followed by colon → compound bind: noun op ':' (clause)?
    if (self.is(.op) or self.is(.keyword_op)) {
      const op_tok = self.tok;
      // Peek: is the character immediately after op a ':' making it 'op:'?
      // We need to detect `noun op ':' clause` vs `noun op clause`.
      // Save state and advance to check.
      const saved_pos = self.lex.pos;
      const saved_an  = self.lex.after_noun;
      const saved_av  = self.lex.after_verb;
      const saved_tok = self.tok;
      self.advance(); // consume op
      if (self.is(.@":")) {
        // compound bind: noun op ':'
        return self.parseBind(noun, op_tok.slice(self.src));
      }
      // Not a bind. Build verb node from saved op_tok and continue as transit.
      const verb_node = try self.makeVerbNode(op_tok);
      // Handle adverb immediately following (term)
      const verb = try self.applyAdverb(verb_node);
      _ = saved_pos; _ = saved_an; _ = saved_av; _ = saved_tok;
      // Now expect right clause for transit
      if (self.isStmtEnd() or self.is(.comment)) {
        // intrans: noun verb (no right arg)
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .intrans = .{ .a = noun, .v = verb, .z = null } };
        return m;
      }
      const b = try self.parseStmt();
      const m = try self.arena.allocator().create(Node);
      m.* = .{ .transit = .{ .a = noun, .v = verb, .b = b } };
      return m;
    }

    // verb_io followed by colon would have been consumed as verb_io already,
    // so handle it as transit:
    if (self.is(.verb_io)) {
      const verb_node = try self.makeVerbNode(self.tok);
      self.advance();
      if (self.isStmtEnd() or self.is(.comment)) {
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .intrans = .{ .a = noun, .v = verb_node, .z = null } };
        return m;
      }
      const b = try self.parseStmt();
      const m = try self.arena.allocator().create(Node);
      m.* = .{ .transit = .{ .a = noun, .v = verb_node, .b = b } };
      return m;
    }

    // Adverb after noun → term; chain multiple adverbs (e.g. f/' → term(term(f,/),'))
    if (self.is(.adverb)) {
      var term: *Node = noun;
      while (self.is(.adverb)) {
        const adv_tok = self.tok;
        self.advance();
        term = try self.makeTerm(term, adv_tok);
      }
      // f/[...] or f/'[...]: apply the derived verb
      if (self.is(.@"[")) {
        const applied = try self.parseApply(term);
        return self.parseAfterNoun(applied);
      }
      if (self.isNounStart() or self.isVerbStart()) {
        const a = try self.parseStmt();
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .apposit = .{ .f = term, .a = a } };
        return m;
      }
      return term;
    }

    // Noun followed by another noun → check for digram transit (left verb-noun adverb right)
    // vs regular apposit. Parse just the inner noun first, then peek for an adverb.
    if (self.isNounStart()) {
      var inner = try self.parseNoun();
      // Allow bracket applications on the inner noun before checking for adverb.
      while (self.is(.@"[")) inner = try self.parseApply(inner);
      if (self.is(.adverb)) {
        // Digram: noun noun adverb [rhs] → transit(noun, term(noun, adverb), rhs)
        var verb = inner;
        while (self.is(.adverb)) {
          const adv_tok = self.tok;
          self.advance();
          verb = try self.makeTerm(verb, adv_tok);
        }
        if (self.is(.@"[")) {
          const applied = try self.parseApply(verb);
          return self.parseAfterNoun(applied);
        }
        if (self.isStmtEnd() or self.is(.comment)) {
          const m = try self.arena.allocator().create(Node);
          m.* = .{ .intrans = .{ .a = noun, .v = verb, .z = null } };
          return m;
        }
        const b = try self.parseStmt();
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .transit = .{ .a = noun, .v = verb, .b = b } };
        return m;
      }
      // No adverb: finish parsing the inner expression normally, then apposit.
      const rest = try self.parseAfterNoun(inner);
      const m = try self.arena.allocator().create(Node);
      m.* = .{ .apposit = .{ .f = noun, .a = rest } };
      return m;
    }

    return noun;
  }

  // Parse bind: noun (op_str)? ':' (clause)?
  fn parseBind(self: *Parser, noun: *Node, op_str: ?[]const u8) ParseError!*Node {
    // Consume the ':'
    std.debug.assert(self.is(.@":"));
    self.advance();
    var rhs: ?*Node = null;
    if (!self.isStmtEnd() and !self.is(.comment)) {
      rhs = try self.parseStmt();
    }
    const m = try self.arena.allocator().create(Node);
    m.* = .{ .bind = .{ .v = noun, .f = op_str, .a = rhs } };
    return m;
  }

  // Verb at start of statement: monad value, compose, or monadic application.
  fn parseVerbLedStmt(self: *Parser) ParseError!*Node {
    const verb_node = try self.makeVerbNode(self.tok);
    self.advance();

    // Check for monad: op ':' (e.g. *: as first-class value)
    if (self.is(.@":")) {
      self.advance();
      const op_str = if (verb_node.* == .verb_op) verb_node.verb_op else "";
      // The monad value. If followed by a noun → apposit(monad, noun)
      const mv = try self.arena.allocator().create(Node);
      mv.* = .{ .monad = .{ .f = op_str } };
      self.arena.allocator().destroy(verb_node);
      if (!self.isStmtEnd() and !self.is(.comment) and
        (self.isNounStart() or self.isVerbStart()))
      {
        const a = try self.parseStmt();
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .apposit = .{ .f = mv, .a = a } };
        return m;
      }
      return mv;
    }

    // Apply adverbs; chain multiple (e.g. +/' → term(term(+,/),'))
    var verb: *Node = verb_node;
    while (self.is(.adverb)) {
      const adv_tok = self.tok;
      self.advance();
      verb = try self.makeTerm(verb, adv_tok);
    }

    // f[...]: apply the verb/term directly (e.g. %[4;2], +/[0;10])
    if (self.is(.@"[")) {
      const applied = try self.parseApply(verb);
      return self.parseAfterNoun(applied);
    }

    // If followed by a clause → apposit (monadic application)
    if (!self.isStmtEnd() and !self.is(.comment) and
      (self.isNounStart() or self.isVerbStart()))
    {
      const a = try self.parseStmt();
      const m = try self.arena.allocator().create(Node);
      m.* = .{ .apposit = .{ .f = verb, .a = a } };
      return m;
    }

    return verb;
  }

  // If current token is an adverb, wrap verb in a term node.
  fn applyAdverb(self: *Parser, verb: *Node) ParseError!*Node {
    if (!self.is(.adverb)) return verb;
    const adv_tok = self.tok;
    self.advance();
    return self.makeTerm(verb, adv_tok);
  }

  fn makeTerm(self: *Parser, f: *Node, adv_tok: Token) ParseError!*Node {
    const adv_str = adv_tok.slice(self.src);
    const m = try self.arena.allocator().create(Node);
    m.* = .{ .term = .{ .f = f, .a = adv_str } };
    return m;
  }

  fn makeVerbNode(self: *Parser, tok: Token) ParseError!*Node {
    const m = try self.arena.allocator().create(Node);
    m.* = switch (tok.tt) {
      .op, .keyword_op => .{ .verb_op = tok.slice(self.src) },
      .verb_io => .{ .verb_io = tok.slice(self.src) },
      else => .blank,
    };
    return m;
  }

  // ---- Noun parsing ----

  fn parseNoun(self: *Parser) ParseError!*Node {
    const tok = self.tok;
    switch (tok.tt) {
      .int, .float, .bit, .bits,
      .string, .symbol, .var_,
      => return self.parseLiteralOrVector(),

      .@"(" => return self.parseGroupOrList(),
      .@"{" => return self.parseLambda(),
      .@"[" => return self.parseDictOrArgs(),
      .@"[[]" => return self.parseTable(),
      .@"[[" => return self.parseUTable(),
      .@"$[" => return self.parseCond(),
      .adverb_val => {
        const adv = tok.slice(self.src);
        self.advance();
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .adverb_val = adv };
        return m;
      },
      else => {
        const m = try self.arena.allocator().create(Node);
        m.* = .blank;
        return m;
      },
    }
  }

  // ---- Literal and vector stranding ----

  fn parseLiteralOrVector(self: *Parser) ParseError!*Node {
    const tok = self.tok;
    self.advance();

    // Stranding: collect consecutive same-type literals into vectors
    switch (tok.tt) {
      .int => {
        // Collect ints, interleaving positive and negative (0 1 -2 0N forms a vector).
        // A '-' is a vector element only when BOTH:
        //   • there is whitespace before it (gap from preceding element, so 10-3 is subtraction)
        //   • it is immediately adjacent to the following int (no space, so "- 3" is not negation)
        var ints = try std.ArrayList(i32).initCapacity(self.arena.allocator(), 0);
        try ints.append(self.arena.allocator(), try parseIntLit(tok.slice(self.src)));
        var last_end = tok.end;
        outer: while (true) {
          while (self.tok.tt == .int) {
            try ints.append(self.arena.allocator(), try parseIntLit(self.tok.slice(self.src)));
            last_end = self.tok.end;
            self.advance();
          }
          if (self.tok.tt == .op and eql(u8, self.tok.slice(self.src), "-")) {
            const minus_start = self.tok.start;
            const minus_end = self.tok.end;
            const next_tok = self.lex.peekNext();
            if (next_tok.tt == .int and next_tok.start == minus_end and minus_start > last_end) {
              self.advance(); // consume '-'
              const neg_val = try parseIntLit(self.tok.slice(self.src));
              last_end = self.tok.end;
              self.advance();
              try ints.append(self.arena.allocator(), -neg_val);
            } else break :outer;
          } else break :outer;
        }
        const items = try ints.toOwnedSlice(self.arena.allocator());
        const m = try self.arena.allocator().create(Node);
        if (items.len == 1) {
          defer self.arena.allocator().free(items);
          m.* = .{ .literal = .{ .i = items[0] } };
        } else {
          m.* = .{ .literal = .{ .I = items } };
        }
        return m;
      },
      .float => {
        var floats = try std.ArrayList(f32).initCapacity(self.arena.allocator(), 0);
        try floats.append(self.arena.allocator(), try parseFloatLit(tok.slice(self.src)));
        var last_end = tok.end;
        outer: while (true) {
          // Collect floats and ints (ints coerced to float in float context).
          while (self.tok.tt == .float or self.tok.tt == .int) {
            if (self.tok.tt == .float) {
              try floats.append(self.arena.allocator(), try parseFloatLit(self.tok.slice(self.src)));
            } else {
              const iv = try parseIntLit(self.tok.slice(self.src));
              try floats.append(self.arena.allocator(), @floatFromInt(iv));
            }
            last_end = self.tok.end;
            self.advance();
          }
          if (self.tok.tt == .op and eql(u8, self.tok.slice(self.src), "-")) {
            const minus_start = self.tok.start;
            const minus_end = self.tok.end;
            const next_tok = self.lex.peekNext();
            if ((next_tok.tt == .float or next_tok.tt == .int) and next_tok.start == minus_end and minus_start > last_end) {
              self.advance();
              if (self.tok.tt == .float) {
                const neg_val = try parseFloatLit(self.tok.slice(self.src));
                last_end = self.tok.end;
                self.advance();
                try floats.append(self.arena.allocator(), -neg_val);
              } else {
                const neg_val = try parseIntLit(self.tok.slice(self.src));
                last_end = self.tok.end;
                self.advance();
                try floats.append(self.arena.allocator(), -@as(f32, @floatFromInt(neg_val)));
              }
            } else break :outer;
          } else break :outer;
        }
        const items = try floats.toOwnedSlice(self.arena.allocator());
        const m = try self.arena.allocator().create(Node);
        if (items.len == 1) {
          defer self.arena.allocator().free(items);
          m.* = .{ .literal = .{ .f = items[0] } };
        } else {
          m.* = .{ .literal = .{ .F = items } };
        }
        return m;
      },
      .bit, .bits => {
        var bools = try std.ArrayList(bool).initCapacity(self.arena.allocator(), 0);
        try appendBools(self.arena.allocator(), &bools, tok.slice(self.src), tok.tt == .bits);
        while (self.tok.tt == .bit or self.tok.tt == .bits) {
          const t2 = self.tok;
          self.advance();
          try appendBools(self.arena.allocator(), &bools, t2.slice(self.src), t2.tt == .bits);
        }
        const items = try bools.toOwnedSlice(self.arena.allocator());
        const m = try self.arena.allocator().create(Node);
        if (items.len == 1) {
          defer self.arena.allocator().free(items);
          m.* = .{ .literal = .{ .b = items[0] } };
        } else {
          m.* = .{ .literal = .{ .B = items } };
        }
        return m;
      },
      .symbol => {
        // Check for stranded symbols: `a`b`c
        // After a symbol, if next is also symbol (backtick), collect
        if (self.tok.tt != .symbol) {
          // Single symbol
          const s = symbolBody(tok.slice(self.src));
          const m = try self.arena.allocator().create(Node);
          m.* = .{ .literal = .{ .s = s } };
          return m;
        }
        // Multiple symbols → .S
        var syms = try std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0);
        try syms.append(self.arena.allocator(), symbolBody(tok.slice(self.src)));
        while (self.tok.tt == .symbol) {
          try syms.append(self.arena.allocator(), symbolBody(self.tok.slice(self.src)));
          self.advance();
        }
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .literal = .{ .S = try syms.toOwnedSlice(self.arena.allocator()) } };
        return m;
      },
      .string => {
        const full = tok.slice(self.src);
        // Strip surrounding quotes
        const inner = if (full.len >= 2) full[1 .. full.len - 1] else "";
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .literal = .{ .c = inner } };
        return m;
      },
      .var_ => {
        const m = try self.arena.allocator().create(Node);
        m.* = .{ .literal = .{ .@"var" = tok.slice(self.src) } };
        return m;
      },
      else => unreachable,
    }
  }

  // ---- Group / List ----

  fn parseGroupOrList(self: *Parser) ParseError!*Node {
    std.debug.assert(self.is(.@"("));
    self.advance(); // consume '('

    // Empty list: ()
    if (self.eat(.@")")) {
      const m = try self.arena.allocator().create(Node);
      m.* = .{ .list = .{ .seq = null } };
      return m;
    }

    // adverb_val as group content: (') or (\)
    if (self.is(.adverb_val)) {
      const adv = self.tok.slice(self.src);
      self.advance();
      _ = self.eat(.@")");
      const av = try self.arena.allocator().create(Node);
      av.* = .{ .adverb_val = adv };
      const m = try self.arena.allocator().create(Node);
      m.* = .{ .group = .{ .stmt = av } };
      return m;
    }

    // Parse sequence inside parens
    const seq = try self.parseSeq(.@")");
    _ = self.eat(.@")");

    const m = try self.arena.allocator().create(Node);
    if (seq.len == 1) {
      // Single statement → group
      m.* = .{ .group = .{ .stmt = seq[0] } };
      self.arena.allocator().free(seq);
    } else {
      m.* = .{ .list = .{ .seq = seq } };
    }
    return m;
  }

  // Parse a seq of statements separated by sep, ending before `end_tt`.
  fn parseSeq(self: *Parser, end_tt: TT) ParseError!Seq {
    var stmts = try std.ArrayList(*Node).initCapacity(self.arena.allocator(), 0);
    var last_was_sep = false;

    while (!self.is(end_tt) and !self.is(.eof)) {
      self.skipComments();
      if (self.is(end_tt) or self.is(.eof)) break;

      if (self.is(.sep)) {
        if (last_was_sep) {
          const blank = try self.arena.allocator().create(Node);
          blank.* = .blank;
          try stmts.append(self.arena.allocator(), blank);
        }
        self.advance();
        last_was_sep = true;
        continue;
      }

      last_was_sep = false;
      const node = try self.parseStmt();
      try stmts.append(self.arena.allocator(), node);
      self.skipComments();
    }
    if (last_was_sep) {
      const blank = try self.arena.allocator().create(Node);
      blank.* = .blank;
      try stmts.append(self.arena.allocator(), blank);
    }
    return stmts.toOwnedSlice(self.arena.allocator());
  }

  fn parseLambda(self: *Parser) ParseError!*Node {
    std.debug.assert(self.is(.@"{"));
    const start_byte = self.tok.start;
    self.advance(); // consume '{'

    var args: ?Args = null;
    // Optional args: [a;b;c]
    if (self.is(.@"[")) {
      self.advance();
      args = try self.parseArgList();
    }

    var seq: ?Seq = null;
    if (!self.is(.@"}")) {
      seq = try self.parseSeq(.@"}");
    }

    const end_byte = self.tok.end;
    _ = self.eat(.@"}");

    const m = try self.arena.allocator().create(Node);
    m.* = .{ .lambda = .{ .a = args, .b = seq, .start = start_byte, .end = end_byte } };
    return m;
  }

  fn parseArgList(self: *Parser) ParseError!Args {
    var args = try std.ArrayList(Arg).initCapacity(self.arena.allocator(), 0);
    var awaiting = true;
    while (!self.is(.@"]") and !self.is(.eof)) {
      self.skipComments();
      if (self.is(.sep)) {
        if (awaiting) try args.append(self.arena.allocator(), .{ .is_some = false, .value = "" });
        awaiting = true;
        self.advance();
        continue;
      }
      if (self.is(.var_)) {
        if (awaiting) {
          try args.append(self.arena.allocator(), .{ .is_some = true, .value = self.tokSlice() });
          awaiting = false;
        }
        self.advance();
      } else {
        self.advance();
      }
    }
    if (awaiting and args.items.len > 0)
      try args.append(self.arena.allocator(), .{ .is_some = false, .value = "" });
    _ = self.eat(.@"]");
    return args.toOwnedSlice(self.arena.allocator());
  }

  fn parseDictOrArgs(self: *Parser) ParseError!*Node {
    // '[' can be a dict '[k:v;...]'
    std.debug.assert(self.is(.@"["));
    self.advance();

    if (self.is(.@"]")) {
      self.advance();
      const m = try self.arena.allocator().create(Node);
      m.* = .{ .dict = .{ .items = null } };
      return m;
    }

    const items = try self.parseItems(.@"]");
    _ = self.eat(.@"]");

    const m = try self.arena.allocator().create(Node);
    m.* = .{ .dict = .{ .items = if (items.len > 0) items else null } };
    return m;
  }

  fn parseTable(self: *Parser) ParseError!*Node {
    // table_open = '[[]'
    std.debug.assert(self.is(.@"[[]"));
    self.advance();
    const items = try self.parseItems(.@"]");
    _ = self.eat(.@"]");
    const m = try self.arena.allocator().create(Node);
    m.* = .{ .table = .{ .items = if (items.len > 0) items else null } };
    return m;
  }

  fn parseUTable(self: *Parser) ParseError!*Node {
    // utable_open = '[['
    std.debug.assert(self.is(.@"[["));
    self.advance();
    const keys = try self.parseItems(.@"]");
    _ = self.eat(.@"]");
    const vals = try self.parseItems(.@"]");
    _ = self.eat(.@"]");
    const m = try self.arena.allocator().create(Node);
    m.* = .{ .utable = .{
      .keys = if (keys.len > 0) keys else null,
      .items = if (vals.len > 0) vals else null,
    } };
    return m;
  }

  // Parse key:value items inside dict/table, ending at end_tt.
  fn parseItems(self: *Parser, end_tt: TT) ParseError!Items {
    var items = try std.ArrayList(Item).initCapacity(self.arena.allocator(), 0);
    while (!self.is(end_tt) and !self.is(.eof)) {
      self.skipComments();
      if (self.is(end_tt) or self.is(.eof)) break;
      if (self.is(.sep)) { self.advance(); continue; }

      // Parse key: one of int, string, symbol, var
      const key = try self.parseItemKey() orelse break;

      // Consume ':'
      if (!self.eat(.@":")) break;

      // Parse value (optional)
      var val: *Node = undefined;
      if (self.is(end_tt) or self.is(.sep) or self.is(.eof)) {
        val = try self.arena.allocator().create(Node);
        val.* = .blank;
      } else {
        val = try self.parseStmt();
      }
      try items.append(self.arena.allocator(), .{ .k = key, .v = val });
    }
    return items.toOwnedSlice(self.arena.allocator());
  }

  fn parseItemKey(self: *Parser) ParseError!?[]const u8 {
    switch (self.tok.tt) {
      .var_, .int, .string, .symbol => {
        const s = self.tok.slice(self.src);
        const key = switch (self.tok.tt) {
          .string => if (s.len >= 2) s[1 .. s.len - 1] else s,
          .symbol => symbolBody(s),
          else => s,
        };
        self.advance();
        return key;
      },
      else => return null,
    }
  }

  // Explicit function application: f[a;b;c]
  fn parseApply(self: *Parser, f: *Node) ParseError!*Node {
    std.debug.assert(self.is(.@"["));
    self.advance();
    if (self.eat(.@"]")) {
      const m = try self.arena.allocator().create(Node);
      m.* = .{ .apply = .{ .f = f, .a = null } };
      return m;
    }
    const seq = try self.parseSeq(.@"]");
    _ = self.eat(.@"]");
    const m = try self.arena.allocator().create(Node);
    m.* = .{ .apply = .{ .f = f, .a = seq } };
    return m;
  }

  fn parseCond(self: *Parser) ParseError!*Node {
    std.debug.assert(self.is(.@"$["));
    self.advance();
    var stmts = try std.ArrayList(*Node).initCapacity(self.arena.allocator(), 0);
    while (!self.is(.@"]") and !self.is(.eof)) {
      self.skipComments();
      if (self.is(.@"]")) break;
      if (self.is(.sep)) { self.advance(); continue; }
      try stmts.append(self.arena.allocator(), try self.parseStmt());
    }
    _ = self.eat(.@"]");
    const m = try self.arena.allocator().create(Node);
    m.* = .{ .cond = .{ .stmts = try stmts.toOwnedSlice(self.arena.allocator()) } };
    return m;
  }

  // ---- Literal helpers ----

  fn parseIntLit(s: []const u8) ParseError!i32 {
    if (eql(u8, s, "0N") or eql(u8, s, "-0N")) return std.math.minInt(i32);
    return parseInt(i32, s, 0) catch return error.InvalidCharacter;
  }

  fn parseFloatLit(s: []const u8) ParseError!f32 {
    if (eql(u8, s, "0n") or eql(u8, s, "-0n")) return std.math.nan(f32);
    if (eql(u8, s, "0w")) return std.math.inf(f32);
    if (eql(u8, s, "-0w")) return -std.math.inf(f32);
    return parseFloat(f32, s) catch return error.InvalidCharacter;
  }

  fn appendBools(alloc: Alloc, list: *std.ArrayList(bool), s: []const u8, is_vec: bool) !void {
    if (is_vec) {
      const digits = s[0 .. s.len - 1];
      for (digits) |d| try list.append(alloc, d == '1');
    } else {
      try list.append(alloc, s[0] == '1');
    }
  }

  fn symbolBody(s: []const u8) []const u8 {
    // s starts with '`'
    if (s.len <= 1) return "";
    var body = s[1..];
    if (body.len >= 2 and body[0] == '"' and body[body.len - 1] == '"')
      body = body[1 .. body.len - 1];
    return body;
  }

  pub fn free(_: Parser, _: *Node) void {}
};


// ---- Tests ----

const ta = std.testing.allocator;

test "parse int" {
  var p = Parser.init(ta);
  const n = try p.parse("42");
  defer p.deinit();
  try std.testing.expect(n.* == .terse);
  try std.testing.expect(n.terse.stmts.len == 1);
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.* == .literal);
  try std.testing.expect(s.literal == .i);
  try std.testing.expectEqual(@as(i32, 42), s.literal.i);
}

test "parse ints vector" {
  var p = Parser.init(ta);
  const n = try p.parse("1 2 3");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.literal == .I);
  try std.testing.expectEqualSlices(i32, &.{1, 2, 3}, s.literal.I);
}

test "parse bind" {
  var p = Parser.init(ta);
  const n = try p.parse("a:1");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.* == .bind);
  try std.testing.expect(s.bind.v.literal == .@"var");
  try std.testing.expectEqualStrings("a", s.bind.v.literal.@"var");
  try std.testing.expect(s.bind.a.?.literal == .i);
}

test "parse transit" {
  var p = Parser.init(ta);
  const n = try p.parse("1+1");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.* == .transit);
  try std.testing.expectEqualStrings("+", s.transit.v.verb_op);
}

test "parse apposit (f a)" {
  var p = Parser.init(ta);
  const n = try p.parse("f 1");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.* == .apposit);
  try std.testing.expectEqualStrings("f", s.apposit.f.literal.@"var");
}

test "parse adverb term" {
  var p = Parser.init(ta);
  const n = try p.parse("+/ 1 2 3");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.* == .apposit);
  try std.testing.expect(s.apposit.f.* == .term);
  try std.testing.expectEqualStrings("+", s.apposit.f.term.f.verb_op);
  try std.testing.expectEqualStrings("/", s.apposit.f.term.a);
}

test "parse lambda" {
  var p = Parser.init(ta);
  const n = try p.parse("{x+1}");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.* == .lambda);
  try std.testing.expect(s.lambda.a == null);
  try std.testing.expect(s.lambda.b != null);
  const seq = s.lambda.b.?;
  try std.testing.expect(seq.len == 1);
  try std.testing.expect(seq[0].* == .transit);
}

test "parse list" {
  var p = Parser.init(ta);
  const n = try p.parse("(1 2 3; 4 5 6)");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.* == .list);
  try std.testing.expect(s.list.seq.?.len == 2);
}

test "parse dict" {
  var p = Parser.init(ta);
  const n = try p.parse("[name:\"Bob\";age:42]");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.* == .dict);
  try std.testing.expect(s.dict.items.?.len == 2);
}

test "parse symbol" {
  var p = Parser.init(ta);
  const n = try p.parse("`abc");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.literal == .s);
  try std.testing.expectEqualStrings("abc", s.literal.s);
}

test "parse monad value" {
  var p = Parser.init(ta);
  const n = try p.parse("*:1 2 3");
  defer p.deinit();
  const s = n.terse.stmts[0].node;
  try std.testing.expect(s.* == .apposit);
  try std.testing.expect(s.apposit.f.* == .monad);
}
