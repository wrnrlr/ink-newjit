/ test/lsp.k — end-to-end language-server tests (tools/lsp.k).
/ Run: ink test/lsp.k     (needs zig-out/bin/ink and the json extension)
/
/ tools/lsp.k IS the executable — loading it starts the stdin read loop — so the
/ only honest way to test it is to speak the protocol: frame a batch of JSON-RPC
/ requests, hand them to `ink lsp` on stdin with `x, and decode what comes back.
/
/ The cases below pin the behaviour a progn `[a;b;c]` introduced: a progn opens no
/ scope, so a bind inside a TOP-LEVEL block is a global (and a document symbol),
/ while a bind inside a progn in a lambda body is an ordinary local.
/
/ NB: json.parse COLUMNARISES a JSON array of objects into a dict of columns, so a
/ `Symbol[]`/`LocationLink[]` result arrives as `(name:…;kind:…;…)`, not as a list
/ of records — read a field to get the column and index that.

pass: 0
fail: 0
chkN: 0
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; {[n;g;w] fail::fail+1; `0 0:"FAIL #",($chkN)," ",n; `0 0:"  got  ",($g); `0 0:"  want ",($w)}[name;got;want]]; 0}

/ ── protocol framing ────────────────────────────────────────────────────────
/ ink string literals cannot express CR, so the byte comes from `c$13.
cr:  `c$13
lf:  `c$10
sep: cr,lf,cr,lf
CL:  "Content-Length: "
fr:  {[m] CL,($#m),sep,m}
req: {[id;meth;p] fr json.gen((`jsonrpc`id`method`params)!("2.0";id;meth;p))}
note:{[meth;p] fr json.gen((`jsonrpc`method`params)!("2.0";meth;p))}

/ Split a response stream into bodies: every frame starts with CL and its body
/ with `{`, so dropping up to the first brace strips the header.
body:  {[s] (s?"{")_s}
bodies:{[o] body'1_CL\o}
/ The server under test is a real child process. Path defaults to the tree-local
/ build (run from the repo root, like every other test); override with an argument.
BIN:   $[`L=@x; *x; "zig-out/bin/ink"]
drive: {[msgs] {[b] json.parse b}'bodies `x[(BIN;"lsp");,/msgs]}

/ ── response lookup ─────────────────────────────────────────────────────────
R: ()
hasId:{[r] |/`id=!r}
idOf: {[r] r`id}
run:  {[msgs] R:: drive msgs; 0}
byId: {[id] rs:R@&hasId'R; i:&id=idOf'rs; $[#i;(rs@*i)`result;`absent]}
/ Compare positions as plain `line character` pairs: json.parse builds a Position's
/ values as a boxed general list, so `~` against a `(line:1;character:1)` literal
/ (whose values are an int VECTOR) fails even when the numbers agree.
lnch: {[p] ((p`line);(p`character))}
stOf: {[rl;i] lnch (rl@i)`start}
edOf: {[rl;i] lnch (rl@i)`end}

/ ── the document under test ─────────────────────────────────────────────────
/ line 0  a:1                      top-level bind
/ line 1  [b:2;c:3]                top-level progn — b and c are GLOBALS
/ line 2  f:{[x] [y:x*2; :y+1]}    progn in a lambda — y is a LOCAL
/ line 3  d:(k:1;v:2)              dict literal — k and v are keys, not names
uri: "file:///tmp/lsptest.k"
src: "a:1\n[b:2;c:3]\nf:{[x] [y:x*2; :y+1]}\nd:(k:1;v:2)\n"
open: note["textDocument/didOpen";(textDocument:(uri:uri;languageId:"ink";version:1;text:src))]
pos:  {[l;c] (textDocument:(uri:uri);position:(line:l;character:c))}
init: req[1;"initialize";()!()]
bye:  ,/(req[98;"shutdown";()!()];req[99;"exit";()!()])

/ ── document symbols ────────────────────────────────────────────────────────
run (init;open;req[2;"textDocument/documentSymbol";(textDocument:(uri:uri))];bye)
sym: byId 2
/ every name here is one character, so razing the column gives a comparable string
nms: ,/sym`name
chk["a top-level progn's binds are document symbols"; nms; "abcfd"]
chk["neither a lambda-local nor a dict key is one";   |/nms in "kvy"; 0b]
/ SymbolKind: Function=12, Variable=13 — only f is a lambda.
chk["symbol kinds";                                   sym`kind; 13 13 13 12 13]
chk["the first progn bind's position";                stOf[sym`range;1]; 1 1]
chk["the second progn bind's position";               stOf[sym`range;2]; 1 5]

/ ── definition of a progn-local ─────────────────────────────────────────────
/ `y` is used at line 2 col 16 and bound at line 2 col 8; a progn opens no scope,
/ so the use resolves to that bind exactly like any other lambda local.
run (init;open;req[3;"textDocument/definition";pos[2;16]];bye)
def: byId 3
chk["definition of a progn-bound local resolves"; stOf[def`targetRange;0]; 2 8]
chk["  ...spanning just the name";                edOf[def`targetRange;0]; 2 9]

/ A bind in a TOP-LEVEL progn is a global, so a later reference reaches it.
src2:"[b:2;c:3]\ng:{[x] x+b}\n"
op2: note["textDocument/didOpen";(textDocument:(uri:uri;languageId:"ink";version:1;text:src2))]
run (init;op2;req[4;"textDocument/definition";(textDocument:(uri:uri);position:(line:1;character:9))];bye)
chk["a top-level progn bind is reachable from later code"; stOf[(byId 4)`targetRange;0]; 0 1]

/ ── hover on a progn-local ──────────────────────────────────────────────────
/ Regression: doc.at keys on the LINE, so before isTopDef this reported `f`'s
/ signature — the enclosing binding happens to start the same line.
run (init;open;req[5;"textDocument/hover";pos[2;16]];bye)
chk["hover on a progn-bound local"; (byId 5)`contents; (kind:"markdown";value:"**variable** `y` — defined at line 3")]
/ …while the enclosing top-level binding still hovers as the documented function.
run (init;open;req[6;"textDocument/hover";pos[2;0]];bye)
chk["hover on the enclosing binding is unchanged"; ((byId 6)`contents)`value; "```k\nf[x]\n```\n\n*function, 1 arg*"]

/ ── references across a progn boundary ──────────────────────────────────────
rp: (textDocument:(uri:uri);position:(line:2;character:8);context:(includeDeclaration:1b))
run (init;open;req[7;"textDocument/references";rp];bye)
chk["both occurrences of a progn-bound local"; #(byId 7)`range; 2]

`0 0:""
`0 0:($chkN)," assertions: ",($pass)," passed, ",($fail)," failed"
`0 0:$[fail=0; "ALL PASS"; "FAILURES"]
