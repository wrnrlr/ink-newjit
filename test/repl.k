/ test/repl.k — the k repl (tools/repl.k) minus its stdin loop.
/
/ What is pinned here is the part that used to live in Zig: the multi-line dict /
/ table / keyed-table grids the REPL prints, the entry trimming, and the rule that
/ decides when an entry is still open because a string was left unterminated.
/ Everything below is what `ink` on a terminal actually shows, so a change in
/ column padding or alignment fails here rather than in someone's session.
/
/ Run: ink test/repl.k

repl.TEST: 1                      / load the helpers, do not start the loop
2: "tools/repl.k"

Q: `c$34                          / a lone quote, to build open-string cases
ok:: 0; nok:: 0
chk: {[nm;b] $[b; ok::ok+1; nok::nok+1]; $[b; 0; `0: "FAIL ",nm,"\n"]}
eq:  {[nm;got;want] chk[nm; got~want]; $[got~want; 0; `0: "  got:  ",got,"\n  want: ",want,"\n"]}

run: {[]
  / ── evaluating source ─────────────────────────────────────────────────────
  chk["eval: a value";        (. "1+2")~3]
  chk["eval: a binding is null"; (. "reptmp: 7")~::]
  chk["eval: the binding took"; (. "reptmp")~7]
  chk["eval: trailing ; suppresses"; (. "2+2;")~::]
  chk["eval: a runtime error is a value"; (@. "1+`a")~`"!"]
  chk["eval: a parse error is a value";   (@. "(a:1;2)")~`"!"]

  / ── trimming ──────────────────────────────────────────────────────────────
  eq["trim: both ends";      repl.trim "  a+b \t\n"; "a+b"]
  eq["trim: all blank";      repl.trim " \n\t"; ""]
  eq["trim: empty";          repl.trim ""; ""]
  eq["trim: single char";    repl.trim "3"; ,"3"]
  eq["rtrim: keeps padding"; repl.rtrim "  a  "; "  a"]

  / ── entry still open? only an unterminated MULTI-line string continues ────
  chk["open: complete expression"; ~repl.open "1+2\n"]
  chk["open: quote at end of line"; repl.open ("x:",Q,"\nabc\n")]
  chk["open: closed again";        ~repl.open ("x:",Q,"\nabc",Q,"\n")]
  chk["open: single-line string";  ~repl.open ("x:",Q,"abc\n")]
  chk["open: quote inside a comment"; ~repl.open (" / a ",Q," quote\n")]

  / ── cells ─────────────────────────────────────────────────────────────────
  eq["cell: chars are unquoted"; repl.cell "ab"; "ab"]
  eq["cell: symbol drops the tick"; repl.cell `ab; "ab"]
  eq["cell: symbol vector";      repl.cell `a`bb; "a bb"]
  eq["cell: number";             repl.cell 12; "12"]
  eq["cell: nested list";        repl.cell (1 2;3 4); "(1 2;3 4)"]

  / ── grids ─────────────────────────────────────────────────────────────────
  eq["dict"; repl.pretty (a:1;b:2); "a|1\nb|2"]
  eq["dict: one entry"; repl.pretty (a:1); "a|1"]
  eq["dict: keys are padded"; repl.pretty (nm:`ab`c;q:(1 2;3 4)); "nm|ab c\nq |(1 2;3 4)"]
  eq["dict: empty stays a literal"; repl.pretty ()!(); "()!()"]

  eq["table"; repl.pretty ([]a:1 2;b:3 4); "a b\n- -\n1 3\n2 4"]
  eq["table: one column"; repl.pretty ([]x:1 2); "x\n-\n1\n2"]
  eq["table: no rows"; repl.pretty ([]a:!0); "a\n-"]
  eq["table: numbers right, text left"
     repl.pretty ([]nm:`ab`c;val:1.5 2.25;s:("xy";"z"))
     "nm  val s\n-- ---- --\nab  1.5 xy\nc  2.25 z"]

  eq["keyed table"; repl.pretty ([k:1 2]v:3 4); "k|v\n-|-\n1|3\n2|4"]
  eq["keyed table: key column padded"
     repl.pretty ([k:`a`bb]v:3 4;w:"xy")
     "k |v w\n--|- -\na |3 x\nbb|4 y"]

  / ── the raw escape hatch: a leading blank asks for the k literal ──────────
  eq["raw: dict as a literal"; repl.fmt[0; (a:1;b:2)]; "(a:1;b:2)"]
  eq["raw: table as a literal"; repl.fmt[0; ([]a:1 2)]; "([]a:1 2)"]
  eq["grid: nested list breaks lines"; repl.fmt[1; (1 2;3 4)]; "(1 2\n 3 4)"]

  `0: "repl: ",($ok)," ok, ",($nok)," fail\n"}
z: run[]
