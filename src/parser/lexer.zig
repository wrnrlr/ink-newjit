const std = @import("std");
const isAlphabetic = std.ascii.isAlphabetic;
const isAlphanumeric = std.ascii.isAlphanumeric;
const isDigit = std.ascii.isDigit;

pub const TT = enum {
  int, float,
  bit, bits,
  string, symbol,
  iden,
  keyword, op, io,
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
  "parse", "exec",
};

fn isKeywordOp(s: []const u8) bool {
  for (KEYWORD_OPS) |kw| {
    if (std.mem.eql(u8, s, kw)) return true;
  }
  return false;
}

// Part of speech can be a prase, noun, or a verb
const Tag = enum { phrase, noun, verb };

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
  i: u32 = 0,
  tag: Tag = .phrase,

  pub fn init(src: []const u8) Lexer { return .{ .src = src }; }

  fn ch(self: *Lexer, i:comptime_int) ?u8 {
    if (self.i + i >= self.src.len) return null;
    return self.src[self.i + i];
  }

  fn adv(self: *Lexer) void { if (self.i < self.src.len) self.i += 1; }

  inline fn CR(self: *Lexer) u8 { return self.src[self.i]; }

  // Returns true if whitespace (spaces/tabs only, not newlines) was skipped.
  fn skipSpace(self: *Lexer) bool {
    const start = self.i;
    while (self.i < self.src.len and (self.CR() == ' ' or self.CR() == '\t'))
      self.i += 1;
    return self.i > start;
  }

  pub fn next(self: *Lexer) Token {
    const had_space = self.skipSpace();
    if (self.i >= self.src.len) {
      return .{ .tt = .eof, .start = self.i, .end = self.i };
    }
    const start = self.i;
    const c = self.CR();

    // Newline -> sep
    if (c == '\n') {
      self.adv();
      self.tag = .phrase;
      return .{ .tt = .sep, .start = start, .end = self.i };
    }

    // Semicolon -> sep
    if (c == ';') {
      self.adv();
      self.tag = .phrase;
      return .{ .tt = .sep, .start = start, .end = self.i };
    }

    // Comment: / with whitespace before it (or at start / after sep)
    if (c == '/' and (had_space or self.tag == .phrase)) {
      while (self.i < self.src.len and self.CR() != '\n')
        self.adv();
      self.tag = .phrase;
      return .{ .tt = .comment, .start = start, .end = self.i };
    }

    // Adverb or adverb_val for '
    if (c == '\'') {
      if ((self.tag == .phrase) and !had_space) {
        self.adv();
        if (self.ch(0) == ':') self.adv();
        self.tag = .verb;
        return .{ .tt = .adverb, .start = start, .end = self.i };
      }
      // adverb_val: ' as noun value (inside group etc.)
      self.adv();
      self.tag = .noun;
      return .{ .tt = .adverb_val, .start = start, .end = self.i };
    }

    // Backslash
    if (c == '\\') {
      // Adverb \: or \ takes priority when immediately after a noun or verb
      if ((self.tag != .phrase) and !had_space) {
        self.adv();
        if (self.ch(0) == ':') self.adv();
        self.tag = .verb;
        return .{ .tt = .adverb, .start = start, .end = self.i };
      }
      // Command: \letter... (only at start of expression, not after noun/verb)
      if (self.ch(1)) |n| {
        if (isAlphabetic(n)) {
          self.adv(); // skip '\'
          while (self.i < self.src.len and self.CR() != '\n')
            self.adv();
          self.tag = .phrase;
          return .{ .tt = .command, .start = start, .end = self.i };
        }
      }
      // adverb_val: \ as noun value
      self.adv();
      self.tag = .noun;
      return .{ .tt = .adverb_val, .start = start, .end = self.i };
    }

    // / as adverb (immediate after noun or verb, no space)
    if (c == '/' and (self.tag != .phrase) and !had_space) {
      self.adv();
      if (self.ch(0) == ':') self.adv();
      self.tag = .verb;
      return .{ .tt = .adverb, .start = start, .end = self.i };
    }

    // Special bracket sequences
    if (c == '$' and self.ch(1) == '[') {
      self.i += 2;
      self.tag = .phrase;
      return .{ .tt = .@"$[", .start = start, .end = self.i };
    }
    if (c == '[' and self.ch(1) == '[' and self.ch(2) == ']') {
      self.i += 3;
      self.tag = .phrase;
      return .{ .tt = .@"[[]", .start = start, .end = self.i };
    }
    if (c == '[' and self.ch(1) == '[') {
      self.i += 2;
      self.tag = .phrase;
      return .{ .tt = .@"[[", .start = start, .end = self.i };
    }

    // Simple delimiters
    if (c == '(') { self.adv(); self.tag = .phrase; return .{ .tt = .@"(", .start = start, .end = self.i }; }
    if (c == ')') { self.adv(); self.tag = .noun;   return .{ .tt = .@")", .start = start, .end = self.i }; }
    if (c == '{') { self.adv(); self.tag = .phrase; return .{ .tt = .@"{", .start = start, .end = self.i }; }
    if (c == '}') { self.adv(); self.tag = .noun;   return .{ .tt = .@"}", .start = start, .end = self.i }; }
    if (c == '[') { self.adv(); self.tag = .phrase; return .{ .tt = .@"[", .start = start, .end = self.i }; }
    if (c == ']') { self.adv(); self.tag = .noun;   return .{ .tt = .@"]", .start = start, .end = self.i }; }

    // Colon (check for verb_io first: digit handled below)
    if (c == ':') {
      self.adv();
      self.tag = .phrase;
      return .{ .tt = .@":", .start = start, .end = self.i };
    }

    // String literal "..."
    // A '"' inside a string closes it only when the *next* char is a "close char"
    // (whitespace, bracket, op, digit, etc.) — this is the K string-doubling convention.
    // Example: """ is a 1-char string containing '"'.
    if (c == '"') {
      self.adv(); // skip opening "
      while (self.i < self.src.len) {
        const sc = self.CR();
        if (sc == '\n') break; // unclosed string
        if (sc == '\\') {
          self.adv();
          if (self.i < self.src.len) self.adv();
        } else if (sc == '"') {
          const next_c: u8 = if (self.i + 1 < self.src.len) self.src[self.i + 1] else 0;
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
      self.tag = .noun;
      return .{ .tt = .string, .start = start, .end = self.i };
    }

    // Symbol: `body
    if (c == '`') {
      self.adv();
      if (self.i < self.src.len and self.CR() == '"') {
        // quoted symbol: `"content"
        self.adv();
        while (self.i < self.src.len and self.CR() != '"') self.adv();
        if (self.i < self.src.len) self.adv();
      } else {
        // unquoted symbol: `abc, `123, `+, etc.
        // Symbol body uses iden = /[a-zA-Z][a-zA-Z\d]*/ — no underscores.
        const sym_ops = "%!&+*|<>=~,^#_$?@/-";
        while (self.i < self.src.len) {
          const sc = self.CR();
          if (isAlphanumeric(sc) or sc == '.') {
            self.adv();
          } else if (std.mem.indexOfScalar(u8, sym_ops, sc) != null and
            self.i == start + 1)
          {
            // single-char op symbol: `+, `-, etc. (only at start)
            self.adv();
            break;
          } else {
            break;
          }
        }
      }
      self.tag = .noun;
      return .{ .tt = .symbol, .start = start, .end = self.i };
    }

    // Leading-dot float: .3  .14  etc. (before op check consumes '.')
    if (c == '.' and self.ch(1) != null and isDigit(self.ch(1).?)) {
      return self.lexNumber(start);
    }

    // Numbers: digit or minus-then-digit (only when next char is numeric)
    if (isDigit(c)) return self.lexNumber(start);
    if (c == '-' and self.tag!=.noun) {
      const n = self.ch(1);
      if (n != null and (isDigit(n.?) or n.? == '.')) {
        return self.lexNumber(start);
      }
    }

    // Minus as operator (after noun, or when not followed by digit)
    if (c == '-') {
      self.adv();
      self.tag = .verb;
      return .{ .tt = .op, .start = start, .end = self.i };
    }

    // Identifiers: must start with a letter (grammar: var = /[a-zA-Z][a-zA-Z\d]*/)
    // '_' is always an op, never a var start.
    if (isAlphabetic(c)) {
      while (self.i < self.src.len and isAlphanumeric(self.CR())) {
        self.adv();
      }
      const word = self.src[start..self.i];
      if (isKeywordOp(word)) {
        self.tag = .verb;
        return .{ .tt = .keyword, .start = start, .end = self.i };
      }
      self.tag = .noun;
      return .{ .tt = .iden, .start = start, .end = self.i };
    }

    // Single-char ops: %!&+*|<>=~,^#_$?@./  (note: _ is here, not in idents)
    const single_ops = "%!&+*|<>=~,^#_$?@./";
    if (std.mem.indexOfScalar(u8, single_ops, c) != null) {
      self.adv();
      // Check for adverb immediately following (e.g. +/)
      // The adverb will be picked up on the next call with state after verb
      self.tag = .verb;
      return .{ .tt = .op, .start = start, .end = self.i };
    }

    // Unknown character — advance and return as eof-like
    self.adv();
    return .{ .tt = .eof, .start = start, .end = self.i };
  }

  fn lexNumber(self: *Lexer, start: u32) Token {
    const c = self.CR();

    // Leading-dot float: .3 .14
    if (c == '.') {
      self.adv(); // consume '.'
      while (self.i < self.src.len and isDigit(self.CR())) self.adv();
      if (self.ch(0) == 'e' or self.ch(0) == 'E') {
        self.adv();
        if (self.ch(0) == '+' or self.ch(0) == '-') self.adv();
        while (self.i < self.src.len and isDigit(self.CR())) self.adv();
      }
      self.tag = .noun;
      return .{ .tt = .float, .start = start, .end = self.i };
    }

    // Handle negative sign
    const has_minus = c == '-';
    if (has_minus) self.adv();

    // Special: 0N, 0W, 0n, 0w (null/infinity)
    if (self.ch(0) == '0') {
      const n = self.ch(1);
      if (n == 'N' or n == 'W') {
        self.i += 2;
        self.tag = .noun;
        return .{ .tt = .int, .start = start, .end = self.i };
      }
      if (n == 'n' or n == 'w') {
        self.i += 2;
        self.tag = .noun;
        return .{ .tt = .float, .start = start, .end = self.i };
      }
      // hex: 0x...
      if (n == 'x' or n == 'X') {
        self.i += 2;
        while (self.i < self.src.len and std.ascii.isHex(self.CR())) {
          self.adv();
        }
        self.tag = .noun;
        return .{ .tt = .int, .start = start, .end = self.i };
      }
    }

    // Scan digits
    const digits_start = self.i;
    while (self.i < self.src.len and isDigit(self.CR()))
      self.adv();
    const n_digits = self.i - digits_start;
    _ = n_digits;

    // Bool/bools: digits followed by 'b' where all digits are 0 or 1
    if (self.ch(0) == 'b' and !has_minus) {
      const digit_slice = self.src[digits_start..self.i];
      var all_binary = true;
      for (digit_slice) |dc| {
        if (dc != '0' and dc != '1') { all_binary = false; break; }
      }
      if (all_binary and digit_slice.len > 0) {
        self.adv(); // consume 'b'
        self.tag = .noun;
        const tt:TT = if (digit_slice.len == 1) .bit else .bits;
        return .{ .tt = tt, .start = start, .end = self.i };
      }
    }

    // verb_io: single digit followed by ':'  (only if no minus)
    if (!has_minus and self.ch(0) == ':') {
      const dlen = self.i - digits_start;
      if (dlen == 1) {
        self.adv(); // consume ':'
        self.tag = .verb;
        return .{ .tt = .io, .start = start, .end = self.i };
      }
    }

    // Float: digits.digits or digits. (trailing dot)
    // Consume dot when next char is a digit, or when it's not alphanumeric/bracket
    // (so `2.3` and `2.` are floats but `2.[` and `2.a` keep the dot as a separate op).
    if (self.ch(0) == '.') {
      const after_dot = self.ch(1) orelse 0;
      if (
        isDigit(after_dot) or
        (!isAlphanumeric(after_dot) and after_dot != '[')
      ) {
        self.adv(); // consume '.'
        while (self.i < self.src.len and isDigit(self.CR())) self.adv();
        if (self.ch(0) == 'e' or self.ch(0) == 'E') {
          self.adv();
          if (self.ch(0) == '+' or self.ch(0) == '-') self.adv();
          while (self.i < self.src.len and isDigit(self.CR())) self.adv();
        }
        self.tag = .noun;
        return .{ .tt = .float, .start = start, .end = self.i };
      }
    }

    // Scientific notation for floats starting as integers
    if (self.ch(0) == 'e' or self.ch(0) == 'E') {
      self.adv();
      if (self.ch(0) == '+' or self.ch(0) == '-') self.adv();
      while (self.i < self.src.len and isDigit(self.CR())) self.adv();
      self.tag = .noun;
      return .{ .tt = .float, .start = start, .end = self.i };
    }

    // Plain integer
    self.tag = .noun;
    return .{ .tt = .int, .start = start, .end = self.i };
  }

  // Peek at the next token without advancing state.
  pub fn peekNext(self: *Lexer) Token {
    const saved_pos = self.i;
    const saved_tag = self.tag;
    const tok = self.next();
    self.i = saved_pos;
    self.tag = saved_tag;
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
