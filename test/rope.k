/ test/rope.k — SumTree rope buffer (lib/rope.k).
/ Run: ink test/rope.k
2:"lib/rope.k"

pass: 0
fail: 0
chkN: 0
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; {[n;g;w] fail::fail+1; `0 0:"FAIL #",($chkN)," ",n," got ",($g)," want ",$w}[name;got;want]]; 0}

cp: {`i$x}                                   / ASCII text → codepoints
st: {[s] rope.new cp s}                      / rope from an ASCII string
tx: {[r] `c$rope.text r}                     / rope → ASCII text

/ ── construction / summaries ─────────────────────────────────────────────────
chk["empty len";   rope.len st"";            0]
chk["empty rows";  rope.rows st"";           1]
chk["empty text";  tx st"";                  ""]
chk["len";         rope.len st"hello";       5]
chk["text";        tx st"hello";             "hello"]
chk["rows 1";      rope.rows st"a\nb\nc";    3]
chk["nlines";      rope.nlines st"a\nb\nc";  2]

/ A document long enough to be a real multi-level tree: 400 lines ⇒ ~3200
/ codepoints ⇒ ~50 leaves ⇒ 3 levels at arity 8.
BIG: ,/{[i] "line ",($i),"\n"}'!400
R: st BIG
chk["big roundtrip"; tx R;        BIG]
chk["big len";       rope.len R;  #BIG]
chk["big rows";      rope.rows R; 401]

/ ── line addressing ──────────────────────────────────────────────────────────
L: st"alpha\nbeta\n\ngamma"
chk["lineAt 0";    `c$rope.lineAt[L;0];  "alpha"]
chk["lineAt 1";    `c$rope.lineAt[L;1];  "beta"]
chk["lineAt 2";    `c$rope.lineAt[L;2];  ""]
chk["lineAt 3";    `c$rope.lineAt[L;3];  "gamma"]
chk["lineStart 0"; rope.lineStart[L;0];  0]
chk["lineStart 1"; rope.lineStart[L;1];  6]
chk["lineStart 3"; rope.lineStart[L;3];  12]
chk["lineLen 2";   rope.lineLen[L;2];    0]
chk["trailing nl"; `c$rope.lineAt[st"a\n";1]; ""]
chk["trailing rows"; rope.rows st"a\n";  2]

/ Every line of the big document, via the tree.
bigLine: {[i] `c$rope.lineAt[R;i]}
chk["big lineAt all"; bigLine'!400; {[i] "line ",$i}'!400]

/ ── offset ↔ point ───────────────────────────────────────────────────────────
chk["pt 0";    rope.pt[L;0];   0 0]
chk["pt 3";    rope.pt[L;3];   0 3]
chk["pt 6";    rope.pt[L;6];   1 0]
chk["pt 11";   rope.pt[L;11];  2 0]
chk["pt 12";   rope.pt[L;12];  3 0]
chk["pt end";  rope.pt[L;17];  3 5]
chk["off 1 2"; rope.off[L;1;2]; 8]
chk["off clamp"; rope.off[L;1;99]; 10]
/ round-trip offset→point→offset over the big document
rtOff: {[i] p:rope.pt[R;i]; rope.off[R;p 0;p 1]}
chk["pt/off roundtrip"; rtOff'!300; !300]

/ ── slicing ──────────────────────────────────────────────────────────────────
chk["sub head";  `c$rope.sub[L;0;5];   "alpha"]
chk["sub mid";   `c$rope.sub[L;6;4];   "beta"]
chk["sub span";  `c$rope.sub[L;3;6];   "ha\nbet"]
chk["sub clamp"; `c$rope.sub[L;14;99]; "mma"]
chk["sub zero";  `c$rope.sub[L;3;0];   ""]
chk["sub cross-leaf"; `c$rope.sub[R;100;200]; 200#100_BIG]

/ ── edits ────────────────────────────────────────────────────────────────────
chk["ins head";  tx rope.ins[st"world";0;cp"hello "];   "hello world"]
chk["ins tail";  tx rope.ins[st"hello";5;cp" world"];   "hello world"]
chk["ins mid";   tx rope.ins[st"helld";3;cp"lo wor"];   "hello world"]
chk["ins empty"; tx rope.ins[st"";0;cp"hi"];            "hi"]
chk["del head";  tx rope.del[st"hello world";0;6];      "world"]
chk["del tail";  tx rope.del[st"hello world";5;6];      "hello"]
chk["del all";   tx rope.del[st"hello";0;5];            ""]
chk["del clamp"; tx rope.del[st"hello";3;99];           "hel"]
chk["splice";    tx rope.splice[st"hello world";6;5;cp"ink"]; "hello ink"]

/ Edits must keep the newline summary honest.
E1: rope.ins[st"ab";1;cp"\n"]
chk["ins nl rows"; rope.rows E1; 2]
chk["ins nl text"; tx E1;        "a\nb"]
E2: rope.del[st"a\nb";1;1]
chk["del nl rows"; rope.rows E2; 1]
chk["del nl text"; tx E2;        "ab"]

/ Typing one character at a time crosses the leaf-split path many times.
typed: {[r;c] rope.ins[r;rope.len r;,c]}
T: (st"") typed/ cp BIG
chk["typed len";  rope.len T;  #BIG]
chk["typed text"; tx T;        BIG]
chk["typed rows"; rope.rows T; 401]
chk["typed line 200"; `c$rope.lineAt[T;200]; "line 200"]

/ Backspacing all of it must land back on the empty rope.
bsp: {[r;i] rope.del[r;(rope.len r)-1;1]}
D: T bsp/ !300
chk["bsp len";  rope.len D;   (#BIG)-300]
chk["bsp text"; tx D;         (-300)_BIG]

/ Editing in the middle of a big document, repeatedly.
mid: {[r;i] rope.ins[r;(rope.len r)div 2;cp"X"]}
M: R mid/ !50
chk["mid len";  rope.len M; 50+#BIG]
chk["mid count"; +/(rope.text M)=cp"X"; 50]

/ Delete a span crossing many leaves.
X: rope.del[R;100;500]
chk["cross del text"; tx X; (100#BIG),600_BIG]
chk["cross del rows"; rope.rows X; 1++/(rope.text X)=10]

`0 0: "rope: ",($pass),"/",($chkN)," passed"
$[fail>0; `0 0:"ROPE TESTS FAILED"; 0]
