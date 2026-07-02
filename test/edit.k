/ test/edit.k — a tiny text editor built on the eyes.k / typeset.k GPU pipeline.
/
/ Build first:  zig build gpu && zig build font
/ Run:          ink test/edit.k
/
/ Shows three things worth reusing elsewhere:
/  1. Input as a TABLE. RunWindow hands each frame a `props`events` column dict —
/     one row per input event since the last frame. We flip it to a table (+) and
/     filter by the int `kind` column (0 text,1 key,2 mouse,3 scroll). Payload
/     columns carry 0N/0n where they don't apply. (kind is an int, not a symbol,
/     because symbol `=` is broken in ink.)
/  2. Unicode. Lines are stored as codepoint INT-vectors, not byte strings —
/     FontShape int-casts its argument, so passing codepoints renders the whole
/     Unicode cmap. Text events already deliver decoded codepoints; the `u8`
/     helper decodes UTF-8 source literals for the seed text.
/  3. Speed. Each glyph is tessellated ONCE (cached by glyph id); a frame only
/     re-lays the document when an event arrived, and idle frames redraw a cached
/     vertex buffer. As in typeset.k every draw is an explicit FillFrame and every
/     $[...] stays on one line.

2: "lib/font.k"
2: "lib/gpu.k"

FONT: (ReadFont "font/FiraCode-Regular.ttf") 0   / face 0 (FiraCode is monospaced)

/ ── Metrics / layout ─────────────────────────────────────────────────────────
SZ:     22.                        / glyph size in pixels
SCALE:  FontScale[FONT; SZ]
AV:     (FONT`hmtx)`adv            / advance widths (font units); monospace ⇒ all equal
ADV:    SCALE * AV 0               / one cell width in pixels
MET:    FontMetrics[FONT; SZ]      / (ascent; descent; lineGap), descent < 0
ASC:    MET 0
LINEH:  6. + (MET 0) - MET 1       / baseline-to-baseline pixel step
MARGIN: 18.

WINW: 760.
WINH: 480.

/ Event kinds (props`events`kind) — symbols now that symbol `=` works.
KTEXT: `text
KKEY: `key
KMOUSE: `mouse
KSCROLL: `scroll

/ ── Colours ──────────────────────────────────────────────────────────────────
BG:    gpuSolid[0.12; 0.12; 0.15; 1.]   / dark background
PEN:   gpuSolid[0.90; 0.90; 0.84; 1.]   / glyph ink
CARET: gpuSolid[0.40; 0.75; 0.95; 1.]   / cursor bar

/ ── UTF-8 → codepoints (for the seed text; typed text is already codepoints) ──
contByte: {[out;need;acc;c] a: (acc*64)+c-128; $[need=1; (out,a; 0; 0); (out; need-1; a)]}
u8step:   {[st;c] out: st 0; need: st 1; acc: st 2; $[need>0; contByte[out;need;acc;c]; c<128; (out,c; 0; 0); c<224; (out; 1; c-192); (out; 2; c-224)]}
u8:       {[s] (u8step/[(!0; 0; 0); `i$s]) 0}

/ ── Editor state ─────────────────────────────────────────────────────────────
/ The document is a list of lines; each line is an I-vector of codepoints. The
/ caret is a (row;col) pair.
LINES: u8'("The ink editor."; ""; "Type to edit — the caret follows."; "Unicode works: café, naïve, jalapeño."; "Click to place the caret; arrows move it."; "")
CR: 0                              / caret row
CC: 0                              / caret column

/ ── Geometry (verbatim from typeset.k) ───────────────────────────────────────
quad:  {[x;y;w;h] Tessellate (x,y, (x+w),y, (x+w),(y+h), x,(y+h))}
shift: {[t;ox;oy] t + ((#t) # ox,oy,0.,0.)}

/ ── Glyph cache ──────────────────────────────────────────────────────────────
/ Tessellating a glyph (Bézier flatten + triangulate) is the expensive step, so
/ do it once per glyph id and keep the local-space vertices. A cache miss appends
/ to the parallel CKEYS/CVALS globals (found via `?`); hits just reuse. Contours
/ are packed with NaN pairs so Tessellate resolves counters (holes in a,e,o,…).
CKEYS: !0                          / cached glyph ids (I)
CVALS: ()                          / their local vertex buffers (L)
/ 0.+ copies the tessellation out of the extension's C-allocated buffer into VM
/ memory, so caching it in a global is freed with the matching allocator at exit.
cacheGlyph: {[gid] cs: FontOutline[FONT; gid; SZ]; v: $[0=#cs; 0#0.; 0. + Tessellate (,/{x,0n,0n}'cs)]; CKEYS:: CKEYS,gid; CVALS:: CVALS,,v; v}
glyphLocal: {[gid] i: CKEYS?gid; $[i<#CKEYS; CVALS i; cacheGlyph gid]}

/ The current row's glyph ids and baseline live in globals so the mapped builder
/ captures no vector (a vector captured into a '-mapped projection hits the
/ runtime bug the font.k header warns about — same reason FpFont is a global).
RowGids: !0
RowBase: 0.
glyphAt:   {[i] shift[glyphLocal RowGids i; MARGIN + ADV*i; RowBase]}
lineVerts: {[r] RowGids:: FontShape[FONT; LINES r]; RowBase:: MARGIN + ASC + LINEH*r; n: #RowGids; $[0=n; 0#0.; ,/{glyphAt x}' !n]}
textVerts: {[] $[0=#LINES; 0#0.; ,/{lineVerts x}' !#LINES]}

/ Whole-document vertex buffer, rebuilt only when the frame changed something.
GLYPHS: textVerts[]

/ Caret: a thin vertical bar at (CR,CC).
caretVerts: {[] quad[MARGIN + ADV*CC; (MARGIN + LINEH*CR) + 3.; 2.; LINEH - 6.]}

/ ── Editing operations ───────────────────────────────────────────────────────
/ Every op is a named function: multi-statement bodies can't live inside a $[...]
/ branch (there `[a; b]` parses as a dict literal), so $ only dispatches. Lines
/ are I-vectors, so a codepoint inserts/splices with no char conversion.
insCh: {[cp] ln: LINES CR; LINES[CR]:: (CC#ln),cp,(CC_ln); CC:: CC+1}

kEnter: {[] ln: LINES CR; a: CC#ln; b: CC_ln; LINES:: (CR#LINES),(,a),(,b),((CR+1)_LINES); CR:: CR+1; CC:: 0}

bDel:   {[] ln: LINES CR; LINES[CR]:: ((CC-1)#ln),(CC_ln); CC:: CC-1}
bMerge: {[] pv: LINES(CR-1); cur: LINES CR; LINES:: ((CR-1)#LINES),(,pv,cur),((CR+1)_LINES); CR:: CR-1; CC:: #pv}
kBack:  {[] $[CC>0; bDel[]; CR>0; bMerge[]; 0]}

dFwd:  {[] ln: LINES CR; LINES[CR]:: (CC#ln),((CC+1)_ln)}
dJoin: {[] cur: LINES CR; nx: LINES(CR+1); LINES:: (CR#LINES),(,cur,nx),((CR+2)_LINES)}
kDel:  {[] $[CC<#(LINES CR); dFwd[]; CR<(-1+#LINES); dJoin[]; 0]}

goPrevEnd:  {[] CR:: CR-1; CC:: #(LINES CR)}
goNextStart:{[] CR:: CR+1; CC:: 0}
mLeft:  {[] $[CC>0; CC:: CC-1; CR>0; goPrevEnd[]; 0]}
mRight: {[] $[CC<#(LINES CR); CC:: CC+1; CR<(-1+#LINES); goNextStart[]; 0]}
upRow:  {[] CR:: CR-1; CC:: CC & #(LINES CR)}
dnRow:  {[] CR:: CR+1; CC:: CC & #(LINES CR)}
mUp:    {[] $[CR>0; upRow[]; 0]}
mDown:  {[] $[CR<(-1+#LINES); dnRow[]; 0]}
mHome:  {[] CC:: 0}
mEnd:   {[] CC:: #(LINES CR)}
kTab:   {[] insCh 32; insCh 32}

/ GLFW key codes → action. Printable keys arrive separately as text events, so
/ doKey only claims the editing keys and ignores everything else.
doKey: {[k] $[k=257; kEnter[]; k=259; kBack[]; k=261; kDel[]; k=263; mLeft[]; k=262; mRight[]; k=265; mUp[]; k=264; mDown[]; k=268; mHome[]; k=269; mEnd[]; k=258; kTab[]; 0]}

/ Click → caret. Round x to the nearest cell, clamp to the line; floor y to a row.
setCaret: {[x;y] r: 0 | (_ (y - MARGIN) % LINEH) & -1+#LINES; c: 0 | (_ 0.5 + (x - MARGIN) % ADV) & #(LINES r); CR:: r; CC:: c}

/ ── Per-frame input ──────────────────────────────────────────────────────────
/ Flip the events column-dict to a table, then handle each kind. Text and key
/ codes are copied into VM memory (0+…) before use so nothing from the C-allocated
/ event columns is parked in a global (see feedback_vm_allocator_ordering).
procText:  {[E] {insCh x}' 0 + (E`code)@&KTEXT=(E`kind)}
procKeys:  {[E] {doKey x}' 0 + (E`code)@&(KKEY=(E`kind))&(1=(E`down))}
/ j is the last mouse-down row; index the columns with @ (a bare `(E`x) *|m`
/ would read `*` as dyadic multiply, not monadic first).
clickAt:   {[E;j] setCaret[(E`x)@j; (E`y)@j]}
procMouse: {[E] m: &(KMOUSE=(E`kind))&(1=(E`down)); $[#m; clickAt[E; *|m]; 0]}
handle: {[props] E: props`events; n: #E; $[n>0; procAll E; 0]; n}
procAll: {[E] procText E; procKeys E; procMouse E; 0}

/ ── Frame ────────────────────────────────────────────────────────────────────
run: {[props]
  n: handle props
  $[n>0; GLYPHS:: textVerts[]; 0]     / re-lay the document only on a change
  w: props`width; h: props`height
  FillFrame[quad[0.;0.;w;h]; BG]      / background
  FillFrame[caretVerts[];    CARET]   / caret (drawn under the glyphs)
  FillFrame[GLYPHS;          PEN]}    / all glyphs in one cached draw

RunWindow[run; WINW,WINH]
