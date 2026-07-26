/ lib/syntax.k — configurable syntax highlighting.
/
/ A highlighter is a function `codepoints → role index per codepoint`. Roles are
/ names ( `num `str `dyad `assign … ), and a THEME maps every role to an rgba. Both
/ halves are swappable: register another language with `syn.reg[name; fn]`, or hand
/ `syn.setTheme` a different role→colour dict. Nothing here knows about the GPU — a
/ caller turns `syn.rgba` into whatever paint its renderer wants (see demo/edit.k).
/
/   syn.hl[`ink; cps]   → role index per codepoint
/   syn.runs rls        → (starts; lens; roles) — the runs to draw
/   syn.rgba role       → (r;g;b;a)             syn.rgbaAt idx
/   syn.setTheme t      t = syn.ROLES!rgba-list (syn.themeDark / syn.themeLight)
/
/ The ink highlighter is driven by the built-in `parse`, which returns the CST as a
/ column dict — one row per node, pre-order, with CODEPOINT ranges. That is the whole
/ trick: paint each node's range with its role and let children overwrite their
/ parents, so whatever a container node still owns afterwards is exactly its own
/ punctuation — the `[`;`]` of a call, the `:` of an assignment, the `/` of a fold.
/ `parse` is error tolerant (it returns the partial tree for half-typed source), so
/ this runs happily on every keystroke.

2: "lib/color.k"

/ ── roles ────────────────────────────────────────────────────────────────────
syn.ROLES: `text`comment`num`bool`str`sym`name`param`op`mono`dyad`over`scan`each`assign`bracket`brace`paren`cond`key`sep`cmd
syn.RTEXT:   syn.ROLES?`text
syn.RDYAD:   syn.ROLES?`dyad
syn.RMONO:   syn.ROLES?`mono
syn.RASSIGN: syn.ROLES?`assign

/ ── themes (Tailwind OKLCh via lib/color.k, tuned to match the Zed extension) ─
/ Order matches syn.ROLES:
/   text comment num bool str sym name param op mono dyad over scan each
/   assign bracket brace paren cond key sep cmd
syn.themeDark: syn.ROLES! oklch'(
  Zinc200; Slate500; Orange300; Amber300; Lime300; Teal300; Zinc200; Zinc300
  Teal300; Blue400; Purple400; Purple400; Pink400; Teal300
  Red400; Slate500; Zinc400; Zinc400; Amber300; Rose400; Slate500; Purple400 )
syn.themeLight: syn.ROLES! oklch'(
  Zinc800; Slate400; Orange700; Amber600; Lime700; Teal600; Zinc800; Zinc600
  Teal600; Blue600; Purple600; Purple600; Pink600; Teal600
  Red600; Slate400; Zinc500; Zinc500; Amber600; Rose600; Slate400; Purple600 )

syn.THEME: syn.themeDark
syn.setTheme:{[t] syn.THEME:: t}
syn.rgba:{[role] syn.THEME role}
syn.rgbaAt:{[i] syn.THEME syn.ROLES i}
syn.rgbas:{[] syn.THEME syn.ROLES}                    / every role's rgba, in role order

/ ── language registry ────────────────────────────────────────────────────────
syn.LNAME: 0#`
syn.LFN: ()
syn.reg:{[nm;f] syn.LNAME:: syn.LNAME,nm; syn.LFN:: syn.LFN,,f}
syn.plain:{[cps] (#cps)#syn.RTEXT}
syn.hl:{[nm;cps] i:syn.LNAME?nm; $[i<#syn.LNAME; (syn.LFN i)cps; syn.plain cps]}

/ ── runs: collapse a per-codepoint role vector into (starts; lens; roles) ────
syn.runs:{[rl] $[0=#rl; (!0;!0;!0); syn.runs1 rl]}
syn.runs1:{[rl] st:0,1+&~(1_rl)=-1_rl; (st; (1_st,#rl)-st; rl@st)}

/ ── codepoints → UTF-8 chars (what `parse` eats; it reports codepoint offsets) ─
syn.encCp:{[c] $[c<128; ,c
  c<2048;  (192+c div 64; 128+c mod 64)
  c<65536; (224+c div 4096; 128+(c div 64) mod 64; 128+c mod 64)
  (240+c div 262144; 128+(c div 4096) mod 64; 128+(c div 64) mod 64; 128+c mod 64)]}
syn.enc:{[cps] $[128>|/0,cps; `c$cps; `c$,/syn.encCp'cps]}
/ …and back: cut the bytes at every LEAD byte (anything but 10xxxxxx) and fold each
/ group down to its codepoint. Source literals are UTF-8, so this is what turns one
/ into buffer content.
syn.decB:{[g] c:*g; $[1=#g; c
  2=#g; ((c-192)*64)+(g 1)-128
  3=#g; (((c-224)*4096)+64*(g 1)-128)+(g 2)-128
  ((((c-240)*262144)+4096*(g 1)-128)+64*(g 2)-128)+(g 3)-128]}
/ A continuation byte is 10xxxxxx, i.e. 128..191 — spelled as a range test because `&`
/ on ints is MIN here, not a bitwise and.
syn.lead:{[b] &~(~b<128)&b<192}
syn.dec:{[s] b:`i$s; $[0=#b; b; 128>|/b; b; syn.decB'(syn.lead b)_b]}

/ ═══ the ink highlighter ═════════════════════════════════════════════════════
/ One row per CST node kind: the role its own span paints, the role its leftover
/ PUNCTUATION takes ( ( ) [ ] ; $ ), the role its leftover BRACES take ( { } ), and
/ whether it is a container at all (a leaf kind must never be char-refined, or a `[`
/ inside a string literal would come out grey).
syn.KTAB: (
  (`terse;    `text;    `sep;     `brace;   1b)
  (`transit;  `text;    `sep;     `brace;   1b)
  (`intrans;  `text;    `sep;     `brace;   1b)
  (`apposit;  `text;    `sep;     `brace;   1b)
  (`right;    `mono;    `mono;    `brace;   1b)
  (`term;     `op;      `op;      `brace;   1b)
  (`bind;     `assign;  `assign;  `assign;  1b)
  (`group;    `paren;   `paren;   `brace;   1b)
  (`list;     `paren;   `paren;   `brace;   1b)
  (`lambda;   `bracket; `bracket; `brace;   1b)
  (`apply;    `bracket; `bracket; `brace;   1b)
  (`dict;     `key;     `brace;   `brace;   1b)
  (`table;    `key;     `brace;   `brace;   1b)
  (`utable;   `key;     `brace;   `brace;   1b)
  (`cond;     `cond;    `cond;    `cond;    1b)
  (`command;  `cmd;     `cmd;     `cmd;     0b)
  (`op;       `op;      `op;      `op;      0b)
  (`io;       `op;      `op;      `op;      0b)
  (`monad;    `mono;    `mono;    `mono;    0b)
  (`blank;    `text;    `text;    `text;    0b)
  (`bool;     `bool;    `bool;    `bool;    0b)
  (`bools;    `bool;    `bool;    `bool;    0b)
  (`int;      `num;     `num;     `num;     0b)
  (`ints;     `num;     `num;     `num;     0b)
  (`float;    `num;     `num;     `num;     0b)
  (`floats;   `num;     `num;     `num;     0b)
  (`nat;      `num;     `num;     `num;     0b)
  (`nats;     `num;     `num;     `num;     0b)
  (`dbl;      `num;     `num;     `num;     0b)
  (`dbls;     `num;     `num;     `num;     0b)
  (`hlf;      `num;     `num;     `num;     0b)
  (`hlfs;     `num;     `num;     `num;     0b)
  (`string;   `str;     `str;     `str;     0b)
  (`symbol;   `sym;     `sym;     `sym;     0b)
  (`symbols;  `sym;     `sym;     `sym;     0b)
  (`var;      `name;    `name;    `name;    0b)
  (`param;    `param;   `param;   `param;   0b)
  (`comment;  `comment; `comment; `comment; 0b)
  ((`$"adverb_val"); `op; `op; `op; 0b) )

syn.KCOL:  +syn.KTAB
syn.KIND:  syn.KCOL 0
syn.KDEF:  #syn.KIND                                  / index `?` yields for any other kind
syn.KBASE: (syn.ROLES?syn.KCOL 1),syn.RTEXT
syn.KPUN:  (syn.ROLES?syn.KCOL 2),syn.RTEXT
syn.KBRC:  (syn.ROLES?syn.KCOL 3),syn.RTEXT
syn.KCON:  (syn.KCOL 4),0b
syn.KTERM:  syn.KIND?`term
syn.KAPPLY: syn.KIND?`apply

syn.PUNCTC: 40 41 91 93 59 36                          / ( ) [ ] ; $
syn.BRACEC: 123 125                                    / { }
syn.ADVC:   47 92 39                                   / / \ '
syn.ADVR:   (syn.ROLES?`over`scan`each),syn.ROLES?`op

/ A node's `value` is its literal payload for literals and its GLYPH for verbs and
/ adverbs; reduce it to that glyph's first character code (0 when it is not a symbol).
/ `$` on a symbol keeps the leading backtick, hence the 1_.
syn.gl1:{[s] $[0=#s; 0; `i$*s]}
syn.gl:{[v] $[`s~@v; syn.gl1 1_$v; 0]}
/ How many `arg children each row has (i.e. the arity of a call), per row index.
syn.argc:{[pr;fd;n] c:n#0; ai:pr@&fd=`arg; $[0=#ai; c; syn.argc1[c;ai]]}
syn.argc1:{[c0;ai] c:c0; u:?ai; c[u]:{+/x}'ai=/:u; c}
/ Paint one node's range into the per-codepoint vector; folded over every row.
syn.pnt:{[a0;e] a:a0; a[(e 0)+!e 1]:e 2; a}

syn.ink:{[cps] t:parse syn.enc cps; $[`kind in !t; syn.ink1[cps;t]; syn.plain cps]}
syn.ink1:{[cps;t]
  kn:t`kind
  fd:t`field
  vv:t`value
  pr:0|t`parent                                       / root's -1 folds onto itself
  gl:syn.gl'vv
  ki:syn.KIND?kn
  rl:syn.KBASE@ki
  pk:ki@pr                                            / parent's kind index
  pg:gl@pr                                            / parent's glyph code
  na:(syn.argc[t`parent;fd;#kn])@pr                   / arity of the call this row sits in
  / a `term` IS its adverb: +/ folds (purple), \ scans (pink), ' maps
  tm:&kn=`term
  rl[tm]:syn.ADVR@syn.ADVC?gl tm
  / a primitive's colour is its VALENCE. `v` of a transit is dyadic; `f` is monadic
  / unless it feeds a fold/scan or a call with more than one argument.
  isop:(kn=`op)|kn=`io
  dv:(pk=syn.KTERM)&(pg=47)|pg=92
  dv:dv|(pk=syn.KAPPLY)&na>1
  rl[&isop&(fd=`v)|(fd=`f)&dv]:syn.RDYAD
  rl[&isop&(fd=`f)&~dv]:syn.RMONO
  / amend @[x;i;:;v] and drill .[x;p;:;v] read as assignment, like their `:` does
  rl[&isop&(fd=`f)&(pk=syn.KAPPLY)&(na>2)&(gl=64)|gl=46]:syn.RASSIGN
  syn.ink2[cps; t`start; t`len; ki; rl]}
syn.ink2:{[cps;st;ln;ki;rl]
  n:#cps
  rows:+(st;ln;rl)
  rr:syn.pnt/[n#syn.RTEXT; rows]
  kd:syn.pnt/[n#syn.KDEF; +(st;ln;ki)]                / which node still owns each cell
  con:syn.KCON@kd
  p:&con&cps in syn.PUNCTC
  rr[p]:(syn.KPUN@kd)p
  b:&con&cps in syn.BRACEC
  rr[b]:(syn.KBRC@kd)b
  rr}

syn.reg[`ink; syn.ink]
