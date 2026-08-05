/ tools/repl.k — the interactive read-eval-print loop.

/ Two runtime primitives carry the parts that cannot live in k: `. src` evaluates
/ ink source in the global scope (a failure arrives as an error VALUE, so a bad
/ entry prints like any other result) and `` `show x `` renders a value the way
/ the REPL prints it.
/
/ Two parse rules shape the style below: a lambda cannot close over a caller's
/ locals (so helpers take their context as leading parameters and vary the LAST
/ one under a projection), and an adverb binds to the whole phrase on its left
/ (so `" "/f'x` would derive a verb from `" "/f` — every each/fold lands on its
/ own line instead).
/
/ Definitions carry their `repl.` prefix; INSIDE a member's body a bare name is
/ resolved against the enclosing namespace first, so the prefix is dropped there
/ (`trim e`, `PEND:: …`).  A parameter or local of the same name still wins, and
/ a name with no matching member (`show`, `in`) still reaches the global.

repl.PROMPT:"  ";repl.WS:" \t\r\n";repl.BS:"\\"

/ ── stdin ───────────────────────────────────────────────────────────────────
/ `1:`stdin` hands back whatever bytes are available (blocking for at least one,
/ "" at end of input), so lines are re-assembled here.

repl.PEND::""                     / bytes read from stdin but not yet consumed
repl.EOF::0b                      / 1 once stdin has reported end of input

/ append the next chunk of input; at EOF close the pending line off with a newline
repl.feed:{[b]d:1:`stdin;$[0=#d;[EOF::1b;b,"\n"];b,d]}
repl.fill:{[b]{(~EOF)&(#x)=x?"\n"}feed/b}

/ one physical line, without its newline
repl.readln:{[]
  PEND:: fill PEND
  i: PEND?"\n"
  r: i#PEND
  PEND:: (i+1)_PEND
  r}

/ ── an unfinished entry keeps the prompt coming ─────────────────────────────
/ Two things leave an entry unfinished: an open multi-line string, and a bracket
/ that has not been closed yet — so `f:{` and `(1;` read on, while a stray closer
/ (`x+1}`) does not.  A `"` at the very end of a line opens a MULTI-LINE string
/ (the lexer's rule is that the quote is followed by a newline); an unclosed
/ single-line string is a complete, if broken, entry.  A `"` inside a string
/ closes it only when the next character is one that can follow a noun.
/ State: 0 code, 1 multi-line string, 2 single-line string, 3 comment,
/        4/5 the character escaped by a backslash inside 1/2.

repl.CLOSE:("\n\t ;()[]{}"),repl.BS,"%!&+*|<>=~,^#_$?@./-:"

repl.sstep:{[s;p]
  a: p 0                          / previous character
  c: p 1                          / current
  n: p 2                          / next
  $[s=4; 1
   ;s=5; 2
   ;s=3; $[c="\n"; 0; 3]
   ;s=1; $[c~BS; 4; (c="\"")&n in CLOSE; 0; 1]
   ;s=2; $[c~BS; 5; (c="\"")&n in CLOSE; 0; c="\n"; 0; 2]
   ;c="\""; $[n="\n"; 1; 2]
   ;(c="/")&a in " \t\n;"; 3
   ;0]}

/ Brackets are counted only where the scan says the text is code, so a `{` in a
/ string or a comment does not hold the entry open.  The tally is a plain total:
/ a closer with nothing to close leaves it at or below zero, and the entry ends.
repl.OPENB:"([{"
repl.SHUTB:")]}"
repl.depth:{[st;x] c: 0=st
  o: +/c&(#OPENB)>OPENB?x
  s: +/c&(#SHUTB)>SHUTB?x
  o-s}
repl.open:{[x] $[0=#x; 0; opens x]}
repl.opens:{[x] w: 3':" ",x," "
  st: 0 sstep\w                     / the state each character leaves behind
  ((*|st) in 1 4)|0<depth[st;x]}

/ one logical entry: physical lines joined until no string is left open
repl.more:{[b] `stdout 1: PROMPT; b,(readln 0),"\n"}
repl.entry:{[] b: (readln 0),"\n"; {(~EOF)&open x}more/b}

/ ── text helpers ────────────────────────────────────────────────────────────
/ indices of the non-blank characters.  `?` on a one-element vector answers with
/ an ATOM, and monadic `&` on an atom counts rather than locates, so the mask is
/ reshaped back to the string's length first.
repl.keep: {[s] m: (#WS)=WS?s; &(#s)#m}
repl.trim: {[s] i: keep s; $[0=#i; ""; (*i)_(1+*|i)#s]}
repl.rtrim:{[s] i: keep s; $[0=#i; ""; (1+*|i)#s]}        / a grid may open with padding
repl.lpad: {[w;s] ((w-#s)#" "),s}
repl.rpad: {[w;s] s,(w-#s)#" "}
repl.lines:{[ls] "\n"/ls}
repl.colwidth:{[ls] n: #'ls; 0|/n}        / widest of a list of cells (0 when empty)

/ ── cells ───────────────────────────────────────────────────────────────────
/ A grid cell is raw text: char data unquoted, symbols without their backtick,
/ everything else in its ordinary single-line form.  Always a char VECTOR — a
/ list of char atoms would collapse into one string when rows are assembled.

repl.syms:{[v] s:$'v; n: 1_'s; " "/n}
repl.cell:{[v] t:@v
  $[t~`C;v
   ;t~`c;,v
   ;t~`S;syms v
   ;t~`s;1_$v
   ;$v]}

/ A table renders as grid, columns padded to its widest cell, numbers right-aligned
repl.grid:{[t] c:.t
  h:cell'!t
  s:{cell'x}'c
  hw:#'h;cw: colwidth's
  ra:{[c] (@c) in `I`F`B}'c / right aligned
  (h;s;hw|cw;ra; $[0=#c; 0; #*c])}

/ one padded field of a row; `p` pads the last column too (a keyed table's key
/ half, so the `|` after it lines up)
repl.field:{[s;w;r;p;i] v: s i
  $[r i; lpad[w i; v]
   ;p|i<(#s)-1; rpad[w i; v]
   ;v]}
repl.row:{[w;r;p;s] f: field[s;w;r;p]'!#s; " "/f}
repl.dashes:{[w] d: {[n] n#"-"}'w; " "/d}
repl.cellrow:{[s;i] {[j;c] c j}[i]'s}

/ every row of a grid, as already-padded text
repl.rows:{[g;p] rs: cellrow[g 1]'!g 4; row[g 2; g 3; p]'rs}

repl.table:{[t] g: grid t
  hd: (row[g 2; g 3; 0] g 0; dashes g 2)
  rs: rows[g; 0]
  lines $[0=#rs; hd; hd,rs]}

/ a keyed table is a dict of two tables sharing rows, joined on a `|`
repl.pipe:{[k;v;i] (k i),"|",v i}
repl.keyed:{[d]
  kg: grid[!d]                     / bracketed: a bare `!` after a name reads as DYADIC
  vt: .d
  vg: grid vt
  h:  (row[kg 2; kg 3; 1] kg 0),"|",row[vg 2; vg 3; 0] vg 0
  sp: (dashes kg 2),"|",dashes vg 2
  hd: (h; sp)
  n:  (kg 4)&vg 4
  rs: pipe[rows[kg; 1]; rows[vg; 0]]'!n
  lines $[0=n; hd; hd,rs]}

/ a dict renders one `key|value` line per entry.  A one-entry dict holds its
/ value unwrapped, so re-enlist it before rendering.
repl.entryline:{[w;k;c;i] (rpad[w; k i]),"|",c i}
repl.dict:{[d]
  k: cell'!d
  v: .d
  c: $[1=#k; ,cell v; cell'v]
  w: colwidth k
  ls: entryline[w; k; c]'!#k
  lines ls}

/ ── printing ────────────────────────────────────────────────────────────────
/ An entry that begins with whitespace asks for the raw k literal instead of the
/ grid — the same escape hatch the Zig loop had.

repl.showtable:{[v] $[0=#!v; `show v; table v]}
repl.showdict:{[v] k: !v; w: .v
  $[(`M~@k)&`M~@w; keyed v; 0=#k; `show v; dict v]}
repl.pretty:{[v] t: @v
  $[t~`M; showtable v
   ;t~`m; showdict v
   ;`show v]}

repl.fmt:{[grid;v] $[grid; pretty v; `show v]}
repl.emit:{[s] $[0<#s; `stdout 1: s,"\n"; 0]}

/ ── the loop ────────────────────────────────────────────────────────────────
/ Returns `ok to keep going, `eof to stop.  A null result prints nothing, as in
/ ngn/k — assignments, `\d`, the side-effecting verbs and `::` all yield one.

repl.once:{[]
  `stdout 1: PROMPT
  e: entry 0
  g: $[0=#e; 1; ~(*e) in " \t"]
  s: trim e
  $[EOF&0=#s; :`eof; 0]
  $[(s~"\\q")|s~"exit"; :`eof; 0]
  r:$[0=#s;::;.s]
  $[r~::; 0; emit rtrim fmt[g; r]]
  $[EOF; `eof; `ok]}

repl.run:{[] {x~`ok}once/`ok}

/ Running this file IS the repl.  Bind the loop's terminal `eof so a bare
/ expression statement's value is not echoed.  test/repl.k sets `repl.TEST` first
/ (an unset global reads as 0) to load the helpers without taking over stdin.
repl.done: $[repl.TEST; `test; repl.run 0]
