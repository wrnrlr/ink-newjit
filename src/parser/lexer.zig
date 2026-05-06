const std = @import("std");

pub const TT = enum {
  int, float,
  bit, bits,
  string, symbol,
  var_,
  keyword_op, op, verb_io,
  adverb, adverb_val,
  @":",
  @"(", @")",
  @"{", @"}",
  @"[", @"]",
  @"$[",
  @"[[]", @"[[",
  sep,
  comment,
  command,
  eof,
};

pub const Token = struct {
  tt: TT, start: u32, end: u32,
  pub fn slice(t: Token, s: []const u8) []const u8 { return s[t.start..t.end]; }
  pub fn len(t: Token) u32 { return t.end - t.start; }
};

const KEYWORD_OPS = [_][]const u8{
  "sqrt", "sqr", "exp", "log", "sin", "cos", "abs",
  "first", "last", "count", "in", "has",
  "parse",
};

fn isKeywordOp(s: []const u8) bool {
  for (KEYWORD_OPS) |kw| {
    if (std.mem.eql(u8, s, kw)) return true;
  }
  return false;
}

// A '"' inside a K string closes the string only when the next character is one of these.
// This implements the "string doubling" convention: "" inside a string is a literal quote.
fn isStringCloseChar(c: u8) bool {
  return switch (c) {
    0, '\n', '\t', ' ', ';' => true,
    '(', ')', '[', ']', '{', '}' => true,
    '`' => true,
    '0'...'9' => true,
    '\\' => true,
    else => std.mem.indexOfScalar(u8, "%!&+*|<>=~,^#_$?@./-:", c) != null,
  };
}

pub const Lexer = struct {
  src: []const u8,
  pos: u32,
  after_noun: bool, // last emitted token was noun-like (int/float/var/)/}/])
  after_verb: bool, // last emitted token was verb-like (op/keyword_op/verb_io/adverb)

  pub fn init(src: []const u8) Lexer {
    return .{ .src = src, .pos = 0, .after_noun = false, .after_verb = false };
  }

  fn ch(self: *Lexer) ?u8 {
    if (self.pos >= self.src.len) return null;
    return self.src[self.pos];
  }

  fn ch1(self: *Lexer) ?u8 {
    if (self.pos + 1 >= self.src.len) return null;
    return self.src[self.pos + 1];
  }

  fn ch2(self: *Lexer) ?u8 {
    if (self.pos + 2 >= self.src.len) return null;
    return self.src[self.pos + 2];
  }

  fn adv(self: *Lexer) void {
    if (self.pos < self.src.len) self.pos += 1;
  }

  // Returns true if whitespace (spaces/tabs only, not newlines) was skipped.
  fn skipSpace(self: *Lexer) bool {
    const start = self.pos;
    while (self.pos < self.src.len and
      (self.src[self.pos] == ' ' or self.src[self.pos] == '\t'))
    {
      self.pos += 1;
    }
    return self.pos > start;
  }

  fn setNoun(self: *Lexer) void {
    self.after_noun = true;
    self.after_verb = false;
  }
  fn setVerb(self: *Lexer) void {
    self.after_noun = false;
    self.after_verb = true;
  }
  fn setNeither(self: *Lexer) void {
    self.after_noun = false;
    self.after_verb = false;
  }

  pub fn next(self: *Lexer) Token {
    const had_space = self.skipSpace();
    if (self.pos >= self.src.len) {
      return .{ .tt = .eof, .start = self.pos, .end = self.pos };
    }
    const start = self.pos;
    const c = self.src[self.pos];

    // Newline -> sep
    if (c == '\n') {
      self.adv();
      self.setNeither();
      return .{ .tt = .sep, .start = start, .end = self.pos };
    }

    // Semicolon -> sep
    if (c == ';') {
      self.adv();
      self.setNeither();
      return .{ .tt = .sep, .start = start, .end = self.pos };
    }

    // Comment: / with whitespace before it (or at start / after sep)
    if (c == '/' and (had_space or (!self.after_noun and !self.after_verb))) {
      while (self.pos < self.src.len and self.src[self.pos] != '\n')
        self.adv();
      self.setNeither();
      return .{ .tt = .comment, .start = start, .end = self.pos };
    }

    // Adverb or adverb_val for '
    if (c == '\'') {
      if ((self.after_noun or self.after_verb) and !had_space) {
        self.adv();
        if (self.ch() == ':') self.adv();
        self.setVerb();
        return .{ .tt = .adverb, .start = start, .end = self.pos };
      }
      // adverb_val: ' as noun value (inside group etc.)
      self.adv();
      self.setNoun();
      return .{ .tt = .adverb_val, .start = start, .end = self.pos };
    }

    // Backslash
    if (c == '\\') {
      // Adverb \: or \ takes priority when immediately after a noun or verb
      if ((self.after_noun or self.after_verb) and !had_space) {
        self.adv();
        if (self.ch() == ':') self.adv();
        self.setVerb();
        return .{ .tt = .adverb, .start = start, .end = self.pos };
      }
      // Command: \letter... (only at start of expression, not after noun/verb)
      if (self.ch1()) |n| {
        if (std.ascii.isAlphabetic(n)) {
          self.adv(); // skip '\'
          while (self.pos < self.src.len and self.src[self.pos] != '\n')
            self.adv();
          self.setNeither();
          return .{ .tt = .command, .start = start, .end = self.pos };
        }
      }
      // adverb_val: \ as noun value
      self.adv();
      self.setNoun();
      return .{ .tt = .adverb_val, .start = start, .end = self.pos };
    }

    // / as adverb (immediate after noun or verb, no space)
    if (c == '/' and (self.after_noun or self.after_verb) and !had_space) {
      self.adv();
      if (self.ch() == ':') self.adv();
      self.setVerb();
      return .{ .tt = .adverb, .start = start, .end = self.pos };
    }

    // Special bracket sequences
    if (c == '$' and self.ch1() == '[') {
      self.pos += 2;
      self.setNeither();
      return .{ .tt = .@"$[", .start = start, .end = self.pos };
    }
    if (c == '[' and self.ch1() == '[' and self.ch2() == ']') {
      self.pos += 3;
      self.setNeither();
      return .{ .tt = .@"[[]", .start = start, .end = self.pos };
    }
    if (c == '[' and self.ch1() == '[') {
      self.pos += 2;
      self.setNeither();
      return .{ .tt = .@"[[", .start = start, .end = self.pos };
    }

    // Simple delimiters
    if (c == '(') { self.adv(); self.setNeither(); return .{ .tt = .@"(", .start = start, .end = self.pos }; }
    if (c == ')') { self.adv(); self.setNoun();    return .{ .tt = .@")", .start = start, .end = self.pos }; }
    if (c == '{') { self.adv(); self.setNeither(); return .{ .tt = .@"{", .start = start, .end = self.pos }; }
    if (c == '}') { self.adv(); self.setNoun();    return .{ .tt = .@"}", .start = start, .end = self.pos }; }
    if (c == '[') { self.adv(); self.setNeither(); return .{ .tt = .@"[", .start = start, .end = self.pos }; }
    if (c == ']') { self.adv(); self.setNoun();    return .{ .tt = .@"]", .start = start, .end = self.pos }; }

    // Colon (check for verb_io first: digit handled below)
    if (c == ':') {
      self.adv();
      self.setNeither();
      return .{ .tt = .@":", .start = start, .end = self.pos };
    }

    // String literal "..."
    // A '"' inside a string closes it only when the *next* char is a "close char"
    // (whitespace, bracket, op, digit, etc.) — this is the K string-doubling convention.
    // Example: """ is a 1-char string containing '"'.
    if (c == '"') {
      self.adv(); // skip opening "
      while (self.pos < self.src.len) {
        const sc = self.src[self.pos];
        if (sc == '\n') break; // unclosed string
        if (sc == '\\') {
          self.adv();
          if (self.pos < self.src.len) self.adv();
        } else if (sc == '"') {
          const next_c: u8 = if (self.pos + 1 < self.src.len) self.src[self.pos + 1] else 0;
          if (isStringCloseChar(next_c)) {
            self.adv(); // consume closing "
            break;
          } else {
            self.adv(); // " is content
          }
        } else {
          self.adv();
        }
      }
      self.setNoun();
      return .{ .tt = .string, .start = start, .end = self.pos };
    }

    // Symbol: `body
    if (c == '`') {
      self.adv();
      if (self.pos < self.src.len and self.src[self.pos] == '"') {
        // quoted symbol: `"content"
        self.adv();
        while (self.pos < self.src.len and self.src[self.pos] != '"') self.adv();
        if (self.pos < self.src.len) self.adv();
      } else {
        // unquoted symbol: `abc, `123, `+, etc.
        // Symbol body uses iden = /[a-zA-Z][a-zA-Z\d]*/ — no underscores.
        const sym_ops = "%!&+*|<>=~,^#_$?@/-";
        while (self.pos < self.src.len) {
          const sc = self.src[self.pos];
          if (std.ascii.isAlphanumeric(sc) or sc == '.') {
            self.adv();
          } else if (std.mem.indexOfScalar(u8, sym_ops, sc) != null and
            self.pos == start + 1)
          {
            // single-char op symbol: `+, `-, etc. (only at start)
            self.adv();
            break;
          } else {
            break;
          }
        }
      }
      self.setNoun();
      return .{ .tt = .symbol, .start = start, .end = self.pos };
    }

    // Leading-dot float: .3  .14  etc. (before op check consumes '.')
    if (c == '.' and self.ch1() != null and std.ascii.isDigit(self.ch1().?)) {
      return self.lexNumber(start);
    }

    // Numbers: digit or minus-then-digit (only when next char is numeric)
    if (std.ascii.isDigit(c)) {
      return self.lexNumber(start);
    }
    if (c == '-' and !self.after_noun) {
      const n = self.ch1();
      if (n != null and (std.ascii.isDigit(n.?) or n.? == '.')) {
        return self.lexNumber(start);
      }
    }

    // Minus as operator (after noun, or when not followed by digit)
    if (c == '-') {
      self.adv();
      self.setVerb();
      return .{ .tt = .op, .start = start, .end = self.pos };
    }

    // Identifiers: must start with a letter (grammar: var = /[a-zA-Z][a-zA-Z\d]*/)
    // '_' is always an op, never a var start.
    if (std.ascii.isAlphabetic(c)) {
      while (self.pos < self.src.len and
        std.ascii.isAlphanumeric(self.src[self.pos]))
      {
        self.adv();
      }
      const word = self.src[start..self.pos];
      if (isKeywordOp(word)) {
        self.setVerb();
        return .{ .tt = .keyword_op, .start = start, .end = self.pos };
      }
      self.setNoun();
      return .{ .tt = .var_, .start = start, .end = self.pos };
    }

    // Single-char ops: %!&+*|<>=~,^#_$?@./  (note: _ is here, not in idents)
    const single_ops = "%!&+*|<>=~,^#_$?@./";
    if (std.mem.indexOfScalar(u8, single_ops, c) != null) {
      self.adv();
      // Check for adverb immediately following (e.g. +/)
      // The adverb will be picked up on the next call with after_verb=true
      self.setVerb();
      return .{ .tt = .op, .start = start, .end = self.pos };
    }

    // Unknown character — advance and return as eof-like
    self.adv();
    return .{ .tt = .eof, .start = start, .end = self.pos };
  }

  fn lexNumber(self: *Lexer, start: u32) Token {
    const c = self.src[self.pos];

    // Leading-dot float: .3 .14
    if (c == '.') {
      self.adv(); // consume '.'
      while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.adv();
      if (self.ch() == 'e' or self.ch() == 'E') {
        self.adv();
        if (self.ch() == '+' or self.ch() == '-') self.adv();
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.adv();
      }
      self.setNoun();
      return .{ .tt = .float, .start = start, .end = self.pos };
    }

    // Handle negative sign
    const has_minus = c == '-';
    if (has_minus) self.adv();

    // Special: 0N, 0W, 0n, 0w (null/infinity)
    if (self.ch() == '0') {
      const n = self.ch1();
      if (n == 'N' or n == 'W') {
        self.pos += 2;
        self.setNoun();
        return .{ .tt = .int, .start = start, .end = self.pos };
      }
      if (n == 'n' or n == 'w') {
        self.pos += 2;
        self.setNoun();
        return .{ .tt = .float, .start = start, .end = self.pos };
      }
      // hex: 0x...
      if (n == 'x' or n == 'X') {
        self.pos += 2;
        while (self.pos < self.src.len and
          std.ascii.isHex(self.src[self.pos]))
        {
          self.adv();
        }
        self.setNoun();
        return .{ .tt = .int, .start = start, .end = self.pos };
      }
    }

    // Scan digits
    const digits_start = self.pos;
    while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos]))
      self.adv();
    const n_digits = self.pos - digits_start;
    _ = n_digits;

    // Bool/bools: digits followed by 'b' where all digits are 0 or 1
    if (self.ch() == 'b' and !has_minus) {
      const digit_slice = self.src[digits_start..self.pos];
      var all_binary = true;
      for (digit_slice) |dc| {
        if (dc != '0' and dc != '1') { all_binary = false; break; }
      }
      if (all_binary and digit_slice.len > 0) {
        self.adv(); // consume 'b'
        self.setNoun();
        if (digit_slice.len == 1) {
          return .{ .tt = .bit, .start = start, .end = self.pos };
        } else {
          return .{ .tt = .bits, .start = start, .end = self.pos };
        }
      }
    }

    // verb_io: single digit followed by ':'  (only if no minus)
    if (!has_minus and self.ch() == ':') {
      const dlen = self.pos - digits_start;
      if (dlen == 1) {
        self.adv(); // consume ':'
        self.setVerb();
        return .{ .tt = .verb_io, .start = start, .end = self.pos };
      }
    }

    // Float: digits.digits or digits. (trailing dot)
    // Consume dot when next char is a digit, or when it's not alphanumeric/bracket
    // (so `2.3` and `2.` are floats but `2.[` and `2.a` keep the dot as a separate op).
    if (self.ch() == '.') {
      const after_dot = self.ch1() orelse 0;
      if (std.ascii.isDigit(after_dot) or
          (!std.ascii.isAlphanumeric(after_dot) and after_dot != '['))
      {
        self.adv(); // consume '.'
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.adv();
        if (self.ch() == 'e' or self.ch() == 'E') {
          self.adv();
          if (self.ch() == '+' or self.ch() == '-') self.adv();
          while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.adv();
        }
        self.setNoun();
        return .{ .tt = .float, .start = start, .end = self.pos };
      }
    }

    // Scientific notation for floats starting as integers
    if (self.ch() == 'e' or self.ch() == 'E') {
      self.adv();
      if (self.ch() == '+' or self.ch() == '-') self.adv();
      while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.adv();
      self.setNoun();
      return .{ .tt = .float, .start = start, .end = self.pos };
    }

    // Plain integer
    self.setNoun();
    return .{ .tt = .int, .start = start, .end = self.pos };
  }

  // Peek at the next token without advancing state.
  pub fn peekNext(self: *Lexer) Token {
    const saved_pos = self.pos;
    const saved_an = self.after_noun;
    const saved_av = self.after_verb;
    const tok = self.next();
    self.pos = saved_pos;
    self.after_noun = saved_an;
    self.after_verb = saved_av;
    return tok;
  }
};

test "lexer basics" {
  const src = "1 2 3";
  var lex = Lexer.init(src);
  const t1 = lex.next();
  try std.testing.expectEqual(TT.int, t1.tt);
  try std.testing.expectEqualStrings("1", t1.slice(src));
  const t2 = lex.next();
  try std.testing.expectEqual(TT.int, t2.tt);
  const t3 = lex.next();
  try std.testing.expectEqual(TT.int, t3.tt);
  const t4 = lex.next();
  try std.testing.expectEqual(TT.eof, t4.tt);
}

test "lexer adverb" {
  const src = "+/";
  var lex = Lexer.init(src);
  const t1 = lex.next();
  try std.testing.expectEqual(TT.op, t1.tt);
  const t2 = lex.next();
  try std.testing.expectEqual(TT.adverb, t2.tt);
  try std.testing.expectEqualStrings("/", t2.slice(src));
}

test "lexer comment" {
  const src = "/ comment\n1";
  var lex = Lexer.init(src);
  const t1 = lex.next();
  try std.testing.expectEqual(TT.comment, t1.tt);
  const t2 = lex.next();
  try std.testing.expectEqual(TT.sep, t2.tt);
  const t3 = lex.next();
  try std.testing.expectEqual(TT.int, t3.tt);
}

test "lexer inline comment" {
  const src = "+/!3 /inline";
  var lex = Lexer.init(src);
  try std.testing.expectEqual(TT.op,     lex.next().tt); // +
  try std.testing.expectEqual(TT.adverb, lex.next().tt); // / (immediate)
  try std.testing.expectEqual(TT.op,     lex.next().tt); // !
  try std.testing.expectEqual(TT.int,    lex.next().tt); // 3
  try std.testing.expectEqual(TT.comment,lex.next().tt); // /inline (after space)
}

test "lexer symbol" {
  const src = "`abc";
  var lex = Lexer.init(src);
  const t = lex.next();
  try std.testing.expectEqual(TT.symbol, t.tt);
  try std.testing.expectEqualStrings("`abc", t.slice(src));
}

test "lexer bool" {
  const src = "0b 1b 0110b";
  var lex = Lexer.init(src);
  try std.testing.expectEqual(TT.bit,  lex.next().tt);
  try std.testing.expectEqual(TT.bit,  lex.next().tt);
  try std.testing.expectEqual(TT.bits, lex.next().tt);
}
