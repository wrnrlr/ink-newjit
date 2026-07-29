/
# doc

Extracts an API reference from ink source, off the parse CST.

One shared extractor sits behind `ink doc` (tools/doc.k), the language server's
hover (tools/lsp.k) and the static site build, so the published reference, the
editor popup and the website can never drift apart.  Everything is read off the
`parse` CST table rather than guessed at with a regex.

## Doc visibility

This is a doc/lsp concept — the language itself is unaffected.  A top-level
binding is PUBLIC when both hold:

- it starts its own line (indentation is fine; the `b` in `a:1;b:2` is not), and
- a comment block sits directly above it, with no blank line in between.

Everything else is private and is never listed.  A `\d ns a b` export list still
wins: a member it hides stays private no matter how well commented.  An aligned
trailing comment (`read: … / what it does`) documents the binding too.

## Module headers

A header is a block comment holding markdown — a lone `/` opens it, a lone `\`
closes it, and its first heading names the module.  A run of `/` lines still
works; the title is then the text after the em dash.

## Entry points

```k
doc.file "lib/http.k"     / → module dict
doc.scan[path; src]       / same, from source you already hold (the lsp path)
doc.find[m; "http.get"]   / one def dict, or ` when absent
doc.at[m; line]           / the def bound on `line` (0-based), or `
```

The module dict is `` `path`mod`title`summary`head`body`defs ``:

| key | meaning |
| --- | --- |
| `head` | the leading comment, as lines (markers stripped, markdown kept) |
| `body` | `head` without its `# title` heading |
| `summary` | the body's lead line, for an index row or a tooltip |
| `defs` | every top-level binding, in source order |

Each def carries `name` (fully qualified), `kind` (`` `fn `verb `val ``), `type`
(`` i f b c s C I F B S L m M ``, or `` `fn `verb `expr ``), `arity` (parameters
of a function, implicit `x`/`y`/`z` counted, else -1), `params`, `count`
(elements of a literal vector/list/dict, else -1), `line` (0-based), `public`,
`doc` / `summary` / `detail`, and `sig`.

Pure k — loads on the first reference to any `doc.*` name.
\

doc.BS:  `c$92
doc.TAB: `c$9

/ ── codepoint helpers (the CST records CODEPOINT offsets, not bytes) ─────────
doc.cpLead:{[s] i:`i$s; ~(127<i)&i<192}
doc.cpLen: {[s] +/doc.cpLead s}
doc.cpTake:{[s;n] $[n<1; ""; s@&~(+\doc.cpLead s)>n]}

/ ── per-file state (lambdas cannot close over locals, so the scan hangs its
/ ── working set on globals and every helper reads them back) ────────────────
doc.LNS:  ()      / source split into lines
doc.LO:   0#0     / codepoint offset of each line start
doc.T:    ()      / the parse CST table
doc.CI:   0#0     / row index of each comment, ascending by offset
doc.CS:   0#0     /   its start offset
doc.CL:   0#0     /   its first line
doc.CE:   0#0     /   its last line (block comments span many)
doc.COWN: 0#0     /   1b when it is the first thing on its line
doc.DL:   0#0     / line of each `\d` directive
doc.DNS:  ()      /   the namespace it opens ("" = global)
doc.DEX:  ()      /   its export list (() = everything is exported)
doc.BL:   0#0     / line of each top-level binding
doc.HEADN:0       / number of leading comment lines claimed as the file header

/ ── small utilities ─────────────────────────────────────────────────────────
/ Join with a SINGLE-char separator: a one-char string is a char ATOM, and `C/x`
/ needs a char vector — so every separator has to be enlisted first.
doc.NL:  ,"\n"
doc.SEMI:,";"
doc.join: {[sep;xs] $[0=#xs; ""; sep/xs]}
doc.lines:{[xs] doc.join[doc.NL;xs]}
doc.words: {[s] w:" "\s; w@&0<#'w}
/ `~` distinguishes a 1-char ATOM from a 1-element char VECTOR (both print as a
/ 1-char string), so string equality goes through length + elementwise compare.
doc.allEq:{[a;b] $[0=#a; 1b; &/a=b]}
doc.streq: {[a;b] $[(#a)=#b; doc.allEq[a;b]; 0b]}
/ NB `f[;v]` does NOT fix the second argument — it binds v to the FIRST one, so
/ anything projected over an each must take its fixed argument first.
doc.hasNm: {[ns;nm] $[0=#ns; 0b; |/doc.streq[nm]'ns]}
doc.blankStr:{[s] $[0=#s; 1b; &/(s=" ")|s=doc.TAB]}
doc.nlines:{[s] +/s="\n"}         / how many lines a chunk of text spans, minus 1
doc.lineAt:{[o] -1+#&~doc.LO>o}
/ A comment node's text → its content LINES.
/   `/ foo`   → ,"foo"           the marker and one following space go
/   `//foo`   → ,"foo"
/   `/\n…\n\` → the inner lines VERBATIM (a block comment holds markdown, so
/                indentation, fences and blank lines all have to survive)
/ The text always starts with "/" (it came from a comment node), so only the
/ doubled form needs a test — and `2#"/"` cycles to "//", which folds the
/ bare-"/" divider line in too.
doc.ctext:{[s] $[doc.isBlock s; doc.blockBody s; ,doc.lineText s]}
doc.isBlock:{[s] ("/\n")~2#s}
doc.blockBody:{[s] ls:"\n"\s; doc.dropClose 1_ls}
doc.dropClose:{[ls] $[0=#ls; ls; doc.streq[*|ls; ,doc.BS]; -1_ls; ls]}
doc.lineText:{[s] u:$[("//")~2#s; 2_s; 1_s]
  $[(0<#u)&(*u)=" "; 1_u; u]}
/ is `line` the first thing on its line?  o is a codepoint offset.
doc.ownLine:{[o] l:doc.lineAt o; doc.blankStr doc.cpTake[doc.LNS@l; o-doc.LO@l]}

/ ── CST helpers ─────────────────────────────────────────────────────────────
doc.kids:  {[t;i] &i=t`parent}
doc.childF:{[t;i;f] c:doc.kids[t;i]; h:c@&f=(t`field)@c; $[#h;*h;-1]}
doc.nameOf:{[t;i] 1_$(t`value)@i}
doc.topBinds:{[t] &((t`kind)=`bind)&0=t`parent}
/ the bound value; `name::v` wraps it in a `right` node, so step through that
doc.valNode:{[t;bi] ai:doc.childF[t;bi;`a]
  $[ai<0; -1; `right~(t`kind)@ai; doc.childF[t;ai;`clause]; ai]}
/ end row (exclusive) of node i's subtree — the CST is pre-order, so the
/ subtree runs until the next row at the same or a shallower depth
doc.subEnd:{[t;i] d:(t`depth)@i; n:#t`depth; j:i+1+!n-i+1
  k:j@&~((t`depth)@j)>d; $[#k;*k;n]}
/ nearest enclosing lambda row of i, or -1
doc.owner:{[t;i] p:(t`parent)@i; $[p<1; -1; `lambda~(t`kind)@p; p; doc.owner[t;p]]}

/ ── type / arity of a bound value ───────────────────────────────────────────
doc.KK:`int`float`bool`char`symbol`string`ints`floats`bools`chars`symbols`list`dict`table`utable`lambda`op`term
doc.KT:   `i`f    `b   `c  `s     `C     `I  `F     `B   `C    `S      `L  `m   `M    `M     `fn    `verb`verb
doc.ktype:{[k] i:doc.KK?k; $[i<#doc.KK; doc.KT@i; `expr]}
doc.typeOf:{[t;vi] $[vi<0; `expr; doc.ktype (t`kind)@vi]}
doc.kindOf:{[ty] $[ty~`fn; `fn; ty~`verb; `verb; `val]}

doc.VEC:`ints`floats`bools`chars`symbols
doc.countOf:{[t;vi]
  $[vi<0; -1
   ; `list~(t`kind)@vi;   #doc.kids[t;vi]
   ; `dict~(t`kind)@vi;   #doc.kids[t;vi]
   ; `string~(t`kind)@vi; #doc.sym[(t`value)@vi]   / the literal is interned; drop its backtick
   ; doc.vecCount[t;vi]]}
doc.vecCount:{[t;vi] k:(t`kind)@vi; $[(doc.VEC?k)<#doc.VEC; #(t`value)@vi; -1]}

/ implicit x/y/z params: vars in the lambda's own subtree (not a nested one)
doc.XYZ:,'"xyzuvw"
doc.argNames:{[n] $[n<1; (); n<1+#doc.XYZ; doc.XYZ@!n; doc.numArgs n]}
doc.numArgs: {[n] {"a",$1+x}'!n}
doc.implicitN:{[ns] $[doc.hasNm[ns;doc.XYZ 2];3; doc.hasNm[ns;doc.XYZ 1];2; doc.hasNm[ns;doc.XYZ 0];1; 0]}
doc.implicit:{[t;li] e:doc.subEnd[t;li]; r:li+1+!e-li+1
  vs:r@&`var=(t`kind)@r
  ns:$[#vs; doc.nameOf[t]'vs@&li=doc.owner[t]'vs; ()]
  doc.argNames doc.implicitN ns}
doc.lamParams:{[t;li] c:doc.kids[t;li]; p:c@&`param=(t`kind)@c
  $[#p; doc.nameOf[t]'p; doc.implicit[t;li]]}
doc.paramsOf:{[t;vi] $[vi<0; (); `lambda~(t`kind)@vi; doc.lamParams[t;vi]; ()]}

/ an FFI binding — `name: so 2:(`CSymbol; nargs)` — is a function too, and the
/ literal in the pair is its exact arity.  -1 when the shape does not match.
doc.ffiArity:{[t;vi] $[vi<0; -1; ~`transit~(t`kind)@vi; -1; doc.ffiVerb[t;vi]]}
doc.ffiVerb:{[t;vi] v:doc.childF[t;vi;`v]
  $[v<0; -1; ~`io~(t`kind)@v; -1; ~doc.streq[doc.nameOf[t;v];"2:"]; -1; doc.ffiPair[t;vi]]}
doc.ffiPair:{[t;vi] b:doc.childF[t;vi;`b]
  $[b<0; -1; ~`list~(t`kind)@b; -1; doc.ffiN[t;b]]}
doc.ffiN:{[t;b] c:doc.kids[t;b]
  $[2>#c; -1; ~`int~(t`kind)@c 1; -1; (t`value)@c 1]}

/ ── namespaces (`\d` args are dropped from the CST, so scan the lines) ──────
doc.isDir:{[l] (1<#l)&(2#l)~doc.BS,"d"}
doc.dirNs:{[w] $[1<#w; w 1; ""]}
doc.dirEx:{[w] $[2<#w; 2_w; ()]}
doc.nsAt:{[ln] d:&doc.DL<ln; $[#d; doc.DNS@*|d; ""]}
doc.exAt:{[ln] d:&doc.DL<ln; $[#d; doc.DEX@*|d; ()]}
doc.qual:{[ns;nm] $[(0<#ns)&~|/"."=nm; ns,".",nm; nm]}
doc.exOk:{[ln;nm] ex:doc.exAt ln; $[0=#ex; 1b; doc.hasNm[ex;nm]]}

/ ── comment blocks ──────────────────────────────────────────────────────────
/ A comment node is either a `/` line or a whole `/ … \` BLOCK spanning many
/ lines, so lookups key off the line the comment ENDS on and walking upwards
/ resumes from the line it STARTS on.  The empty-file guard is not decoration:
/ with no comments at all `&(()=l)&()` yields a 1-element result and blkDown
/ recurses forever (lib/agent.k hung on exactly this).
doc.cmtAt:{[l] $[0=#doc.CI; -1; doc.cmtHit l]}
doc.cmtHit:{[l] h:&(doc.CE=l)&doc.COWN; $[#h; doc.CI@*h; -1]}
doc.cval: {[i] (doc.T`value)@i}
doc.cstart:{[i] doc.CL@doc.CI?i}                 / first line of comment row i
/ a section-divider comment (`/ ── hover ────`) separates code, it does not
/ document the next binding — treat it like a blank line and stop the block.
/ Both the pure rule (`/ ─────────`) and the banner (`/ ── hover ───────`) count:
/ a line fenced by rule characters at BOTH ends is a section heading.
doc.DIVC:"-=_*~+#. ",`c$226 148 128 149 129 130 131
doc.allDiv:{[s] $[0=#s; 0b; &/s in doc.DIVC]}
doc.nosp:  {[s] s@&~s=" "}
doc.isDiv: {[s] u:doc.nosp s; $[3>#u; 0b; doc.allDiv u; 1b; doc.allDiv[2#u]&doc.allDiv[-2#u]]}
/ contiguous own-line comments ending at line l, walking upwards
doc.blkUp:{[l;acc] i:$[l<doc.HEADN; -1; doc.cmtAt l]
  $[i<0; acc; doc.blkStep[i; doc.ctext doc.cval i; acc]]}
doc.blkStep:{[i;ls;acc] $[doc.isDiv doc.join[" ";ls]; acc; doc.blkUp[-1+doc.cstart i; ls,acc]]}
doc.blockAbove:{[ln] doc.blkUp[ln-1; ()]}
/ the own-line comment STARTING at line l, or -1
doc.cmtFrom:{[l] $[0=#doc.CI; -1; doc.cmtFromHit l]}
doc.cmtFromHit:{[l] h:&(doc.CL=l)&doc.COWN; $[#h; doc.CI@*h; -1]}
doc.cend:{[i] doc.CE@doc.CI?i}                   / last line of comment row i
/ contiguous own-line comments starting at line l, walking downwards.  One block
/ comment covers the whole header on its own; a run of `/` lines takes several.
doc.blkDown:{[l;acc] i:doc.cmtFrom l
  $[i<0; acc; doc.blkDown[1+doc.cend i; acc,doc.ctext doc.cval i]]}
doc.blkEnd: {[l] i:doc.cmtFrom l; $[i<0; l; doc.blkEnd[1+doc.cend i]]}
/ a trailing comment on the binding's own line (after the name), or ""
doc.trailAt:{[ln;o] $[0=#doc.CI; ""; doc.trailHit[ln;o]]}
doc.trailHit:{[ln;o] h:&(doc.CL=ln)&(~doc.COWN)&doc.CS>o
  $[#h; doc.join[" ";doc.ctext doc.cval doc.CI@*h]; ""]}

/ ── one definition ──────────────────────────────────────────────────────────
doc.sigOf:{[nm;kd;ps] $[~kd~`fn; nm; 0=#ps; nm,"[]"; nm,"[",doc.join[doc.SEMI;ps],"]"]}
doc.defAt:{[bi]
  t:doc.T
  vi:doc.childF[t;bi;`v]
  o:(t`start)@vi
  ln:doc.lineAt o
  nm:doc.nameOf[t;vi]
  vn:doc.valNode[t;bi]
  ty0:doc.typeOf[t;vn]
  fa:$[ty0~`fn; -1; doc.ffiArity[t;vn]]      / FFI bindings are functions too
  ty:$[fa<0; ty0; `fn]
  kd:doc.kindOf ty
  ps:$[fa<0; doc.paramsOf[t;vn]; doc.argNames fa]
  blk:doc.blockAbove ln
  tr:doc.trailAt[ln;o]
  txt:$[(0=#blk)&0<#tr; ,tr; blk]
  fq:doc.qual[doc.nsAt ln; nm]
  pub:doc.ownLine[o] & (0<#txt) & doc.exOk[ln;nm]
  (`name`kind`type`arity`params`count`line`public`doc`summary`detail`sig)!(
    fq; kd; ty; $[kd~`fn; #ps; -1]; ps; doc.countOf[t;vn]; ln; pub
    ; txt; $[#txt; *txt; ""]; $[#txt; 1_txt; ()]; doc.sigOf[fq;kd;ps])}

/ ── scan a whole file ───────────────────────────────────────────────────────
doc.modOf:{[path] f:*|"/"\path; $[".k"~-2#f; -2_f; f]}
doc.trimS:{[s] $[(0<#s)&(*s)=" "; doc.trimS 1_s; s]}
doc.nonEmpty:{[ls] $[0=#ls; ls; ls@&0<#'ls]}   / `&` over an each-of-nothing errors

/ Title of a header block.  The modern form is a markdown block comment whose
/ first heading names the module (`# audio`); the legacy line-comment form reads
/ `lib/http.k — HTTP client`, so fall back to the text after the em dash.
doc.DASH:`c$226 128 148          / U+2014 EM DASH, as its three UTF-8 bytes
doc.HASH:,"#"
doc.titleOf:{[head] ls:doc.nonEmpty head
  $[0=#ls; ""; doc.isH1[*ls]; doc.trimS 1_*ls; doc.afterDash[*ls]]}
doc.isH1:{[s] doc.streq[1#s; doc.HASH] & ~doc.streq[2#s; "##"]}
doc.afterDash:{[s] w:doc.DASH\s
  $[1<#w; doc.trimS doc.join[doc.DASH;1_w]; doc.trimS s]}
/ Header prose WITHOUT its `# title` heading — the renderer supplies its own.
doc.bodyOf:{[head] ls:doc.nonEmpty head
  $[0=#ls; head; doc.isH1[*ls]; doc.afterH1 head; head]}
doc.afterH1:{[head] h:&doc.isH1'head; doc.trimBlank (1+*h)_head}
doc.trimBlank:{[ls] $[0=#ls; ls; 0<#*ls; ls; doc.trimBlank 1_ls]}
/ one-line description for an index or a tooltip: the body's lead line (write the
/ first line under the heading as one sentence), falling back to the title
doc.leadOf:{[body;title] ls:doc.nonEmpty body; $[#ls; *ls; title]}

doc.scan:{[path;src]
  doc.LNS::"\n"\src
  doc.LO:: (#doc.LNS)#0,+\1+doc.cpLen'doc.LNS
  doc.T::  parse src
  ci:&`comment=doc.T`kind
  doc.CI::ci
  doc.CS::(doc.T`start)@ci
  doc.CL::doc.lineAt'doc.CS
  doc.CE::doc.CL+doc.nlines'(doc.T`value)@ci
  doc.COWN::doc.ownLine'doc.CS
  di:&doc.isDir'doc.LNS
  dw:doc.words'doc.LNS@di
  doc.DL::di
  doc.DNS::doc.dirNs'dw
  doc.DEX::doc.dirEx'dw
  b:doc.topBinds doc.T
  doc.BL::doc.lineAt'(doc.T`start)@doc.childF[doc.T]'[b;`v]
  doc.HEADN::0
  hd:doc.blkDown[0;()]             / the comment run the file OPENS with
  nx:doc.blkEnd 0                  / first line after it
  / a comment that runs straight into a binding documents THAT binding, it is
  / not the file header
  doc.HEADN::$[doc.hasLine[doc.BL;nx]; 0; nx]
  hd:$[0<doc.HEADN; hd; ()]
  ds:doc.defAt'b
  ti:doc.titleOf hd
  bd:doc.bodyOf hd
  (`path`mod`title`summary`head`body`defs)!(
    path; doc.modOf path; ti; doc.leadOf[bd;ti]; hd; bd; ds)}
doc.hasLine:{[bl;l] |/bl=l}

doc.file:{[path] doc.scan[path; 1: path]}

/ Memoised on source identity.  Hover fires on every mouse move, so the language
/ server must not re-parse a 2000-line module each time.
doc.MSRC:""
doc.MVAL:()
doc.of:   {[path;src] $[doc.streq[doc.MSRC;src]; doc.MVAL; doc.ofSet[path;src]]}
doc.ofSet:{[path;src] doc.MSRC::src; doc.MVAL::doc.scan[path;src]; doc.MVAL}

/ ── lookups (the lsp side) ──────────────────────────────────────────────────
/ every one of these guards the empty case: `&` over an each-of-nothing yields a
/ spurious single index, which would report one public def in an empty module
doc.pub:  {[m] d:m`defs; $[0=#d; (); d@&{x`public}'d]}
doc.find: {[m;nm] d:m`defs; $[0=#d; `; doc.pick[d;&doc.isNm[nm]'d]]}
doc.at:   {[m;ln] d:m`defs; $[0=#d; `; doc.pick[d;&doc.isLn[ln]'d]]}
doc.isNm: {[nm;r] doc.streq[nm;r`name]}
doc.isLn: {[ln;r] ln=r`line}
doc.pick: {[d;h] $[#h; d@*h; `]}
/ markdown a hover popup can render straight into its `value` field
doc.hoverMd:{[r] hd:"```k\n",(r`sig),"\n```\n\n",doc.typeLine r
  $[0=#(r`doc); hd; hd,"\n\n",doc.lines[r`doc]]}
doc.typeLine:{[r] n:r`arity; c:r`count; ty:doc.sym[r`type]
  $[(r`kind)~`fn;   "*function, ",($n)," arg",doc.plural[n],"*"
  ; (r`kind)~`verb; "*verb*"
  ; c<0;            "*",ty,"*"
  ;                 "*",ty,", ",($c)," item",doc.plural[c],"*"]}
doc.plural:{[n] $[1=n; ""; "s"]}
/ symbol → plain string (`$` keeps the leading backtick)
doc.sym:{[s] 1_$s}
