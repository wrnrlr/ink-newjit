/ tools/klint.k — flag the `<=` / `>=` parse gotcha in ink source.
/ Usage:  ink tools/klint.k file1.k file2.k ...
/ Exit status = total number of findings (0 = clean).
/
/ k has NO `<=` / `>=`: `x<=y` parses as `x<(=y)` (a silent wrong result). This is the gotcha I hit
/ most — three times in an earlier draft of THIS file. The check scans a per-line CODE MASK (a
/ boolean vector, 1 = a real code char) that blanks out "strings", `symbols and / comments, so `<=`
/ inside those is ignored. Everything is vectorised — no per-char lambdas (which can't close over a
/ caller's locals in ink) — and fully-qualified (no `\d`).
/
/ (The `name`sym`-before-an-operator gotcha and the bracketed-`$[]`-branch gotcha also exist; a
/ reliable check for them needs a real tokenizer / working CST spans — left as future work.)

klint.NF:0
klint.warn:{[path;ln;code;msg] klint.NF:: klint.NF+1; `0:path,":",($ln),": [",code,"] ",msg,"\n"}
klint.ALNUM:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789."

/ ── per-line code mask: 1 = code, 0 = inside a string / `symbol / comment ─────────
/ Folded state machine over char indices. State: 0 code, 1 string, 2 symbol, 3 comment.
klint.LINE:""
klint.mnext:{[st;c;prev]
  $[st=1; $[c="\""; (0;0); (1;0)]                       / in string; closing quote ends it
   st=2; $[c in klint.ALNUM; (2;0); klint.mnext[0;c;prev]]  / in `symbol; alnum stays, else re-handle
   st=3; (3;0)                                          / in comment: rest of line
   c="\""; (1;0)
   c="`"; (2;0)
   (c="/")&prev=" "; (3;0)                              / ` /` (space then slash) begins a comment
   (0;1)]}
klint.mstep:{[acc;i] c:klint.LINE i; prev:$[i=0; " "; klint.LINE i-1]
  r:klint.mnext[acc 0; c; prev]; ((r 0); (acc 1),r 1)}
klint.mask:{[line] klint.LINE::line
  $[0=#line; 0#0; 1_ ({klint.mstep[x;y]}/[(0;,0); !#line]) 1]}

/ ── LE check over one line — vectorised ─────────────────────────────────────────
/ hit at i: line[i] in "<>" AND line[i+1]="=" AND both are code chars.
klint.checkLE:{[path;ln;line]
  $[2>#line; 0; klint.leLine[path;ln;line]]}
klint.leLine:{[path;ln;line]
  m: klint.mask line
  lt: m&(line="<")|line=">"                             / code `<` or `>` at i
  eq: m&line="="                                        / code `=` at i
  hits: lt&(1_eq),0                                     / < / > at i with `=` at i+1
  ix: &hits
  $[#ix; klint.warn[path;ln;"LE ";"`",(,line[*ix]),"=` — k has no <=/>=; use ~(a>b) / ~(a<b)"]; 0]}

klint.PATH:""; klint.LINES:()
klint.checkFile:{[path]
  src: 1: path
  klint.LINES:: (0,1+&src="\n") _ src                   / global: the each-lambda can't close over a local
  klint.PATH:: path
  {klint.checkLE[klint.PATH; x+1; klint.LINES x]}'!#klint.LINES
  0}

klint.run:{[paths]
  klint.NF::0
  {klint.checkFile x}'paths
  n: klint.NF
  `0:"\n",($n)," finding",$[n=1;"";"s"],"\n"
  n}

klint.run x
