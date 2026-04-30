#include "tree_sitter/parser.h"

enum TokenType { MINUS, BOOL, BOOLS, INTS, FLOATS, DATES, TIMES, SYMBOLS, STRING };

void *tree_sitter_terse_external_scanner_create() { return 0; }
void tree_sitter_terse_external_scanner_destroy(void *p) {}
unsigned tree_sitter_terse_external_scanner_serialize(void *payload, const char *buffer) { return 0; }
void tree_sitter_terse_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {}

static void adv(TSLexer *l) { l->advance(l, 0); }
static int dig(int c) { return c >= '0' && c <= '9'; }
static int xdig(int c) { return dig(c) || (c>='a'&&c<='f') || (c>='A'&&c<='F'); }

/* Returns 1 if c causes a '"' inside a string to close it.
   Close chars: whitespace, EOF, brackets, operators, semicolons, backtick.
   Non-close chars: '"' itself, letters, digits, backslash — these make '"' content. */
static int is_string_close_char(int c) {
  if (c == 0 || c == '\n' || c == '\t' || c == ' ' || c == ';') return 1;
  if (c == '(' || c == ')' || c == '[' || c == ']' || c == '{' || c == '}') return 1;
  if (c == '`') return 1;
  if (c >= '0' && c <= '9') return 1;
  const char *ops = "%!&+*|<>=~,^#_$?@./-:";
  for (const char *p = ops; *p; p++) if (c == (int)*p) return 1;
  return 0;
}

/* Scan a string starting at the opening '"' (already confirmed by caller).
   Doubling convention: '"' is content when followed by a non-close char.
   '"' closes the string when followed by a close char (or EOF).
   Backslash sequences advance 2 chars as raw content (no decoding).
   Newlines are allowed in string content. */
static int scan_string(TSLexer *l) {
  adv(l);  /* consume opening '"' */
  while (1) {
    if (l->lookahead == 0) break;  /* EOF closes */
    if (l->lookahead == '"') {
      adv(l);  /* consume '"' */
      if (is_string_close_char(l->lookahead)) break;  /* this '"' was the closer */
      /* lookahead is non-close: '"' was content, keep scanning */
    } else if (l->lookahead == '\\') {
      adv(l);  /* consume '\' */
      if (l->lookahead != 0) adv(l);  /* consume escaped char */
    } else {
      adv(l);  /* normal content char (including '\n') */
    }
  }
  l->mark_end(l);
  l->result_symbol = STRING;
  return 1;
}

/* After the initial digit(s) have been consumed, scan any remaining
   suffix to determine the number's type.
   Returns: 1=int, 2=float, 3=date, 4=time. */
static int finish_suffix(TSLexer *l) {
  while (dig(l->lookahead)) adv(l); /* any remaining digits */

  if (l->lookahead == '.') {
    adv(l);
    if (!dig(l->lookahead)) return 2; /* trailing dot "1." → float */
    while (dig(l->lookahead)) adv(l);
    if (l->lookahead == '.') { /* date: YYYY.MM.DD */
      adv(l);
      if (!dig(l->lookahead)) return 1; /* malformed; treat preceding as int */
      while (dig(l->lookahead)) adv(l);
      return 3;
    }
    if (l->lookahead == 'e' || l->lookahead == 'E') {
      adv(l);
      if (l->lookahead == '+' || l->lookahead == '-') adv(l);
      if (!dig(l->lookahead)) return 2;
      while (dig(l->lookahead)) adv(l);
    }
    return 2;
  }
  if (l->lookahead == ':') { /* time: HH:MM:SS(.frac)? */
    adv(l);
    if (!dig(l->lookahead)) return 1;
    while (dig(l->lookahead)) adv(l);
    if (l->lookahead != ':') return 1;
    adv(l);
    if (!dig(l->lookahead)) return 1;
    while (dig(l->lookahead)) adv(l);
    if (l->lookahead == '.') { adv(l); while (dig(l->lookahead)) adv(l); }
    return 4;
  }
  if (l->lookahead == 'e' || l->lookahead == 'E') {
    adv(l);
    if (l->lookahead == '+' || l->lookahead == '-') adv(l);
    if (!dig(l->lookahead)) return 2;
    while (dig(l->lookahead)) adv(l);
    return 2;
  }
  return 1;
}

/* Scan a complete number from scratch at the current position.
   Returns: 0=not a number, 1=int, 2=float, 3=date, 4=time. Advances lexer. */
static int scan_num(TSLexer *l) {
  int neg = (l->lookahead == '-');
  if (neg) adv(l);

  /* Leading dot: .123 → float */
  if (l->lookahead == '.') {
    adv(l);
    if (!dig(l->lookahead)) return 0;
    while (dig(l->lookahead)) adv(l);
    if (l->lookahead == 'e' || l->lookahead == 'E') {
      adv(l);
      if (l->lookahead == '+' || l->lookahead == '-') adv(l);
      if (!dig(l->lookahead)) return 0;
      while (dig(l->lookahead)) adv(l);
    }
    return 2;
  }

  if (!dig(l->lookahead)) return 0;

  /* '0'-prefixed special forms */
  if (l->lookahead == '0') {
    adv(l);
    if (l->lookahead == 'x' || l->lookahead == 'X') {
      adv(l);
      if (!xdig(l->lookahead)) return 0;
      while (xdig(l->lookahead)) adv(l);
      return 1;
    }
    if (l->lookahead == 'N' || l->lookahead == 'W') { adv(l); return 1; }
    if (l->lookahead == 'n' || l->lookahead == 'w') { adv(l); return 2; }
    /* fall through: 0 followed by more digits or suffix */
  } else {
    adv(l); /* first digit 1-9 */
  }

  return finish_suffix(l);
}

/* Scan symbol content after the leading backtick has been consumed. */
static void scan_sym_content(TSLexer *l) {
  if (l->lookahead == '"') {
    adv(l);
    while (l->lookahead && l->lookahead != '"' && l->lookahead != '\n') adv(l);
    if (l->lookahead == '"') adv(l);
    return;
  }
  /* Identifier/number content: letters, digits, dot */
  int any = 0;
  while (
    (l->lookahead >= 'a' && l->lookahead <= 'z') ||
    (l->lookahead >= 'A' && l->lookahead <= 'Z') ||
    (l->lookahead >= '0' && l->lookahead <= '9') ||
    l->lookahead == '.'
  ) { adv(l); any = 1; }
  if (any) return;
  /* Minus: '-' op or start of negative number/identifier */
  if (l->lookahead == '-') {
    adv(l);
    while (
      (l->lookahead >= 'a' && l->lookahead <= 'z') ||
      (l->lookahead >= 'A' && l->lookahead <= 'Z') ||
      (l->lookahead >= '0' && l->lookahead <= '9') ||
      l->lookahead == '.'
    ) adv(l);
    return;
  }
  /* Single operator char */
  const char *ops = "%!&+*|<>=~,^#_$?@/";
  for (const char *p = ops; *p; p++) {
    if (l->lookahead == (int)*p) { adv(l); return; }
  }
  /* Bare backtick: empty content */
}

/* Run the strand loop starting from the second element.
   Returns the result_symbol or 0 if no strand. */
static int strand_loop(TSLexer *l, int has_float, int is_date, int is_time,
                       int want_ints, int want_floats, int want_dates, int want_times) {
  l->mark_end(l);
  int count = 1;
  while (1) {
    if (l->lookahead != ' ' && l->lookahead != '\t') break;
    while (l->lookahead == ' ' || l->lookahead == '\t') adv(l);
    int nxt = scan_num(l);
    if (nxt == 0) break;
    if (is_date  && nxt != 3) break;
    if (is_time  && nxt != 4) break;
    if (!is_date && !is_time && (nxt == 3 || nxt == 4)) break;
    if (nxt == 2) has_float = 1;
    count++;
    l->mark_end(l);
  }
  if (count < 2) return 0;
  if (is_date  && want_dates)  { l->result_symbol = DATES;  return 1; }
  if (is_time  && want_times)  { l->result_symbol = TIMES;  return 1; }
  if (has_float && want_floats) { l->result_symbol = FLOATS; return 1; }
  if (!has_float && want_ints)  { l->result_symbol = INTS;   return 1; }
  return 0;
}

int tree_sitter_terse_external_scanner_scan(void *payload, TSLexer *lexer, const char *valid_symbols) {

  /* STRING: direct match when lexer is positioned at '"' */
  if (valid_symbols[STRING] && lexer->lookahead == '"') {
    return scan_string(lexer);
  }

  /* MINUS: '-' that starts a negative number in transit position */
  if (valid_symbols[MINUS] && lexer->lookahead == '-') {
    lexer->advance(lexer, 0);
    lexer->mark_end(lexer);
    if (lexer->lookahead == '.') lexer->advance(lexer, 0);
    if ('0' > lexer->lookahead || lexer->lookahead > '9') return 0;
    lexer->result_symbol = MINUS;
    return 1;
  }

  /* Skip leading whitespace for strand/symbol detection: tree-sitter calls the
     external scanner at whitespace but won't call it again after skipping extras,
     so we must consume the whitespace ourselves (with skip=1 so it's not included
     in the token text). If we subsequently fail to match, tree-sitter rewinds. */
  int need_skip = valid_symbols[STRING]  || valid_symbols[SYMBOLS] ||
                  valid_symbols[BOOL]    || valid_symbols[BOOLS]   ||
                  valid_symbols[INTS]    || valid_symbols[FLOATS]  ||
                  valid_symbols[DATES]   || valid_symbols[TIMES];
  if (need_skip && (lexer->lookahead == ' ' || lexer->lookahead == '\t')) {
    while (lexer->lookahead == ' ' || lexer->lookahead == '\t')
      lexer->advance(lexer, 1); /* skip: consume but don't include in token */
  }

  /* STRING: match after whitespace skip */
  if (valid_symbols[STRING] && lexer->lookahead == '"') {
    return scan_string(lexer);
  }

  /* SYMBOLS: two or more symbols (contiguous or space-separated) */
  if (valid_symbols[SYMBOLS] && lexer->lookahead == '`') {
    adv(lexer);
    scan_sym_content(lexer);
    lexer->mark_end(lexer);
    int count = 1;
    while (1) {
      while (lexer->lookahead == ' ' || lexer->lookahead == '\t') adv(lexer);
      if (lexer->lookahead != '`') break;
      adv(lexer);
      scan_sym_content(lexer);
      count++;
      lexer->mark_end(lexer);
    }
    if (count < 2) return 0;
    lexer->result_symbol = SYMBOLS;
    return 1;
  }

  int need_bool = (valid_symbols[BOOL] || valid_symbols[BOOLS]);
  int need_num  = (valid_symbols[INTS] || valid_symbols[FLOATS] ||
                   valid_symbols[DATES] || valid_symbols[TIMES]);

  /* Unified handler for: BOOL, BOOLS, INTS, FLOATS, DATES, TIMES.
     All start with digits, '-', or '.'.
     The tricky case: '0' and '1' can start both bools ([01]+b) and ints. */
  if ((lexer->lookahead == '0' || lexer->lookahead == '1') && (need_bool || need_num)) {
    int first_digit = lexer->lookahead;
    int nbits = 0;
    while (lexer->lookahead == '0' || lexer->lookahead == '1') {
      adv(lexer);
      nbits++;
    }
    /* Check for bool/bools suffix */
    if (need_bool && lexer->lookahead == 'b') {
      adv(lexer);
      lexer->mark_end(lexer);
      if (nbits == 1 && valid_symbols[BOOL]) { lexer->result_symbol = BOOL; return 1; }
      if (nbits >= 2 && valid_symbols[BOOLS]) { lexer->result_symbol = BOOLS; return 1; }
      return 0;
    }
    /* Not a bool. Use the consumed [01]+ as start of first integer element. */
    if (!need_num) return 0;
    /* Complete the first number from current position */
    int first = 1;
    if (nbits == 1 && first_digit == '0') {
      /* Handle 0-prefixed special forms: 0N, 0W, 0n, 0w, 0x */
      if (lexer->lookahead == 'N' || lexer->lookahead == 'W') { adv(lexer); first = 1; }
      else if (lexer->lookahead == 'n' || lexer->lookahead == 'w') { adv(lexer); first = 2; }
      else if (lexer->lookahead == 'x' || lexer->lookahead == 'X') {
        adv(lexer);
        while (xdig(lexer->lookahead)) adv(lexer);
        first = 1;
      } else {
        first = finish_suffix(lexer);
      }
    } else {
      first = finish_suffix(lexer);
    }
    if (first == 0) return 0;
    return strand_loop(lexer, first==2, first==3, first==4,
                       valid_symbols[INTS], valid_symbols[FLOATS],
                       valid_symbols[DATES], valid_symbols[TIMES]);
  }

  /* Numeric strand starting with 2-9, '-', or '.' */
  if (need_num && (dig(lexer->lookahead) || lexer->lookahead == '-' || lexer->lookahead == '.')) {
    int first = scan_num(lexer);
    if (first == 0) return 0;
    return strand_loop(lexer, first==2, first==3, first==4,
                       valid_symbols[INTS], valid_symbols[FLOATS],
                       valid_symbols[DATES], valid_symbols[TIMES]);
  }

  return 0;
}
