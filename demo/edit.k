/ demo/edit.k — a text editor with live syntax highlighting, drawn with the
/ Canvas/Slug analytic text path.
/
/ Build first:  zig build gpu && zig build font
/ Run:          ink demo/edit.k
/ Snapshot:     ink -snap 0.4 demo/edit.k     (writes edit-snap.png)
/
/ Keys: arrows / home / end / page up / page down move, enter / backspace / delete /
/ tab edit, click places the caret, the wheel scrolls. cmd+shift+= / cmd+shift+-
/ change the font size, cmd+shift+T (or F1) flips the theme.
/
/ Four things worth reusing elsewhere:
/
/  1. THE BUFFER IS A SUMTREE ROPE (lib/rope.k). Text lives in a B-tree of small
/     chunks, each node carrying a (codepoints; newlines) summary, so "which row is
/     offset 9312 on?" and "where does row 400 start?" are O(log n) descents rather
/     than scans, and a keystroke rewrites one chunk plus a summary delta up the
/     spine. The caret is a single codepoint OFFSET; rows and columns are derived.
/
/  2. HIGHLIGHTING COMES FROM THE LANGUAGE ITSELF (lib/syntax.k). `parse` hands back
/     the CST as a column table with CODEPOINT ranges — the same coordinates the rope
/     uses — so a highlight is just "paint each node's range, let children overwrite
/     their parents". No second lexer, no tree-sitter, no LSP round trip (and so no
/     UTF-16 offset translation, which is what talking to LSP would have cost).
/     `parse` tolerates half-typed source, so this re-runs on every edit.
/
/  3. INPUT AS A TABLE. window.run hands each frame a `props`events` column dict —
/     one row per input event since the last frame. Filter by the `kind` column
/     (`text `key `mouse `scroll); payload columns carry nulls where they don't apply.
/
/  4. ANALYTIC TEXT. cnv.text lays a run's glyphs straight into the Slug scene buffer
/     (resolution-independent, antialiased) and advances the pen, so a coloured line
/     is just one cnv.text per run, chained.

2: "lib/canvas.k"
2: "lib/font.k"
2: "lib/rope.k"
2: "lib/syntax.k"

/ ── font ────────────────────────────────────────────────────────────────────
/ Iosevka ships as a TrueType COLLECTION; font.read returns every face in it and
/ face 0 is the narrow monospace cut ("Iosevka"; 1 is Extended, 2 is Oblique, …).
FONT: *font.read "font/Iosevka/SGr-Iosevka-Regular.ttc"

/ ── chrome / layout ─────────────────────────────────────────────────────────
/ Everything below is in LOGICAL points; `setScale` converts to framebuffer pixels.
/ props`width/height/mx/my are FRAMEBUFFER px and props`dpr is the ratio, so on a
/ retina display a size written straight into a draw call comes out half as big.
WINW:  900.
WINH:  600.
SZL:   15.                                    / glyph size
PADXL: 10.                                    / gutter left padding
GUTWL: 42.                                    / gutter width (line numbers)
TOPYL: 8.                                     / first baseline offset from the top
FOOTL: 22.                                    / status bar height
LEADL: 4.                                     / extra leading between baselines

DPR:   0.                                     / last dpr we scaled for (0 = never)
SZ: 0.
SCALE: 0.
ADV: 0.
ASC: 0.
LINEH: 0.
PADX: 0.
GUTW: 0.
TOPY: 0.
FOOT: 0.
setScale:{[s] DPR::s
  SZ:: SZL*s
  SCALE:: font.scale[FONT; SZ]
  ADV:: SCALE * ((FONT`hmtx)`adv) 0           / one cell width (monospace ⇒ all equal)
  MET: font.metrics[FONT; SZ]                 / (ascent; descent; lineGap), descent < 0
  ASC:: MET 0
  LINEH:: (LEADL*s) + (MET 0) - MET 1         / baseline-to-baseline step
  PADX:: PADXL*s; GUTW:: GUTWL*s; TOPY:: TOPYL*s; FOOT:: FOOTL*s}
syncScale:{[s] $[DPR=s; 0; setScale s]}
setScale 1.

KTEXT:`text
KKEY:`key
KMOUSE:`mouse
KSCROLL:`scroll

/ ── theme ───────────────────────────────────────────────────────────────────
/ syn.THEME owns the SYNTAX colours; the editor's own chrome (page, gutter, caret,
/ current line) is picked from the same Tailwind palette so the two stay in step.
/ Everything below is rebuilt by `setTheme`, so F1 reskins the whole editor.
solid:{[c] gpu.solid[c 0; c 1; c 2; c 3]}
DARK: 1b
PAINTS: ()                                    / one canvas paint per syn.ROLES entry
BG: ()
GUTBG: ()
GUTFG: ()
CARET: ()
CURLN: ()
setTheme:{[d] DARK::d
  syn.setTheme $[d; syn.themeDark; syn.themeLight]
  PAINTS:: solid' syn.rgbas[]
  BG::    solid oklch $[d; Zinc950; Zinc50]
  GUTBG:: solid oklch $[d; Zinc900; Zinc100]
  GUTFG:: solid oklch $[d; Zinc600; Zinc400]
  CURLN:: solid oklch $[d; Zinc900; Zinc100]
  CARET:: solid oklch $[d; Sky400;  Sky600]}
setTheme 1b

/ ── document ────────────────────────────────────────────────────────────────
SEED: (
  "/ demo/edit.k — live highlighting straight off the built-in parser."
  "/ Type anything; F1 flips the theme.  Every glyph below is coloured by"
  "/ its CST node, not by a regex."
  ""
  "123;12.3            / numeric literals are orange"
  "01011b              / a boolean literal is yellow"
  "\"abc\"               / a char literal is green"
  "`a`b`c              / a symbol literal is teal"
  "1+2                 / a transit (a full dyadic op) is purple"
  "*1 2 3              / an apposit (a monadic op) is blue"
  "$[0b;\"true\";\"false\"]  / the $ op and its brackets are yellow"
  "f:{[a;b]a+b}[]      / lambda args and call brackets are grey"
  "n:1 2 3             / an assign operator is red"
  "N::0N               / the double bind is red too"
  "@[x;I;:;1.+.25*+/x@W]"
  "sum:+/              / an adverb with ONE left arg is purple"
  "10+/1 2 3           / …with TWO — a digram — it is pink"
  "bounds wander\\5 5    / any glyph: ' / \\ — the arity is what counts"
  ""
  "hilbert:{[n;p] $[n=0; ,p; ,/hilbert[n-1;]'quad p]}"
  "walk:{[t] +/{x*x}'t@!#t}"
  "step:{[s;dt] s+dt*vel s}"
  "" )
/ The raze is its own statement: `rope.new syn.dec ,/ f' SEED` would compose into a
/ train (an adverb binds to its LEFT) instead of applying right to left.
SRC: ,/{x,"\n"}'SEED
BUF: rope.new syn.dec SRC
LANG: `ink

CO:   0                                       / caret, as a codepoint offset
GOAL: 0                                       / sticky column for up/down
TOP:  0                                       / first visible row
REV:  0                                       / bumped on every edit
NVIS: 1                                       / visible rows, recomputed each frame

/ ── highlight cache ─────────────────────────────────────────────────────────
/ One role per codepoint of the whole document, rebuilt only when the text changed.
HLREV: -1
HLR: !0
hlBuild:{[] HLR:: syn.hl[LANG; rope.text BUF]; HLREV::REV}
hlSync:{[] $[HLREV=REV; 0; hlBuild[]]}

/ ── editing ─────────────────────────────────────────────────────────────────
/ Every op is a named function, so $ only ever dispatches. (A $[…] branch can now
/ hold a `[stmt;stmt]` progn — see doc/reference.md — so these could be inlined.)
docLen:{[] rope.len BUF}
row:{[] rope.rowOf[BUF;CO]}
col:{[] CO-rope.lineStart[BUF;row[]]}

edIns:{[cps] BUF:: rope.ins[BUF;CO;cps]; CO:: CO+#cps; REV::REV+1; GOAL::col[]}
edDel:{[a;n] BUF:: rope.del[BUF;a;n]; CO::a; REV::REV+1; GOAL::col[]}

/ Bracket-apply the enlist: `edIns ,cp` would read the `,` as JOIN and pair the
/ function with the codepoint instead of calling it.
insCh:{[cp] edIns[,cp]}
kEnter:{[] edIns[,10]}
kTab:{[] edIns 32 32}
kBack:{[] $[CO>0; edDel[CO-1;1]; 0]}
kDel:{[] $[CO<docLen[]; edDel[CO;1]; 0]}

setCo:{[o] CO:: 0|o&docLen[]; GOAL::col[]}
mLeft:{[] setCo CO-1}
mRight:{[] setCo CO+1}
mHome:{[] setCo rope.lineStart[BUF;row[]]}
mEnd:{[] setCo rope.lineEnd[BUF;row[]]}
/ Vertical motion keeps the sticky GOAL column, so a short line doesn't eat it.
goRow:{[r] rr: 0|r&(rope.rows BUF)-1; CO:: rope.off[BUF;rr;GOAL]}
mUp:{[] goRow row[]-1}
mDown:{[] goRow row[]+1}
mPgUp:{[] goRow row[]-NVIS-1}
mPgDn:{[] goRow row[]+NVIS-1}

/ ── zoom ────────────────────────────────────────────────────────────────────
/ Font size is a LOGICAL size, so a zoom just moves SZL and re-derives the pixel
/ metrics at the current dpr. The canvas glyph cache is keyed by size, so a new size
/ costs one outline extraction per distinct glyph and is free from then on.
zoom:{[d] SZL:: 8.|32.&SZL+d; setScale DPR; follow[]}

/ GLFW key codes → action. Printable keys arrive separately as text events, so
/ doKey only claims the editing keys and ignores everything else. `mods` bits are
/ 1=shift 2=ctrl 4=alt 8=super — extracted by division, since `&` on ints is MIN,
/ not a bitwise and.
modBit:{[m;b] 1=(m div b) mod 2}
/ cmd (+shift) with the +/- keys zooms; cmd+shift+T flips the theme. F1 also flips it,
/ but macOS eats F1 for screen brightness unless "use F1, F2 as function keys" is on,
/ hence the cmd binding. NB `setTheme ~DARK` would parse as Match — bracket the call.
doCmd:{[k] $[(k=61)|k=334; zoom[1.]; (k=45)|k=333; zoom[-1.]; k=84; setTheme[~DARK]; 0]}
doEdit:{[k] $[k=257; kEnter[]; k=259; kBack[]; k=261; kDel[]
  k=263; mLeft[];  k=262; mRight[]; k=265; mUp[];   k=264; mDown[]
  k=268; mHome[];  k=269; mEnd[];   k=266; mPgUp[]; k=267; mPgDn[]
  k=258; kTab[];   k=290; setTheme[~DARK]; 0]}
doKey:{[k;m] $[modBit[m;8]; doCmd k; doEdit k]}

/ ── viewport ────────────────────────────────────────────────────────────────
scrollTo:{[t] TOP:: 0|t&(rope.rows BUF)-1}
/ Keep the caret on screen after a move (and after an edit that added lines).
follow:{[] r:row[]; $[r<TOP; scrollTo r; ~r<TOP+NVIS; scrollTo 1+r-NVIS; 0]}

/ Click → caret. Floor y to a row, round x to the nearest cell; rope.off clamps the
/ column to that line's length.
setCaret:{[x;y] r: 0|(TOP + _ (y-TOPY)%LINEH)&(rope.rows BUF)-1
  c: 0|_ 0.5+(x-(GUTW+PADX))%ADV
  CO:: rope.off[BUF;r;c]; GOAL::c}

/ ── per-frame input ─────────────────────────────────────────────────────────
/ Text and key codes are copied into VM memory (0+…) before use so nothing from the
/ C-allocated event columns is parked in a global.
/ A cmd-modified key still emits a text event on some platforms, so text events drop
/ anything typed with super held — otherwise cmd+= would zoom AND insert a '='.
procText:{[E] i: &(KTEXT=(E`kind))&~modBit[E`mods;8]; {insCh x}' 0 + (E`code)@i}
procKeys:{[E] i: &(KKEY=(E`kind))&1=(E`down); {doKey[x;y]}'[0+(E`code)@i; 0+(E`mods)@i]}
clickAt:{[E;j] setCaret[(E`x)@j; (E`y)@j]}
procMouse:{[E] m: &(KMOUSE=(E`kind))&1=(E`down); $[#m; clickAt[E; *|m]; 0]}
procScroll:{[E] s: &KSCROLL=(E`kind); $[#s; scrollTo TOP - _ +/3.*(E`amt)@s; 0]}
procAll:{[E] procText E; procKeys E; procMouse E; procScroll E; follow[]; 0}
handle:{[props] E: props`events; $[0<#E`kind; procAll E; 0]}

/ ── drawing ─────────────────────────────────────────────────────────────────
/ A line is drawn as one cnv.text per RUN of equal role: cnv.text advances the pen,
/ so the runs simply chain from the line's baseline-left origin. The run's glyphs
/ come out of a global because a lambda can't see its caller's locals.
LCP: !0
drawSeg:{[s;n;r] cnv.text[FONT; SZ; n#s_LCP; PAINTS r]}
lineY:{[r] (TOPY + ASC) + LINEH*r-TOP}
drawRow:{[r] LCP:: rope.lineAt[BUF;r]
  rl: HLR@(rope.lineStart[BUF;r])+!#LCP
  rs: syn.runs rl
  cnv.moveTo[GUTW+PADX; lineY r]
  drawSeg'[rs 0; rs 1; rs 2]}
drawNum:{[r] cnv.moveTo[PADX; lineY r]; cnv.text[FONT; SZ; `i$($r+1); GUTFG]}
drawLine:{[r] drawNum r; drawRow r}
visRows:{[] TOP+!NVIS&(rope.rows BUF)-TOP}

drawCurLn:{[w] cnv.rect[GUTW; (TOPY+LINEH*row[]-TOP)+2.*DPR; w-GUTW; LINEH]; cnv.fill CURLN}
drawCaret:{[] cnv.rect[(GUTW+PADX)+ADV*col[]; (TOPY+LINEH*row[]-TOP)+3.*DPR; 2.*DPR; LINEH-6.*DPR]
  cnv.fill CARET}
/ Status bar: caret position, document size, language, theme.
status:{[] ($1+row[]),":",($1+col[])," ",($rope.rows BUF)," lines  ",(1_$LANG),"  ",($[DARK;"dark";"light"]),"  ",($`i$SZL),"pt"}
drawFoot:{[w;h] cnv.rect[0.; h-FOOT; w; FOOT]; cnv.fill GUTBG
  cnv.moveTo[PADX; (h-FOOT)+ASC+2.*DPR]; cnv.text[FONT; SZ*0.85; `i$status[]; GUTFG]}

/ ── frame ───────────────────────────────────────────────────────────────────
run:{[props]
  syncScale props`dpr                         / retina: lay out in framebuffer px
  w: props`width
  h: props`height
  NVIS:: 1|_ (h-(TOPY+FOOT))%LINEH
  handle props
  hlSync[]
  cnv.new[]
  cnv.rect[0.; 0.; w; h]; cnv.fill BG
  cnv.rect[0.; 0.; GUTW; h]; cnv.fill GUTBG
  drawCurLn w
  drawCaret[]
  drawLine' visRows[]
  drawFoot[w;h]
  cnv.render[w;h]}

window.run[run; WINW,WINH]
