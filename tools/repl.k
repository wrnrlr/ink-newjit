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

repl.PROMPT:"  ";repl.WS:" \t\r\n";repl.BS:"\\"

/ ── stdin ───────────────────────────────────────────────────────────────────
/ `1:`stdin` hands back whatever bytes are available (blocking for at least one,
/ "" at end of input), so lines are re-assembled here.

repl.PEND::""                     / bytes read from stdin but not yet consumed
repl.EOF::0b                      / 1 once stdin has reported end of input

/ append the next chunk of input; at EOF close the pending line off with a newline
repl.feed:{[b]d:1:`stdin;$[0=#d;[repl.EOF::1b;b,"\n"];b,d]}
repl.fill:{[b]{(~repl.EOF)&(#x)=x?"\n"}repl.feed/b}

/ one physical line, without its newline
repl.readln:{[]
  repl.PEND:: repl.fill repl.PEND
  i: repl.PEND?"\n"
  r: i#repl.PEND
  repl.PEND:: (i+1)_repl.PEND
  r}

/ ── unterminated strings keep the entry open ────────────────────────────────
/ A `"` at the very end of a line opens a MULTI-LINE string (the lexer's rule is
/ that the quote is followed by a newline), and only that keeps the REPL reading;
/ an unclosed single-line string is a complete, if broken, entry.  A `"` inside a
/ string closes it only when the next character is one that can follow a noun.
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
   ;s=1; $[c~repl.BS; 4; (c="\"")&n in repl.CLOSE; 0; 1]
   ;s=2; $[c~repl.BS; 5; (c="\"")&n in repl.CLOSE; 0; c="\n"; 0; 2]
   ;c="\""; $[n="\n"; 1; 2]
   ;(c="/")&a in " \t\n;"; 3
   ;0]}

repl.open:{[x] w: 3':" ",x," "; 1=0 repl.sstep/w}

/ one logical entry: physical lines joined until no string is left open
repl.more:{[b] `stdout 1: repl.PROMPT; b,(repl.readln 0),"\n"}
repl.entry:{[] b: (repl.readln 0),"\n"; {(~repl.EOF)&repl.open x}repl.more/b}

/ ── text helpers ────────────────────────────────────────────────────────────
/ indices of the non-blank characters.  `?` on a one-element vector answers with
/ an ATOM, and monadic `&` on an atom counts rather than locates, so the mask is
/ reshaped back to the string's length first.
repl.keep: {[s] m: (#repl.WS)=repl.WS?s; &(#s)#m}
repl.trim: {[s] i: repl.keep s; $[0=#i; ""; (*i)_(1+*|i)#s]}
repl.rtrim:{[s] i: repl.keep s; $[0=#i; ""; (1+*|i)#s]}   / a grid may open with padding
repl.lpad: {[w;s] ((w-#s)#" "),s}
repl.rpad: {[w;s] s,(w-#s)#" "}
repl.lines:{[ls] "\n"/ls}

/ ── cells ───────────────────────────────────────────────────────────────────
/ A grid cell is raw text: char data unquoted, symbols without their backtick,
/ everything else in its ordinary single-line form.  Always a char VECTOR — a
/ list of char atoms would collapse into one string when rows are assembled.

repl.syms:{[v] s:$'v; n: 1_'s; " "/n}
repl.cell:{[v] t:@v
  $[t~`C;v
   ;t~`c;,v
   ;t~`S;repl.syms v
   ;t~`s;1_$v
   ;$v]}

/ A table renders as grid, columns padded to its widest cell, numbers right-aligned
repl.grid:{[t] c:.t
  h:repl.cell'!t
  s:{repl.cell'x}'c
  hw:#'h;cw:{n: #'x; 0|/n}'s
  ra:{[c] (@c) in `I`F`B}'c / right aligned
  (h;s;hw|cw;ra; $[0=#c; 0; #*c])}

/ one padded field of a row; `p` pads the last column too (a keyed table's key
/ half, so the `|` after it lines up)
repl.field:{[s;w;r;p;i] v: s i
  $[r i; repl.lpad[w i; v]
   ;p|i<(#s)-1; repl.rpad[w i; v]
   ;v]}
repl.row:{[w;r;p;s] f: repl.field[s;w;r;p]'!#s; " "/f}
repl.dashes:{[w] d: {[n] n#"-"}'w; " "/d}
repl.cellrow:{[s;i] {[j;c] c j}[i]'s}

/ every row of a grid, as already-padded text
repl.rows:{[g;p] rs: repl.cellrow[g 1]'!g 4; repl.row[g 2; g 3; p]'rs}

repl.table:{[t] g: repl.grid t
  hd: (repl.row[g 2; g 3; 0] g 0; repl.dashes g 2)
  rs: repl.rows[g; 0]
  repl.lines $[0=#rs; hd; hd,rs]}

/ a keyed table is a dict of two tables sharing rows, joined on a `|`
repl.pipe:{[k;v;i] (k i),"|",v i}
repl.keyed:{[d]
  kg: repl.grid[!d]                / bracketed: a bare `!` after a name reads as DYADIC
  vt: .d
  vg: repl.grid vt
  h:  (repl.row[kg 2; kg 3; 1] kg 0),"|",repl.row[vg 2; vg 3; 0] vg 0
  sp: (repl.dashes kg 2),"|",repl.dashes vg 2
  hd: (h; sp)
  n:  (kg 4)&vg 4
  rs: repl.pipe[repl.rows[kg; 1]; repl.rows[vg; 0]]'!n
  repl.lines $[0=n; hd; hd,rs]}

/ a dict renders one `key|value` line per entry.  A one-entry dict holds its
/ value unwrapped, so re-enlist it before rendering.
repl.entryline:{[w;k;c;i] (repl.rpad[w; k i]),"|",c i}
repl.dict:{[d]
  k: repl.cell'!d
  v: .d
  c: $[1=#k; ,repl.cell v; repl.cell'v]
  w: repl.colwidth k
  ls: repl.entryline[w; k; c]'!#k
  repl.lines ls}

/ ── printing ────────────────────────────────────────────────────────────────
/ An entry that begins with whitespace asks for the raw k literal instead of the
/ grid — the same escape hatch the Zig loop had.

repl.showtable:{[v] $[0=#!v; `show v; repl.table v]}
repl.showdict:{[v] k: !v; w: .v
  $[(`M~@k)&`M~@w; repl.keyed v; 0=#k; `show v; repl.dict v]}
repl.pretty:{[v] t: @v
  $[t~`M; repl.showtable v
   ;t~`m; repl.showdict v
   ;`show v]}

repl.fmt:{[grid;v] $[grid; repl.pretty v; `show v]}
repl.emit:{[s] $[0<#s; `stdout 1: s,"\n"; 0]}

/ ── the loop ────────────────────────────────────────────────────────────────
/ Returns `ok to keep going, `eof to stop.  A null result prints nothing, as in
/ ngn/k — assignments, `\d`, the side-effecting verbs and `::` all yield one.

repl.once:{[]
  `stdout 1: repl.PROMPT
  e: repl.entry 0
  grid: $[0=#e; 1; ~(*e) in " \t"]
  s: repl.trim e
  $[repl.EOF&0=#s; :`eof; 0]
  $[(s~"\\q")|s~"exit"; :`eof; 0]
  r:$[0=#s;::;.s]
  $[r~::; 0; repl.emit repl.rtrim repl.fmt[grid; r]]
  $[repl.EOF; `eof; `ok]}

repl.run:{[] {x~`ok}repl.once/`ok}

/ Running this file IS the repl.  Bind the loop's terminal `eof so a bare
/ expression statement's value is not echoed.  test/repl.k sets `repl.TEST` first
/ (an unset global reads as 0) to load the helpers without taking over stdin.
repl.done: $[repl.TEST; `test; repl.run 0]
