const std = @import("std");
const isAlphabetic = std.ascii.isAlphabetic;
const isAlphanumeric = std.ascii.isAlphanumeric;
const isDigit = std.ascii.isDigit;

pub const TT = enum {
  int, float, bit, bits, nat, dbl, hlf,
  string, symbol, iden,
  keyword, op, io,
  adverb, adverb_val,
  @":",
  @"(", @")",
  @"{", @"}",
  @"[", @"]",
  @"$[",
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

// Grammar keyword verbs — only the genuinely-DYADIC ones remain. The math functions
// (sqrt sqr exp log sin cos abs) and the monadic verbs with no glyph form (first last
// count parse exec depth epoch) were removed from the grammar: any monadic primitive
// is now callable as a symbol (`` `first x ``, `` `parse x `` → its Op1 kernel via
// syms.zig / the compiler peephole), and lib/prelude.k binds friendly names to those
// (loaded at VM init). Their Op1 enum members + kernels are kept. See doc/design/dye.md.
const KEYWORD_OPS = [_][]const u8{
  "in", "has", "mod", "div",
};

fn isKeywordOp(s: []const u8) bool {
  for (KEYWORD_OPS) |kw| {
    if (std.mem.eql(u8, s, kw)) return true;
  }
  return false;
}

// Part of speech can be a prase, noun, or a verb
const Tag = enum { phrase, noun, verb };

// True if the line directly above the '/' at `open` is itself a line comment
// (its first non-blank character is '/'). Such a '/' is a blank divider inside a
// run of comments, not a block-comment opener — this keeps a lone '/' among
// line comments from accidentally pairing with a later lone '\'.
fn prevLineIsComment(src: []const u8, open: u32) bool {
  if (open == 0 or src[open - 1] != '\n') return false; // BOF or not at line start
  var b = open - 1; // the '\n' ending the previous line
  while (b > 0 and src[b - 1] != '\n') b -= 1; // start of the previous line
  var i = b;
  while (i < open - 1 and (src[i] == ' ' or src[i] == '\t')) i += 1;
  return i < open - 1 and src[i] == '/';
}

// True if a block-comment terminator — a line consisting solely of '\' in
// column 0 — exists after the opening '/' at `open`. Scans line by line from
// the line following `open`.
fn blockClosePresent(src: []const u8, open: u32) bool {
  var i = open;
  while (i < src.len and src[i] != '\n') i += 1; // end of the opening '/' line
  while (i < src.len) {
    i += 1; // step past '\n' -> column 0 of next line
    if (i < src.len and src[i] == '\\' and (i + 1 >= src.len or src[i + 1] == '\n'))
      return true;
    while (i < src.len and src[i] != '\n') i += 1;
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
  i: u32 = 0,
  tag: Tag = .phrase,
  // True when the last string token returned was a multi-line string that ran
  // to EOF without a closing quote. Used by endsOpenString for REPL continuation.
  last_string_open: bool = false,

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
      // Block comment: a line consisting of exactly '/' opens a block that runs
      // until a line consisting of exactly '\'. Both delimiters must sit in
      // column 0 and be alone on their line. A lone '/' is NOT a block opener
      // (it stays an ordinary empty line comment) when either the line above it
      // is itself a comment — the blank '/' divider idiom inside a run of
      // comments — or no matching '\' close follows.
      const at_col0 = (start == 0 or self.src[start - 1] == '\n');
      const slash_alone = (start + 1 >= self.src.len or self.src[start + 1] == '\n');
      if (at_col0 and slash_alone and
        !prevLineIsComment(self.src, start) and blockClosePresent(self.src, start)) {
        self.adv(); // consume '/'
        while (self.i < self.src.len and self.CR() != '\n') self.adv();
        while (self.i < self.src.len) {
          self.adv(); // consume '\n' -> now at column 0 of next line
          const ls = self.i;
          const term = (ls < self.src.len and self.src[ls] == '\\') and
            (ls + 1 >= self.src.len or self.src[ls + 1] == '\n');
          while (self.i < self.src.len and self.CR() != '\n') self.adv();
          if (term) break;
        }
        self.tag = .phrase;
        return .{ .tt = .comment, .start = start, .end = self.i };
      }
      while (self.i < self.src.len and self.CR() != '\n')
        self.adv();
      self.tag = .phrase;
      return .{ .tt = .comment, .start = start, .end = self.i };
    }

    // Adverb or adverb_val for '
    // Spacing does NOT participate: `f ' x` means the same as `f'x`. What decides is
    // solely what is to the LEFT — after a noun or a verb this is the adverb (the
    // parser then picks scan-vs-dyadic-verb from that operand), and only at phrase
    // start is it the bare adverb VALUE. Letting a space flip it silently turned
    // `sep \ str` into a scan and `f ' xs` into an error. NB `/` cannot join this
    // rule: a spaced `/` is a COMMENT (see above), which is why it still tests
    // had_space.
    if (c == '\'') {
      if (self.tag != .phrase) {
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
      // Adverb \: or \ takes priority after a noun or verb, spaced or not (see the
      // note on `'`). Commands (`\d`, `\l`, …) are unaffected: they only ever start a
      // phrase, and a newline/`;`/`:` resets tag to .phrase.
      if (self.tag != .phrase) {
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
      // Multi-line string: a '"' immediately followed by a newline opens a
      // string that spans newlines (single-line strings still break at '\n').
      // Dedent happens later in compileLiteral.
      const multiline = self.i < self.src.len and self.CR() == '\n';
      var closed = false;
      while (self.i < self.src.len) {
        const sc = self.CR();
        if (sc == '\n' and !multiline) break; // unclosed single-line string
        if (sc == '\\') {
          self.adv();
          if (self.i < self.src.len) self.adv();
        } else if (sc == '"') {
          const next_c: u8 = if (self.i + 1 < self.src.len) self.src[self.i + 1] else 0;
          if (isStringCloseChar(next_c)) {
            self.adv(); // consume closing "
            closed = true;
            break;
          } else {
            self.adv(); // " is content
          }
        } else {
          self.adv();
        }
      }
      // A multi-line string that hit EOF without closing keeps the REPL reading.
      self.last_string_open = multiline and !closed;
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
      } else if (self.i + 1 < self.src.len and isDigit(self.CR()) and self.src[self.i + 1] == ':') {
        // `0:/`1:/`2:… — a blank symbol immediately followed by an IO verb, NOT a
        // digit-named symbol. Consume nothing; the `<digit>:` lexes next as an io
        // verb, so `` `0:"hi" `` is (blank) 0: "hi" (write "hi" to stdout), matching
        // the spaced `` ` 0:"hi" `` and the `` `0 0:"hi" `` handle forms.
      } else {
        // unquoted symbol: `abc, `a1, `a.b — alphanumerics and dots only.
        // An operator glyph directly after the backtick does NOT join the symbol:
        // `~ is the null symbol ` followed by the Match verb ~ (so `~` is a Match of
        // two null symbols, and `~ is a match projection), matching ngn/k. To name a
        // symbol after an operator, quote it: `"+", `"<=".
        while (self.i < self.src.len) {
          const sc = self.CR();
          if (isAlphanumeric(sc) or sc == '.') self.adv() else break;
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
    if (c == '-') {
      const n = self.ch(1);
      const num_follows = n != null and (isDigit(n.?) or n.? == '.');
      // A '-' glued to a following number is a negative literal unless it sits
      // directly after a noun with no space — then it is dyadic subtract. So
      // `a-3` subtracts but `a -3` juxtaposes a and -3 (e.g. `abs -3` applies
      // abs to -3), matching ngn/k where `cos-3` errors but `cos -3` works.
      if (num_follows and (self.tag != .noun or had_space)) {
        return self.lexNumber(start);
      }
    }

    // Minus as operator (after noun, or when not followed by digit)
    if (c == '-') {
      self.adv();
      self.tag = .verb;
      return .{ .tt = .op, .start = start, .end = self.i };
    }

    // Identifiers: must start with a letter (grammar:
    //   var = /[a-zA-Z][a-zA-Z\d]*(\.[a-zA-Z][a-zA-Z\d]*)*/ )
    // '_' is always an op, never a var character.
    // A '.' extends the name only when immediately followed by a letter, so
    // `a.b` and `ab1.ed4` are single names while `a.1` and `a. b` keep '.' as
    // the dot (index/apply) operator.
    if (isAlphabetic(c)) {
      while (self.i < self.src.len and isAlphanumeric(self.CR())) {
        self.adv();
      }
      while (self.ch(0) == '.') {
        const nxt = self.ch(1) orelse break;
        if (!isAlphabetic(nxt)) break;
        self.adv(); // consume '.'
        while (self.i < self.src.len and isAlphanumeric(self.CR())) self.adv();
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

  // Consume a Tier-2 float precision suffix (d=f64, h=f16) when present and not
  // glued to a longer identifier (`2.3d` → f64, but `2.3dx` keeps `d` for a
  // following name). Returns the resulting token type, else `base`.
  fn floatSuffix(self: *Lexer, base: TT) TT {
    const s = self.ch(0) orelse return base;
    if (s != 'd' and s != 'h') return base;
    const nxt = self.ch(1);
    if (nxt != null and (isAlphanumeric(nxt.?) or nxt.? == '.')) return base;
    self.adv();
    return if (s == 'd') .dbl else .hlf;
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
      return .{ .tt = self.floatSuffix(.float), .start = start, .end = self.i };
    }

    // Handle negative sign
    const has_minus = c == '-';
    if (has_minus) self.adv();

    // Special: 0N, 0W, 0n, 0w (null/infinity) — with optional Tier-2 suffix
    // (`0Nu` natural null, `0nd`/`0wd` f64 null/inf, `0nh`/`0wh` f16).
    if (self.ch(0) == '0') {
      const n = self.ch(1);
      if (n == 'N' or n == 'W') {
        self.i += 2;
        self.tag = .noun;
        if (!has_minus and self.ch(0) == 'u') { self.adv(); return .{ .tt = .nat, .start = start, .end = self.i }; }
        return .{ .tt = .int, .start = start, .end = self.i };
      }
      if (n == 'n' or n == 'w') {
        self.i += 2;
        self.tag = .noun;
        return .{ .tt = self.floatSuffix(.float), .start = start, .end = self.i };
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

    // Natural (u32): digits followed by 'u' — a Tier-2 explicit-precision type.
    // Unsigned, so never after a minus. `3u` is the natural 3.
    if (self.ch(0) == 'u' and !has_minus and self.i > digits_start) {
      self.adv(); // consume 'u'
      self.tag = .noun;
      return .{ .tt = .nat, .start = start, .end = self.i };
    }

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
        return .{ .tt = self.floatSuffix(.float), .start = start, .end = self.i };
      }
    }

    // Scientific notation for floats starting as integers
    if (self.ch(0) == 'e' or self.ch(0) == 'E') {
      self.adv();
      if (self.ch(0) == '+' or self.ch(0) == '-') self.adv();
      while (self.i < self.src.len and isDigit(self.CR())) self.adv();
      self.tag = .noun;
      return .{ .tt = self.floatSuffix(.float), .start = start, .end = self.i };
    }

    // Plain integer — or an integer-mantissa float precision literal (`2d` `2h`).
    self.tag = .noun;
    return .{ .tt = self.floatSuffix(.int), .start = start, .end = self.i };
  }

  // Peek at the next token without advancing state.
  pub fn peekNext(self: *Lexer) Token {
    const saved_pos = self.i;
    const saved_tag = self.tag;
    const saved_open = self.last_string_open;
    const tok = self.next();
    self.i = saved_pos;
    self.tag = saved_tag;
    self.last_string_open = saved_open;
    return tok;
  }

  // Returns true if `src` ends inside an unterminated multi-line string, i.e.
  // the REPL should keep reading more lines before evaluating. An open string
  // always runs to EOF, so it is necessarily the last token before .eof.
  pub fn endsOpenString(src: []const u8) bool {
    var lex = Lexer.init(src);
    while (true) {
      const tok = lex.next();
      if (tok.tt == .eof) return false;
      if (tok.tt == .string and lex.last_string_open) return true;
    }
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

test "lexer block comment" {
  const src = "/\nignored 1 2 3\nstill \"ignored\n\\\n1";
  var lex = Lexer.init(src);
  const t1 = lex.next();
  try std.testing.expectEqual(TT.comment, t1.tt);
  try std.testing.expectEqualStrings("/\nignored 1 2 3\nstill \"ignored\n\\", t1.slice(src));
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  try std.testing.expectEqual(TT.int, lex.next().tt);
}

test "lexer unterminated block is a line comment" {
  // A lone '/' with no matching '\' close is just an empty line comment; the
  // following lines are ordinary code, not swallowed to EOF.
  const src = "1\n/\n2+2";
  var lex = Lexer.init(src);
  try std.testing.expectEqual(TT.int, lex.next().tt);
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  const t = lex.next();
  try std.testing.expectEqual(TT.comment, t.tt);
  try std.testing.expectEqualStrings("/", t.slice(src));
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  try std.testing.expectEqual(TT.int, lex.next().tt); // 2
  try std.testing.expectEqual(TT.op, lex.next().tt);  // +
  try std.testing.expectEqual(TT.int, lex.next().tt); // 2
}

test "lexer divider slash inside comment run" {
  // The blank '/' divider between line comments must NOT open a block comment.
  const src = "/ heading\n/\n/ more\n5";
  var lex = Lexer.init(src);
  try std.testing.expectEqual(TT.comment, lex.next().tt); // / heading
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  const div = lex.next();
  try std.testing.expectEqual(TT.comment, div.tt);       // /  (divider)
  try std.testing.expectEqualStrings("/", div.slice(src));
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  try std.testing.expectEqual(TT.comment, lex.next().tt); // / more
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  try std.testing.expectEqual(TT.int, lex.next().tt);     // 5
}

test "lexer slash not block when not alone" {
  // '/foo' at column 0 is a normal single-line comment, not a block opener.
  const src = "/foo\n1";
  var lex = Lexer.init(src);
  const t1 = lex.next();
  try std.testing.expectEqual(TT.comment, t1.tt);
  try std.testing.expectEqualStrings("/foo", t1.slice(src));
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  try std.testing.expectEqual(TT.int, lex.next().tt);
}

test "lexer divider not swallowed by later backslash" {
  // The '/' on line 2 is a divider inside a comment run; it must NOT open a
  // block comment just because a lone '\' appears later (line 5). `val` stays
  // real code.
  const src = "/ head\n/\n/ more\nval:5\n/\nblk\n\\\nval";
  var lex = Lexer.init(src);
  try std.testing.expectEqual(TT.comment, lex.next().tt); // / head
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  const div = lex.next();
  try std.testing.expectEqual(TT.comment, div.tt);        // /  (divider, not block)
  try std.testing.expectEqualStrings("/", div.slice(src));
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  try std.testing.expectEqual(TT.comment, lex.next().tt); // / more
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  try std.testing.expectEqual(TT.iden, lex.next().tt);    // val
  try std.testing.expectEqual(TT.@":", lex.next().tt);    // :
  try std.testing.expectEqual(TT.int, lex.next().tt);     // 5
  try std.testing.expectEqual(TT.sep, lex.next().tt);
  // line 5 '/' — prev line is code, close follows -> genuine block comment
  const blk = lex.next();
  try std.testing.expectEqual(TT.comment, blk.tt);
  try std.testing.expectEqualStrings("/\nblk\n\\", blk.slice(src));
}

test "a mid-expression backslash does not eat the rest of the line" {
  // Triage 22: `\\` and `||:\` used to leave the lexer looking at a command
  // (`\letter…`), which runs to end of line — so loading lib/color.k silently
  // swallowed everything after them, with no output and no error. After a noun
  // or a verb a `\` is an ADVERB, whatever follows it.
  const cases = [_][]const u8{ "a:1+\\\\~b\nval", "a:,/||:\\!3\nval" };
  for (cases) |src| {
    var lex = Lexer.init(src);
    var saw_sep = false;
    while (true) {
      const t = lex.next();
      if (t.tt == .eof) break;
      if (t.tt == .sep) saw_sep = true;
      // Nothing on the first line may be lexed as a command…
      try std.testing.expect(t.tt != .command);
    }
    // …and the newline plus the code after it must still be there.
    try std.testing.expect(saw_sep);
  }
}

test "lexer symbol" {
  const src = "`abc";
  var lex = Lexer.init(src);
  const t = lex.next();
  try std.testing.expectEqual(TT.symbol, t.tt);
  try std.testing.expectEqualStrings("`abc", t.slice(src));
}

test "lexer symbol stops before op glyph" {
  // `~ is the null symbol ` then the Match verb ~ (dropped op-glyph symbols).
  const src = "`~`";
  var lex = Lexer.init(src);
  const t1 = lex.next();
  try std.testing.expectEqual(TT.symbol, t1.tt);
  try std.testing.expectEqualStrings("`", t1.slice(src)); // empty symbol body
  const t2 = lex.next();
  try std.testing.expectEqual(TT.op, t2.tt);
  try std.testing.expectEqualStrings("~", t2.slice(src));
  const t3 = lex.next();
  try std.testing.expectEqual(TT.symbol, t3.tt);
  try std.testing.expectEqualStrings("`", t3.slice(src));
}

test "lexer minus juxtaposition vs subtract" {
  // `abs -3` → iden then negative int (juxtapose/apply);
  // `abs-3`  → iden, op '-', int 3 (subtract).
  {
    const src = "abs -3";
    var lex = Lexer.init(src);
    try std.testing.expectEqual(TT.iden, lex.next().tt);
    const t = lex.next();
    try std.testing.expectEqual(TT.int, t.tt);
    try std.testing.expectEqualStrings("-3", t.slice(src));
  }
  {
    const src = "abs-3";
    var lex = Lexer.init(src);
    try std.testing.expectEqual(TT.iden, lex.next().tt);
    try std.testing.expectEqual(TT.op, lex.next().tt);
    try std.testing.expectEqual(TT.int, lex.next().tt);
  }
}

test "endsOpenString" {
  const expectEqual = std.testing.expectEqual;
  // Open: opening quote then a newline, no close yet (REPL keeps reading).
  try expectEqual(true, Lexer.endsOpenString("a:\"\n"));
  try expectEqual(true, Lexer.endsOpenString("a:\"\n  Hello,\n"));
  // Closed multi-line string — quote on content line or on its own line.
  try expectEqual(false, Lexer.endsOpenString("a:\"\n  Hello!\"\n"));
  try expectEqual(false, Lexer.endsOpenString("a:\"\n  Hello!\n\"\n"));
  // Single-line strings never trigger continuation (closed or not).
  try expectEqual(false, Lexer.endsOpenString("\"abc\"\n"));
  try expectEqual(false, Lexer.endsOpenString("\"abc\n"));
  // A trailing escaped quote inside an open string does not look closed.
  try expectEqual(true, Lexer.endsOpenString("\"\n  he said \\\"\n"));
  // A quote in a comment must not be mistaken for a string opener.
  try expectEqual(false, Lexer.endsOpenString("1 / a \" comment\n"));
}

test "lexer bool" {
  const src = "0b 1b 0110b";
  var lex = Lexer.init(src);
  try std.testing.expectEqual(TT.bit,  lex.next().tt);
  try std.testing.expectEqual(TT.bit,  lex.next().tt);
  try std.testing.expectEqual(TT.bits, lex.next().tt);
}
