/ lib/lsp.k — ink language server: LSP (JSON-RPC) over stdio.
/ Entry:  lsp.run 0   → reads Content-Length framed messages from stdin and
/ writes responses to stdout until EOF or an `exit` request. Driven by `ink lsp`.
/
/ Built on the `parse` verb's CST table (parent/kind/field/start/len/value/depth).
/ NB: ink string literals cannot express CR or backslash-letter escapes (`"\r"`
/ decodes to 'r', `"\d"` to 'd'), so those bytes come from `c$<code>.
/ Lambdas do not capture parent locals — map with PROJECTION `f[ctx]'items`, not a
/ nested lambda; mutate globals with `::` in a helper (never a `[a::x;b::y]` block,
/ which is a dict literal). Raw byte IO uses the stdin/stdout handles in the runtime.

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

/ ── position mapping (codepoint offsets; k source treated as ASCII) ─────────
/ offset → (line;col)
lc:{[src;o] pre:o#src; nls:&pre=lf; $[#nls;((#nls);o-(1+*|nls));(0;o)]}
/ offset → LSP Position dict
pos:{[src;o] p:lc[src;o]; (`line`character)!(p 0;p 1)}
/ (start;end) offsets → LSP Range dict
rng:{[src;a;b] (`start`end)!(pos[src;a];pos[src;b])}
/ (line;character) → offset
lineOffs:{[src] ls:"\n"\src; (#ls)#0,+\1+#'ls}
posToOff:{[src;line;ch] os:lineOffs src; ls:"\n"\src; (os@line)+ch&#ls@line}

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
nsAt:{[src;o]
  ls:"\n"\src
  os:lineOffs src
  d:&isDir'ls               / directive line indices
  d:d@&(os@d)<o             / those starting before o
  $[#d;dirNs ls@*|d;""]}

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
defVar:{[t;src;ni;o;uri;id]
  nm:nameOf[t;ni]
  ns:nsAt[src;(t`start)@ni]
  rel:$[(0<#ns)&~|/"."=nm;ns,".",nm;""]
  di:$[0<#rel;findDef[t;src;rel;o];-1]
  di:$[di<0;findDef[t;src;nm;o];di]
  $[di<0;reply[id;`null];reply[id;locLink[t;src;ni;di;uri]]]}
onDef:{[req]
  uri:pUri req; src:getDoc uri; t:parse src; o:pOff[src;req]; ni:nodeAt[t;o]
  $[ni<0;reply[req`id;`null]
   ;`var=(t`kind)@ni;defVar[t;src;ni;o;uri;req`id]
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
/ fused reduce: the op's parent is a `term` whose value is `/`
fusedOf:{[t;ni] p:(t`parent)@ni; $[(`term=(t`kind)@p)&`/=(t`value)@p;look[frk;frd;1_$(t`value)@ni];""]}

hoverVerb:{[t;ni;id]
  nm:1_$(t`value)@ni
  fr:fusedOf[t;ni]
  s:sense[isDyad[t;ni];look[vk;vmono;nm];look[vk;vdyad;nm]]
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
hvVar:{[t;src;di;nm;id]
  ln:1+*lc[src;(t`start)@di]
  bi:(t`parent)@di; ai:childF[t;bi;`a]
  kw:$[`lambda=(t`kind)@ai;"function";"variable"]
  hoverMd[id;"**",kw,"** `",nm,"` — defined at line ",$ln]}
hoverVar:{[t;src;ni;id]
  nm:nameOf[t;ni]; o:(t`start)@ni
  ns:nsAt[src;o]
  rel:$[(0<#ns)&~|/"."=nm;ns,".",nm;""]
  di:$[0<#rel;findDef[t;src;rel;o];-1]
  di:$[di<0;findDef[t;src;nm;o];di]
  $[di<0;reply[id;`null];hvVar[t;src;di;nm;id]]}
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

/ ── dispatch ───────────────────────────────────────────────────────────────
caps:[textDocumentSync:1;documentSymbolProvider:1b;definitionProvider:1b;hoverProvider:1b]
initResult:(`capabilities`serverInfo)!(caps;(`name`version)!("ink";"0.1.0"))

/ NB: bind side-effecting helper results to a local (u:) — a discarded
/ user-lambda call is DCE'd (its `::` global mutation would silently vanish).
diag:{[uri] notify["textDocument/publishDiagnostics";(`uri`diagnostics)!(uri;!0)]}
onOpen:{[req] td:(req`params)`textDocument; u:setDoc[td`uri;td`text]; diag td`uri}
onChange:{[req] p:req`params; uri:(p`textDocument)`uri; ch:p`contentChanges; u:setDoc[uri;(*|ch)`text]; diag uri}
onClose:{[req] dropDoc pUri req}
onDocSym:{[req] reply[req`id; docSym getDoc pUri req]}

handle:{[b]
  req:json.parse b
  m:req`method
  $[m~"initialize";      reply[req`id;initResult]
   ;m~"initialized";     `ok
   ;m~"shutdown";        reply[req`id;`null]
   ;m~"exit";            `exit
   ;m~"textDocument/didOpen";       onOpen req
   ;m~"textDocument/didChange";     onChange req
   ;m~"textDocument/didClose";      onClose req
   ;m~"textDocument/documentSymbol";onDocSym req
   ;m~"textDocument/definition";    onDef req
   ;m~"textDocument/hover";         onHover req
   ;$[hasKey[req;`id];reply[req`id;`null];`ok]]}

/ ── read loop (state = pending byte buffer) ────────────────────────────────
more:{[buf] d:1: `stdin; $[0=#d;`eof;buf,d]}
emit:{[buf;bs;len;need] ex:handle len#(bs _ buf); $[ex~`exit;`exit;need _ buf]}
framed:{[buf;s] len:clen s#buf; need:s+(#sep)+len; $[need>#buf;more buf;emit[buf;s+#sep;len;need]]}
step:{[buf] s:sepAt buf; $[s=#buf;more buf;framed[buf;s]]}
run:{[dummy] {(@x)=`C}step/""}

\d
