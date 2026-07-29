/ tools/lsp.k — ink language server: LSP (JSON-RPC) over stdio.
/ Entry:  lsp.run 0   → reads Content-Length framed messages from stdin and
/ writes responses to stdout until EOF or an `exit` request. Driven by `ink lsp`.
/
/ Built on the `parse` verb's CST table (parent/kind/field/start/len/value/depth).
/ NB: ink string literals cannot express CR or backslash-letter escapes (`"\r"`
/ decodes to 'r', `"\d"` to 'd'), so those bytes come from `c$<code>.
/ Lambdas do not capture parent locals — map with PROJECTION `f[ctx]'items`, not a
/ nested lambda; mutate globals with `::` in a helper (never a `[a::x;b::y]` block,
/ which is a dict literal). Raw byte IO uses the stdin/stdout handles in the runtime.
/
/ Symbol documentation comes from lib/doc.k — the same extractor `ink tools/doc.k`
/ uses for doc/api/ — so a hover popup and the published reference never diverge.

2:"lib/doc.k"

\d lsp run

cr:   `c$13
lf:   `c$10
bs:   `c$92
crlf: cr,lf
sep:  crlf,crlf

/ ── framing ────────────────────────────────────────────────────────────────
chk:  {[a;b;L] m:(L#a)&(L#1_b)&(L#2_a)&(L#3_b); $[|/m;*&m;#a]}
sepAt:{[h] a:h=cr; b:h=lf; L:(#h)-3; $[L<1;#h;chk[a;b;L]]}
clen: {[hdr] ls:crlf\hdr; b:{[l]("Content-Length:")~15#l}'ls; ln:*ls@&b; `I$ln@&(ln>"/")&(ln<":")}
frame:{[msg] `stdout 1: ("Content-Length: ",($#msg),sep,msg)}

/ ── JSON-RPC messages ──────────────────────────────────────────────────────
reply: {[id;result] frame json.gen((`jsonrpc`id`result)!("2.0";id;result))}
notify:{[method;params] frame json.gen((`jsonrpc`method`params)!("2.0";method;params))}

/ ── document store (parallel globals: uri symbol → text) ────────────────────
docU: 0#`
docT: ()
appendDoc: {[k;t] docU::docU,k; docT::docT,,t}
replaceDoc:{[i;t] docT[i]::t}
setDoc:{[u;t] k:`s$u; i:docU?k; $[i<#docU;replaceDoc[i;t];appendDoc[k;t]]}
dropDoc:{[u] k:`s$u; i:docU?k; $[i<#docU;[docU::docU _ i; docT::docT _ i];0]}
getDoc:{[u] k:`s$u; i:docU?k; $[i<#docU;docT@i;""]}

/ ── position mapping (CODEPOINT offsets, to match the parse CST) ─────────────
/ The CST records codepoint ranges but the document is a byte (char) vector, so
/ all line/column math must count codepoints, not bytes — otherwise any file with
/ multi-byte UTF-8 (arrows, ×, ≤, … in comments) desyncs every cursor position
/ past the first such byte and hover/definition/rename/refs silently return null.
/ per-byte flag: 1 where a byte starts a codepoint (not a continuation, 128..191)
cpLead:{[s] i:`i$s; ~(127<i)&i<192}
cpLen: {[s] +/cpLead s}
/ codepoint offset of each line's start.  Memoised on src identity: this is a
/ hot path (called via nrng/nsAt once per top-level bind), and its per-line
/ cpLen each was the dominant cost when indexing large files.
loSrc:""
loVal:()
lineOffsC:{[src] ls:"\n"\src; (#ls)#0,+\1+cpLen'ls}
lineOffsSet:{[src] loSrc::src; loVal::lineOffsC src; loVal}
lineOffs:{[src] $[loSrc~src;loVal;lineOffsSet src]}
/ codepoint offset → (line;col), both in codepoint units
lc:{[src;o] co:lineOffs src; line:-1+#&~co>o; (line; o-co@line)}
/ offset → LSP Position dict
pos:{[src;o] p:lc[src;o]; (`line`character)!(p 0;p 1)}
/ (start;end) offsets → LSP Range dict
rng:{[src;a;b] (`start`end)!(pos[src;a];pos[src;b])}
/ (line;character) → codepoint offset
posToOff:{[src;line;ch] os:lineOffs src; ls:"\n"\src; (os@line)+ch&cpLen ls@line}

/ ── request param accessors ─────────────────────────────────────────────────
hasKey:{[d;k] |/k=!d}
pUri: {[req] ((req`params)`textDocument)`uri}
pLine:{[req] (req`params)`position}
pOff: {[src;req] p:pLine req; posToOff[src;p`line;p`character]}

/ ── CST helpers ─────────────────────────────────────────────────────────────
/ children row indices of node i (rows whose parent = i)
kids:  {[t;i] &i=t`parent}
/ child of i whose field = f (first), or -1
childF:{[t;i;f] c:kids[t;i]; h:c@&f=(t`field)@c; $[#h;*h;-1]}
/ most-specific (smallest-span) node covering codepoint offset o, or -1
nodeAt:{[t;o] st:t`start; ln:t`len; cov:&((~o<st)&o<st+ln); $[#cov;cov@*<ln@cov;-1]}
/ name string of a var/op/term/symbol node (its interned value, backtick stripped)
nameOf:{[t;i] 1_$(t`value)@i}

/ ── namespace scan (\d directives; CST drops their args, so scan source) ─────
/ namespace active at offset o: last `\d ns` before o (""=global). `\d` alone resets.
trimL:{[s] $[(0<#s)&(*s)=" ";trimL 1_s;s]}
word1:{[s] i:s?" "; i#s}
dirNs:{[line] rest:trimL 2_line; $[0=#line;"";word1 rest]}
isDir:{[line] (1<#line)&(2#line)~bs,"d"}
/ directive table (offsets; namespaces) for the `\d` lines, memoised on src
/ identity so the per-line isDir each runs once per file, not once per bind.
ndSrc:""
ndVal:()
dtabC:{[src] ls:"\n"\src; d:&isDir'ls; ((lineOffs src)@d;dirNs'(ls@d))}
dtabSet:{[src] ndSrc::src; ndVal::dtabC src; ndVal}
dtabOf:{[src] $[ndSrc~src;ndVal;dtabSet src]}
nsAt:{[src;o]
  tab:dtabOf src
  d:&(tab 0)<o              / directives starting before o
  $[#d;(tab 1)@*|d;""]}

/ qualify a bare name with the active namespace (dotted names stay as written)
qual:{[ns;nm] $[(0<#ns)&~|/"."=nm;ns,".",nm;nm]}
/ node span (start;end) → Range
nrng:{[t;src;i] s:(t`start)@i; rng[src;s;s+(t`len)@i]}

/ ── documentSymbol ──────────────────────────────────────────────────────────
/ SymbolKind: Function=12, Variable=13
symOf:{[t;src;bi]
  vi:childF[t;bi;`v]; ai:childF[t;bi;`a]
  fqn:qual[nsAt[src;(t`start)@vi];nameOf[t;vi]]
  kind:$[((t`kind)@ai)=`lambda;12;13]
  r:nrng[t;src;vi]
  (`name`kind`range`selectionRange)!(fqn;kind;r;r)}
topBinds:{[t] &((t`kind)=`bind)&0=t`parent}
docSym:{[src] t:parse src; b:topBinds t; symOf[t;src]'b}

/ ── workspace index (cross-file top-level defs) ─────────────────────────────
/ `dir must be applied by juxtaposition (`dir p), not `@` (which doesn't route).
wroot: ""              / workspace root path
windex: ()             / list of {name;uri;range;kind} across all .k files
p2p:{[uri] $[("file://")~7#uri;7_uri;uri]}
kfiles:{[root] f:`dir root; f@&{".k"~-2#x}'f}
drecOf:{[t;src;uri;bi]
  vi:childF[t;bi;`v]; ai:childF[t;bi;`a]
  r:doc.at[doc.of[uri;src]; *lc[src;(t`start)@vi]]      / memoised per file
  (`name`uri`range`kind`doc)!(qual[nsAt[src;(t`start)@vi];nameOf[t;vi]];uri;nrng[t;src;vi];$[`lambda=(t`kind)@ai;12;13];$[`m~@r; r`summary; ""])}
fileDefs:{[path] src:1: path; t:parse src; drecOf[t;src;"file://",path]'topBinds t}
buildIndex:{[root] kf:kfiles root; windex:: $[#kf;,/{fileDefs x}'kf;()]}
winNames:{[d] {x`name}'windex}
/ first windex record whose name = target, or ` (blank) if none
winFind:{[target] nms:winNames 0; i:&target~/:nms; $[#i;windex@*i;`]}

/ ── builtin reference data (used by definition + workspace/symbol) ──────────
helpPath:"/tmp/ink-help.k"
helpUri: "file:///tmp/ink-help.k"
bsym: `s$'" "\": + - * % ! & | < > = ~ , ^ # _ $ ? @ . sqrt sqr exp log sin cos abs first last count in has mod div parse exec ' / \\ ': /: \\: 0: 1: 2: +/ */ &/ |/ *| ,/"
bdoc:("Identity/Return :x ; Right/Assign x:y";"Flip +x (transpose) ; Add x+y";"Negate -x ; Subtract x-y";"First *x ; Multiply x*y";"Divide x%y (float division)";"Iota/Odometer !x ; Key (dict) x!y";"Where &x ; Min/And x&y";"Reverse |x ; Max/Or x|y";"Ascend (grade up) <x ; Less x<y";"Descend (grade down) >x ; Greater x>y";"Group/Unit =x ; Equal x=y";"Not ~x ; Match x~y";"Enlist ,x ; Join x,y";"Null ^x ; Fill/Without x^y";"Tally #x ; Take/Reshape x#y";"Floor _x ; Drop/Cut/WeedOut/Delete x_y";"String $x ; Pad/Cast x$y";"Distinct/Uniform ?x ; Find/Roll x?y";"Type @x ; At/Apply (index) x@y";"Value/Get .x ; Dot/ApplyN (deep index) x.y";"Square root  sqrt n";"Square  sqr n";"Exponential  exp n";"Natural log  log n";"Sine  sin n";"Cosine  cos n";"Absolute value  abs n";"First  first x";"Last  last x";"Count  count x";"In (membership)  x in Y";"Has (membership)  Y has x";"Modulo  x mod y";"Integer division  x div y";"Parse source to value  parse s";"Evaluate source  exec s";"Each f'x ; Zip x F'y";"Fold/Decode/Join/N-do/While/Converge  F/";"Scan/Encode/Split/N-dos/Whiles/Converges  F\\";"Eachprior/Window/Stencil  F':x";"Eachright (fix left, map right)  x F/:y";"Eachleft (fix right, map left)  x F\\:y";"Read line 0:x ; Write line x 0:y";"Read bytes 1:x ; Write bytes x 1:y";"Load code (import file)  2:y";"Sum +/x (fused reduce)";"Product */x (fused reduce)";"Minimum / All &/x (fused reduce)";"Maximum / Any |/x (fused reduce)";"Last *|x - last element";"Raze ,/x - flatten one level")
bnm:{[i] 1_$bsym@i}
mkHelpLine:{[i] "/ ",(bnm i),"  ",bdoc@i}
buildHelp:{[d] hdr:("/ Ink builtin reference (definition / workspace-symbol target).";"/"); z:helpPath 1: "\n"/hdr,mkHelpLine'!#bsym}
/ builtin symbol → line number in the help file (header is 2 lines), or -1
hLineOf:{[sym] i:bsym?`s$sym; $[i<#bsym;2+i;-1]}
/ LocationLink[] with an explicit target line/columns
locLinkT:{[t;src;oi;uri;ln;sc;ec] tr:(`start`end)!((`line`character)!(ln;sc);(`line`character)!(ln;ec)); ,(`originSelectionRange`targetUri`targetRange`targetSelectionRange)!(nrng[t;src;oi];uri;tr;tr)}
defBuiltin:{[t;src;ni;id] sym:1_$(t`value)@ni; ln:hLineOf sym; $[ln<0;reply[id;`null];reply[id;locLinkT[t;src;ni;helpUri;ln;2;2+#sym]]]}

/ ── definition (in-file names) ──────────────────────────────────────────────
cfield:{[t;f;i] childF[t;i;f]}                 / arg order for projection over nodes
vfqn:  {[t;src;vi] qual[nsAt[src;(t`start)@vi];nameOf[t;vi]]}
/ nearest bind (its v-child index) whose fqn = target, at/before cur; else first; -1 if none
nearest:{[t;mi;cur] st:(t`start)@mi; bef:mi@&~st>cur; $[#bef;*|bef;*mi]}
findDef:{[t;src;target;cur]
  vis:cfield[t;`v]'&(t`kind)=`bind
  mi:vis@&target~/:vfqn[t;src]'vis
  $[0=#mi;-1;nearest[t;mi;cur]]}
/ a single-element LocationLink[] from origin node oi to def var node di
locLink:{[t;src;oi;di;uri]
  ,(`originSelectionRange`targetUri`targetRange`targetSelectionRange)!(nrng[t;src;oi];uri;nrng[t;src;di];nrng[t;src;di])}
/ LocationLink[] from origin node ni to a cross-file windex record w
winLink:{[t;src;ni;w] ,(`originSelectionRange`targetUri`targetRange`targetSelectionRange)!(nrng[t;src;ni];w`uri;w`range;w`range)}
/ NB: winFind returns a dict (found) or the null symbol; test by TYPE — `~`
/ between two null symbols is not 1b, so a `\`~w` blank-check silently inverts.
defCross:{[t;src;ni;rel;nm;id]
  w:$[0<#rel;winFind rel;`]
  w:$[`m~@w;w;winFind nm]
  $[`m~@w;reply[id;winLink[t;src;ni;w]];reply[id;`null]]}
defVar:{[t;src;ni;o;uri;id]
  nm:nameOf[t;ni]
  ns:nsAt[src;(t`start)@ni]
  rel:$[(0<#ns)&~|/"."=nm;ns,".",nm;""]
  di:$[0<#rel;findDef[t;src;rel;o];-1]
  di:$[di<0;findDef[t;src;nm;o];di]
  $[di<0;defCross[t;src;ni;rel;nm;id];reply[id;locLink[t;src;ni;di;uri]]]}
onDef:{[req]
  uri:pUri req; src:getDoc uri; t:parse src; o:pOff[src;req]; ni:nodeAt[t;o]
  k:$[ni<0;`;(t`kind)@ni]
  $[ni<0;reply[req`id;`null]
   ;`var~k;defVar[t;src;ni;o;uri;req`id]
   ;(`op~k)|(`io~k)|`term~k;defBuiltin[t;src;ni;req`id]
   ;reply[req`id;`null]]}

/ ── hover ───────────────────────────────────────────────────────────────────
/ verb docs (parallel to vk; "" = that valence is absent). Ported from lsp.zig.
vk: `s$'" "\": + - * % ! & | < > = ~ , ^ # _ $ ? @ . sqrt sqr exp log sin cos abs first last count in has mod div parse exec"
vmono:("**Identity / Return** `:x` — return x";"**Flip** `+x` — transpose";"**Negate** `-x`";"**First** `*x` — first item";"";"**Iota** `!i` — 0..i-1; **Odometer** `!I`";"**Where** `&I` — counts to indices";"**Reverse** `|x`";"**Ascend** `<X` — grade-up indices";"**Descend** `>X` — grade-down indices";"**Group** `=X`; **Unit** `=i` — identity matrix";"**Not** `~x` — logical negation";"**Enlist** `,x` — wrap in list";"**Null** `^x` — null mask";"**Tally** `#x` — count";"**Floor** `_x`";"**String** `$x`";"**Distinct** `?X`; **Uniform** `?i` — random floats";"**Type** `@x`";"**Value/Get** `.x`";"**Square root** `sqrt n`";"**Square** `sqr n`";"**Exponential** `exp n`";"**Natural log** `log n`";"**Sine** `sin n`";"**Cosine** `cos n`";"**Absolute value** `abs n`";"**First** `first x`";"**Last** `last x`";"**Count** `count x`";"";"";"";"";"**Parse** `parse s` — source to value";"**Exec** `exec s` — evaluate source")
vdyad:("**Right** `x:y` — return y (also assignment: `n:v`)";"**Add** `x+y`";"**Subtract** `x-y`";"**Multiply** `x*y`";"**Divide** `x%y` — float division";"**Key** `x!y` — make dictionary";"**Min/And** `x&y`";"**Max/Or** `x|y`";"**Less** `x<y`";"**Greater** `x>y`";"**Equal** `x=y`";"**Match** `x~y` — identity check";"**Join** `x,y` — concatenate / merge dicts";"**Fill** `x^y` — replace nulls; **Without** `X^y`";"**Take** `x#y` — reshape/cycle; **Reshape** `I#y`";"**Drop** `i_Y`; **Cut** `I_Y`; **WeedOut** `f_Y`; **Delete** `X_i`";"**Pad** `i$C`; **Cast** `s$y`";"**Find** `x?y`; **Roll/Deal** `i?x`";"**At/Apply** `x@y` — index / apply";"**Dot/ApplyN** `x.y` — deep index / apply";"";"";"";"";"";"";"";"";"";"";"**In** `x in Y` — membership";"**Has** `Y has x` — membership";"**Modulo** `x mod y` — remainder";"**Integer division** `x div y` — floor(x/y)";"";"")
/ i/o verbs
iok: `s$'" "\"0: 1: 2:"
iomono:("**Read line** `0:x` — read lines from stdin / a file";"**Read bytes** `1:x`";"**Load code** `2:y` — import another file")
iodyad:("**Write line** `x 0:y` — write text";"**Write bytes** `x 1:y`";"**Load code** `2:y` — import another file")
/ adverbs (pre-rendered mono / dyad markdown)
advk: `s$'" "\"' / \\ ': /: \\:"
advmono:("**Each** `f'x`";"**Fold** `F/x` · **Decode** `I/x` · **Join** `C/x` · **Converge** `f/x`";"**Scan** `F\\x` · **Encode** `I\\x` · **Split** `C\\x` · **Converges** `f\\x`";"**Eachprior** `F':x` · **Window** `i':x`";"";"")
advdyad:("**Zip** `x F'y`";"**SeededFold** `x F/y` · **N-Do** `i f/y` · **While** `f f/y`";"**SeededScan** `x F\\y` · **N-Dos** `i f\\y` · **Whiles** `f f\\y`";"**Stencil** `i f':x`";"**Eachright** `x F/:y` — fix the left arg, map over the right";"**Eachleft** `x F\\:y` — fix the right arg, map over the left")
/ fused reductions (verb glued to /)
frk: `s$'" "\"+ * & |"
frd:("**Sum** `+/x` — total of x *(fused reduce)*";"**Product** `*/x` — product of x *(fused reduce)*";"**Minimum / All** `&/x` — least element; logical all *(fused reduce)*";"**Maximum / Any** `|/x` — greatest; logical any *(fused reduce)*")

/ look up doc string in (keys;vals) parallel table by a name string; "" if absent
look:{[keys;vals;nm] i:keys?`s$nm; $[i<#keys;vals@i;""]}
sense:{[dy;m;d] $[dy;$[0<#d;d;m];$[0<#m;m;d]]}
hoverMd:{[id;md] reply[id;[contents:[kind:"markdown";value:md]]]}
/ arity from the CST: an op/term that is the verb of a `transit` has a left arg
isDyad:{[t;ni] `transit=(t`kind)@(t`parent)@ni}
isMono:{[t;ni] `apposit=(t`kind)@(t`parent)@ni}
/ fused reduce: the op's parent is a `term` whose value is `/`.
/ Match against a quoted-symbol constant (`/ is an adverb glyph, not a symbol).
slash:`"/"
fusedOf:{[t;ni] p:(t`parent)@ni; $[(`term~(t`kind)@p)&slash~(t`value)@p;look[frk;frd;1_$(t`value)@ni];""]}

hoverVerb:{[t;ni;id]
  nm:1_$(t`value)@ni
  fr:fusedOf[t;ni]
  dy:$[0<#fr;1b;isDyad[t;ni]]        / a fused reduce applies the verb dyadically
  s:sense[dy;look[vk;vmono;nm];look[vk;vdyad;nm]]
  md:$[0<#fr;$[0<#s;fr,"\n\n---\n",s;fr];s]
  $[0=#md;reply[id;`null];hoverMd[id;md]]}
hoverIo:{[t;ni;id]
  nm:1_$(t`value)@ni
  s:sense[isDyad[t;ni];look[iok;iomono;nm];look[iok;iodyad;nm]]
  $[0=#s;reply[id;`null];hoverMd[id;s]]}
hoverAdv:{[t;ni;id]
  nm:1_$(t`value)@ni
  mo:look[advk;advmono;nm]; dy:look[advk;advdyad;nm]
  md:$[isDyad[t;ni];sense[1b;mo;dy];isMono[t;ni];sense[0b;mo;dy];$[(0<#mo)&0<#dy;mo," · ",dy;mo,dy]]
  $[0=#md;reply[id;`null];hoverMd[id;md]]}
/ In-file variable hover.  lib/doc.k owns the doc-comment convention (a comment
/ block directly above a line-leading binding), so hover shows exactly what
/ `ink tools/doc.k` publishes — signature, arity/type, and the prose.  Falls
/ back to the bare "defined at line N" note for an undocumented binding.
hvVar:{[t;src;di;nm;id]
  l0:*lc[src;(t`start)@di]
  r:doc.at[doc.of["";src]; l0]
  $[`m~@r; hoverMd[id;doc.hoverMd r]; hvPlain[t;src;di;nm;id;l0]]}
hvPlain:{[t;src;di;nm;id;l0]
  bi:(t`parent)@di; ai:childF[t;bi;`a]
  kw:$[`lambda=(t`kind)@ai;"function";"variable"]
  hoverMd[id;"**",kw,"** `",nm,"` — defined at line ",$1+l0]}
/ cross-file variable hover: file + line from the workspace index, plus the
/ indexed doc summary when that binding is documented
hvCrossMd:{[w] kw:$[12=w`kind;"function";"variable"]; st:(w`range)`start; ln:1+st`line; file:*|"/"\p2p(w`uri)
  hd:"**",kw,"** `",(w`name),"` — defined in `",file,"` (line ",($ln),")"
  $[0=#(w`doc); hd; hd,"\n\n",w`doc]}
hovCross:{[rel;nm;id] w:$[0<#rel;winFind rel;`]; w:$[`m~@w;w;winFind nm]; $[`m~@w;hoverMd[id;hvCrossMd w];reply[id;`null]]}
hoverVar:{[t;src;ni;id]
  nm:nameOf[t;ni]; o:(t`start)@ni
  ns:nsAt[src;o]
  rel:$[(0<#ns)&~|/"."=nm;ns,".",nm;""]
  di:$[0<#rel;findDef[t;src;rel;o];-1]
  di:$[di<0;findDef[t;src;nm;o];di]
  $[di<0;hovCross[rel;nm;id];hvVar[t;src;di;nm;id]]}
hoverAt:{[t;src;ni;id]
  k:(t`kind)@ni
  $[k=`op;hoverVerb[t;ni;id]
   ;k=`io;hoverIo[t;ni;id]
   ;k=`term;hoverAdv[t;ni;id]
   ;k=`var;hoverVar[t;src;ni;id]
   ;reply[id;`null]]}
onHover:{[req]
  uri:pUri req; src:getDoc uri; t:parse src; o:pOff[src;req]; ni:nodeAt[t;o]
  $[ni<0;reply[req`id;`null];hoverAt[t;src;ni;req`id]]}

/ ── references / rename ─────────────────────────────────────────────────────
isName:{[t;ni] k:(t`kind)@ni; (`var~k)|`param~k}
nameNodes:{[t] ki:t`kind; &(`var=ki)|`param=ki}
/ all var/param node indices whose value = the name symbol
/ Guard the empty case: with no name nodes, `(t`value)@nn` boxes to a general
/ list `()`, so `sym=()` / `&()` yield a spurious match — return empty instead.
occurs:{[t;sym] nn:nameNodes t; $[#nn;nn@&sym=(t`value)@nn;nn]}
locOf:{[t;src;uri;i] (`uri`range)!(uri;nrng[t;src;i])}
/ other workspace .k files (excluding the current doc's own file)
otherK:{[curUri] op:p2p curUri; kf:$[0<#wroot;kfiles wroot;()]; $[#kf;kf@&~kf~\:op;()]}
/ occurrences of sym in one on-disk file → Location list
fileOccs:{[sym;path] src:1: path; t:parse src; locOf[t;src;"file://",path]'occurs[t;sym]}
/ all occurrences: current doc (live text) + every other .k file (disk)
allRefs:{[curUri;curSrc;curT;sym]
  cur:locOf[curT;curSrc;curUri]'occurs[curT;sym]
  others:otherK curUri
  op:$[#others;fileOccs[sym]'others;()]
  $[#op;,/(,cur),op;cur]}
onRefs:{[req]
  uri:pUri req; src:getDoc uri; t:parse src; o:pOff[src;req]; ni:nodeAt[t;o]
  $[ni<0;reply[req`id;!0]
   ;isName[t;ni];reply[req`id;allRefs[uri;src;t;(t`value)@ni]]
   ;reply[req`id;!0]]}
onPrep:{[req]
  uri:pUri req; src:getDoc uri; t:parse src; o:pOff[src;req]; ni:nodeAt[t;o]
  $[ni<0;reply[req`id;`null]
   ;isName[t;ni];reply[req`id;(`range`placeholder)!(nrng[t;src;ni];nameOf[t;ni])]
   ;reply[req`id;`null]]}
/ rename: build the WorkspaceEdit JSON by hand — a `{changes:{uri:[…]}}` object
/ has two single-key levels, and ink's single-key-dict indexing is unreliable.
idJson:{[id] $[`i~@id;$id;json.gen id]}
replyJson:{[id;rj] frame ("{\"jsonrpc\":\"2.0\",\"id\":",(idJson id),",\"result\":",rj,"}")}
edOf:{[t;src;new;i] (`range`newText)!(nrng[t;src;i];new)}
/ one file's `"uri":[edits]` fragment, or "" when the name doesn't occur there
fragOf:{[uri;t;src;sym;new] o:occurs[t;sym]; e:edOf[t;src;new]'o; $[#o;(json.gen uri),":",json.gen e;""]}
fileFrag:{[sym;new;path] src:1: path; t:parse src; fragOf["file://",path;t;src;sym;new]}
/ cross-file WorkspaceEdit JSON: {changes:{uri1:[…];uri2:[…]}}
renJson:{[curUri;curSrc;curT;sym;new]
  cfrag:fragOf[curUri;curT;curSrc;sym;new]
  others:otherK curUri
  ofrags:$[#others;fileFrag[sym;new]'others;()]
  frags:(,cfrag),ofrags
  frags:frags@&0<#'frags
  "{\"changes\":{",(","/frags),"}}"}
onRename:{[req]
  uri:pUri req; src:getDoc uri; t:parse src; o:pOff[src;req]; ni:nodeAt[t;o]
  new:(req`params)`newName
  $[ni<0;reply[req`id;`null]
   ;isName[t;ni];replyJson[req`id;renJson[uri;src;t;(t`value)@ni;new]]
   ;reply[req`id;`null]]}

/ ── documentHighlight (all occurrences of the name under the cursor) ─────────
/ DocumentHighlightKind.Text = 1
hlOf:{[t;src;i] (`range`kind)!(nrng[t;src;i];1)}
onHl:{[req]
  uri:pUri req; src:getDoc uri; t:parse src; o:pOff[src;req]; ni:nodeAt[t;o]
  $[ni<0;reply[req`id;!0]
   ;isName[t;ni];reply[req`id;hlOf[t;src]'occurs[t;(t`value)@ni]]
   ;reply[req`id;!0]]}

/ ── builtin reference file (definition / workspace-symbol target) ────────────
/ Primitives have no source, so on `initialize` we write a generated reference
/ file; definition-on-operator and workspace/symbol resolve builtins to a line.

/ ── workspace/symbol (builtins; user symbols added with cross-file index) ─────
winAt:{[hay;m;i] hay@i+!m}
inStr:{[hay;ndl] m:#ndl; n:1+(#hay)-m; $[n<1;0=#ndl;|/ndl~/:winAt[hay;m]'!n]}
lower:{[s] c:`i$s; `c$c+32*(~c<65)&~c>90}
wmatch:{[q;i] $[0=#q;1b;(inStr[lower bnm i;lower q])|inStr[lower bdoc@i;lower q]]}
wsymOf:{[i] nm:bnm i; e:2+#nm; (`name`kind`location)!(nm;25;(`uri`range)!(helpUri;(`start`end)!((`line`character)!(2+i;2);(`line`character)!(2+i;e))))}
uMatch:{[q;i] $[0=#q;1b;inStr[lower (windex@i)`name;lower q]]}
wsymUser:{[i] w:windex@i; (`name`kind`location)!(w`name;w`kind;(`uri`range)!(w`uri;w`range))}
onWsym:{[req] q:(req`params)`query; bi:&wmatch[q]'!#bsym; ui:&uMatch[q]'!#windex; reply[req`id;(wsymOf'bi),wsymUser'ui]}

/ ── dispatch ───────────────────────────────────────────────────────────────
caps:[textDocumentSync:1;documentSymbolProvider:1b;definitionProvider:1b;hoverProvider:1b;referencesProvider:1b;renameProvider:[prepareProvider:1b];documentHighlightProvider:1b;workspaceSymbolProvider:1b]
initResult:(`capabilities`serverInfo)!(caps;(`name`version)!("ink";"0.1.0"))

/ NB: bind side-effecting helper results to a local (u:) — a discarded
/ user-lambda call is DCE'd (its `::` global mutation would silently vanish).
/ First workspace folder's uri. `workspaceFolders` is a JSON array of objects, which
/ json.parse columnarises into a `uri`/`name`-keyed dict — so read the `uri` column
/ (or map when it stays a plain list) and take the first, rather than `(*wf)`uri`
/ (which would index a column list by a symbol → error).  See chText.
wf0:{[wf] u:$[`m=@wf;wf`uri;`M=@wf;wf`uri;{x`uri}'wf]; $[0<#u;*u;0]}
wfUri:{[p] $[hasKey[p;`workspaceFolders];wf0 p`workspaceFolders;0]}
doIndex:{[path] wroot::path; z:buildIndex path}
initRoot:{[req]
  p:req`params
  ru:$[hasKey[p;`rootUri];p`rootUri;0]
  ru:$[`C=@ru;ru;wfUri p]
  $[(`C=@ru)&0<#ru;doIndex p2p ru;0]}
onInit:{[req] z:buildHelp 0; r:initRoot req; reply[req`id;initResult]}
diag:{[uri] notify["textDocument/publishDiagnostics";(`uri`diagnostics)!(uri;!0)]}
onOpen:{[req] td:(req`params)`textDocument; u:setDoc[td`uri;td`text]; diag td`uri}
/ The full text of the latest change. `contentChanges` is a JSON array of objects,
/ which json.parse COLUMNARISES into a single `text`-keyed dict (`m`) — so `(*|ch)`text`
/ would index the text COLUMN (a list) by a symbol and yield an `!type` error, which
/ then poisons the doc store and crashes the next parse/split. Handle both shapes:
/ a columnarised dict → last of its `text` column; a plain list of change dicts →
/ the last change's `text`. (Sync is full — textDocumentSync:1 — so there is one change.)
chText:{[ch] $[`m=@ch;*|ch`text;(*|ch)`text]}
onChange:{[req] p:req`params; uri:(p`textDocument)`uri; u:setDoc[uri;chText p`contentChanges]; diag uri}
onClose:{[req] dropDoc pUri req}
onDocSym:{[req] reply[req`id; docSym getDoc pUri req]}

handle:{[b]
  req:json.parse b
  m:req`method
  $[m~"initialize";      onInit req
   ;m~"initialized";     `ok
   ;m~"shutdown";        reply[req`id;`null]
   ;m~"exit";            `exit
   ;m~"textDocument/didOpen";       onOpen req
   ;m~"textDocument/didChange";     onChange req
   ;m~"textDocument/didClose";      onClose req
   ;m~"textDocument/documentSymbol";onDocSym req
   ;m~"textDocument/definition";    onDef req
   ;m~"textDocument/hover";         onHover req
   ;m~"textDocument/references";    onRefs req
   ;m~"textDocument/prepareRename"; onPrep req
   ;m~"textDocument/rename";        onRename req
   ;m~"textDocument/documentHighlight";onHl req
   ;m~"workspace/symbol";           onWsym req
   ;$[hasKey[req;`id];reply[req`id;`null];`ok]]}

/ ── read loop (state = pending byte buffer) ────────────────────────────────
more:{[buf] d:1: `stdin; $[0=#d;`eof;buf,d]}
emit:{[buf;bs;len;need] ex:handle len#(bs _ buf); $[ex~`exit;`exit;need _ buf]}
framed:{[buf;s] len:clen s#buf; need:s+(#sep)+len; $[need>#buf;more buf;emit[buf;s+#sep;len;need]]}
step:{[buf] s:sepAt buf; $[s=#buf;more buf;framed[buf;s]]}
run:{[dummy] {(@x)=`C}step/""}

\d

/ This file IS the language-server executable: running it (`ink tools/lsp.k`, or
/ `ink lsp`) starts the JSON-RPC read loop on stdin/stdout. Bind the result to a
/ name so the loop's terminal `eof/`exit value isn't printed onto the protocol
/ stream (a bare expression statement's result is echoed by the evaluator).
done: lsp.run 0
