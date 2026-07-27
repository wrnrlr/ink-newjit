/ test/syntax.k — the configurable highlighter (lib/syntax.k).
/ Run: ink test/syntax.k
/
/ Each case pins the role of EVERY codepoint of a line, written as one initial per
/ column so the expectation reads like the source it describes:
/   . text   # comment  N num   B bool  S str   Y sym   v name  p param
/   o op     m mono     D dyad  / adverb  \ digram (an adverb with TWO left arguments)
/   =assign  [ bracket  { brace ( paren ? cond  k key   ; sep   C cmd
2:"lib/syntax.k"

pass: 0
fail: 0
chkN: 0
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; {[n;g;w] fail::fail+1; `0 0:"FAIL #",($chkN)," ",n; `0 0:"  got  ",g; `0 0:"  want ",w}[name;got;want]]; 0}

INI: ".#NBSYvpomD/\\=[{(?k;C"
hl: {[s] `c$INI@syn.hl[`ink; syn.dec s]}
row:{[src;want] chk[src; hl src; want]}

/ ── literals ─────────────────────────────────────────────────────────────────
row["123;12.3";           "NNN;NNNN"]
row["01011b";             "BBBBBB"]
row["\"abc\"";            "SSSSS"]
row["`a`b`c";             "YYYYYY"]
row["1.5 2.5";            "NNNNNNN"]
row["0N";                 "NN"]

/ ── valence: a primitive is coloured by how it is being used ────────────────
row["1+2";                "NDN"]         / transit ⇒ dyadic
row["*1 2 3";             "mNNNNN"]      / apposit ⇒ monadic
row["f[1;2]";             "v[N[N["]      / call brackets are grey
row["2:\"lib/x.k\"";      "mmSSSSSSSSS"] / monadic io verb
row["x 1: y";             "v.DD.v"]      / dyadic io verb

/ ── adverbs: coloured by how many LEFT arguments the derived verb takes ─────
/ ONE left argument — an ordinary adverb.
row["sum:+/";             "vvv=D/"]      / fold; the + under it reads as dyadic
row["+\\1 2 3";           "D/NNNNN"]     / scan
row["f'x";                "v/v"]         / each
row["#'x";                "m/v"]         / …and only plain each applies its verb monadically
row["+/'x";               "D//v"]        / each over a fold
row["-':12 13 11";        "D//NNNNNNNN"] / eachprior: `': is not plain each, so - is dyadic
row["24 60 60\\3723";     "NNNNNNNN/NNNN"]  / encode
/ TWO left arguments — the DIGRAM forms.
row["10+/1 2 3";          "NND\\NNNNN"]  / seeded fold
row["2 3#'\"ab\"";        "NNND\\SSSS"]  / zip — and its verb IS dyadic
row["x f'y";              "v.v\\v"]      / zip over names
row["1 2*/:3 4";          "NNND\\\\NNN"] / eachright (both glyph chars)
row["10-':12 13";         "NND\\\\NNNNN"]  / seeded eachprior
row["5(2*)/1";            "N(ND(\\N"]    / n-do
row["{x+y}/[1;2]";        "{vDv{\\[N[N["]  / seeded fold, written as a call
row["bounds wander\\5 5"; "vvvvvv.vvvvvv\\NNN"]

/ ── structure: containers own whatever their children don't ─────────────────
row["n:1 2 3";            "v=NNNNN"]
row["N::0N";              "v==NN"]
row["x+:1";               "v==N"]                 / modify-assign is all red
row["f:{[a;b]a+b}[]";     "v={[p[p[vDv{[["]
row["$[0b;\"x\";\"y\"]";  "??BB?SSS?SSS?"]
row["(1;2)";              "(N(N("]
row["[a:1;b:2]";          "{kkN{kkN{"]
row["@[x;I;:;1]";         "=[v[v[[[N["]           / amend reads as assignment
row["a;b";                "v;v"]

/ ── comments ────────────────────────────────────────────────────────────────
row["/ hello";            "#######"]
row["x: 5 / hi";          "v==N.####"]

/ ── a leaf is never char-refined: brackets inside a string stay string ──────
row["\"a[b];c\"";         "SSSSSSSS"]

/ ── half-typed source must still highlight (this runs on every keystroke) ───
row["f:{[a;";             "v={[p["]
row["\"abc";              "SSSS"]
row["1+";                 "ND"]

/ ── multi-line documents keep absolute offsets (a newline is plain text) ────
chk["two lines"; hl "a:1\nb:2"; "v=N.v=N"]
chk["blank line"; hl "a:1\n\nb:2"; "v=N..v=N"]

/ ── unicode: offsets are codepoints, not bytes ──────────────────────────────
chk["utf8 comment"; hl "x:1 / café"; "v=N.######"]
chk["utf8 string";  hl "s:\"héllo\""; "v=SSSSSSS"]
chk["utf8 4-byte";  hl "/ 😀 ok"; "######"]

/ ── UTF-8 codec ─────────────────────────────────────────────────────────────
chk["dec ascii";  syn.dec "abc";        97 98 99]
chk["dec empty";  #syn.dec "";          0]
chk["dec mixed";  syn.dec "a¢€😀";      97 162 8364 128512]
chk["enc mixed";  `c$syn.enc 97 162 8364 128512; "a¢€😀"]
chk["enc ascii";  `c$syn.enc 97 98 99;  "abc"]

/ ── runs ────────────────────────────────────────────────────────────────────
R: syn.runs 3 3 3 7 7 1
chk["run starts"; R 0; 0 3 5]
chk["run lens";   R 1; 3 2 1]
chk["run roles";  R 2; 3 7 1]
/ Bracket-apply: `syn.runs ,4` would read the `,` as JOIN and pair the lambda with 4.
chk["runs empty"; (syn.runs[!0]) 0; !0]
chk["runs one";   (syn.runs[,4]) 1; ,1]

/ ── theme is data: every role resolves to an rgba, in both themes ───────────
chk["dark roles";  #syn.themeDark;  #syn.ROLES]
chk["light roles"; #syn.themeLight; #syn.ROLES]
chk["rgba shape";  #syn.rgba`num;   4]
chk["rgbas";       #syn.rgbas[];    #syn.ROLES]
setL: {[] syn.setTheme syn.themeLight; r:syn.rgba`num; syn.setTheme syn.themeDark; r}
chk["theme swaps"; ~(setL[])~syn.rgba`num; 1b]

/ ── an unregistered language falls back to plain text ───────────────────────
chk["unknown lang"; syn.hl[`nosuch; 97 98 99]; 3#syn.RTEXT]

`0 0: "syntax: ",($pass),"/",($chkN)," passed"
$[fail>0; `0 0:"SYNTAX TESTS FAILED"; 0]
