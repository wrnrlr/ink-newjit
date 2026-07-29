/
# rope

A SumTree rope: a B-tree over text chunks, indexed by summaries.

Same shape as Zed's SumTree. Text is cut into small chunks (`rope.CH` codepoints);
the chunks are the LEAVES of a B-tree of arity `rope.B`. Every node carries a
SUMMARY of its whole subtree — here the monoid is (codepoints; newlines), which is
all a text editor needs. Because the summary is additive, a query "where is offset
9312?" or "where does row 400 start?" descends the tree in O(log n) by comparing the
running summary against the target, instead of scanning the document.

```k
rope.new cps      build from a codepoint vector      rope.text r     whole document
rope.len r        codepoints        rope.rows r      line count
rope.sub[r;a;n]   codepoints [a;a+n)                 rope.lineAt[r;row]
rope.pt[r;off]    → (row;col)       rope.lineStart[r;row] → offset
rope.ins[r;off;cps]  rope.del[r;a;n]  rope.splice[r;a;n;cps]
```

Codepoints, not bytes: offsets here are exactly the offsets the built-in `parse`
reports, so a CST range indexes straight into the buffer (see lib/syntax.k).

EDIT COST. A leaf-local edit that keeps the chunk within bounds writes one chunk and
then walks the parent chain adding the summary DELTA — O(log n), the fast path every
keystroke takes. An edit that would over/underflow a leaf (roughly one in `rope.CH`)
re-chunks and rebuilds bottom-up from the leaf list: O(#leaves), all vectorised, and
it re-uses the untouched chunk vectors by reference rather than copying text.

A rope is a plain LIST, not a dict: replacing a general-list value inside a dict
mis-amends (it drills into the value), so column storage rides on list slots, which
amend cleanly at any depth and any length.

Pure k — loads on the first reference to any `rope.*` name.
\

rope.CH:   64        / target chunk size, codepoints
rope.MAXC: 128       / a leaf splits once it grows past this
rope.B:    8         / branching factor

/ Slot layout of a rope value.
rope.KID: 0          / L  child node ids per node (empty ⇒ the node is a leaf)
rope.TXT: 1          / L  leaf codepoints (empty for interior nodes)
rope.CNT: 2          / I  summary: codepoints in the subtree
rope.NL:  3          / I  summary: newlines in the subtree
rope.PAR: 4          / I  parent node id, -1 at the root
rope.RT:  5          / i  root node id
rope.LV:  6          / I  leaf node ids, in document order

/ ── chunking ─────────────────────────────────────────────────────────────────
rope.nlOf:{[t] +/t=10}                                        / newlines in a chunk
/ Cut v into pieces of n. `_` cut takes the START index of every piece (so the list
/ must begin at 0, else the head is dropped); a v of n or fewer is one piece.
rope.cut:{[n;v] $[~n<#v; ,v; (n*!((#v)+n-1) div n) _ v]}
rope.chunks:{[cp] $[0=#cp; ,0#0; rope.cut[rope.CH;cp]]}
rope.grp:{[v] rope.cut[rope.B;v]}

/ ── build (bottom-up: one whole tree level per step) ─────────────────────────
/ st = (kid; txt; cnt; nl; cur) where cur is the id vector of the level just built.
rope.blvl:{[st] kid:st 0; txt:st 1; cnt:st 2; nl:st 3; g:rope.grp st 4; b:#cnt
  (kid,g; txt,(#g)#,0#0; cnt,{+/x}'cnt@g; nl,{+/x}'nl@g; b+!#g)}
rope.build:{[st] $[1<#st 4; rope.build rope.blvl st; st]}
/ Parent column: node i is the parent of each of its kids, so scatter i (repeated by
/ its child count) into par at the child ids.
rope.parOf:{[kid] n:#kid; par:n#-1; fl:,/kid; par[fl]:,/(#'kid)#'!n; par}
rope.fromChunks:{[ch0] ch:rope.dropEmpty ch0; nc:#ch
  st: rope.build((nc#,0#0); ch; #'ch; rope.nlOf'ch; !nc)
  ((st 0); (st 1); (st 2); (st 3); rope.parOf st 0; *st 4; !nc)}
rope.dropEmpty:{[ch] k:ch@&0<#'ch; $[0=#k; ,0#0; k]}
rope.new:{[cp] rope.fromChunks rope.chunks cp}

/ ── summaries at the root ────────────────────────────────────────────────────
rope.len:{[r] (r 2)@r 5}
rope.nlines:{[r] (r 3)@r 5}
rope.rows:{[r] 1+rope.nlines r}
rope.text:{[r] ,/(r 1)@r 6}
rope.leaf:{[r;n] 0=#(r 0)@n}

/ ── descent by the codepoint summary ─────────────────────────────────────────
/ Pick the child whose running count still covers the target: the LAST prefix entry
/ that is ≤ the target. `a` is the prefix, one longer than the child vector, so the
/ index is clamped to the last child (that is what puts an end-of-text offset on the
/ final leaf rather than off the end).
/ Descents are written as plain recursion, not as `cond body/ seed`: a while whose
/ result is then consumed (`g c f/ x`) re-reads as a train and loops forever, and a
/ converge would have to `~`-compare the whole rope every step.
rope.pick:{[a;o;m] (m-1)&-1++/~a>o}
rope.desc:{[r;n;o] ks:(r 0)@n; $[0=#ks; (n;o); rope.desc1[r;ks;o]]}
rope.desc1:{[r;ks;o] a:0,+\(r 2)@ks; j:rope.pick[a;o;#ks]; rope.desc[r;ks j;o-a j]}
rope.find:{[r;off] rope.desc[r;r 5;off]}                       / → (leaf; localOff)

/ ── descent by the newline summary → the offset a row starts at ──────────────
/ Carries (newlines still to skip; codepoints passed on the way down).
rope.ndesc:{[r;n;k;acc] ks:(r 0)@n; $[0=#ks; (n;k;acc); rope.ndesc1[r;ks;k;acc]]}
/ `+/` over an EMPTY vector is not 0 here, so every running total seeds with 0,.
rope.ndesc1:{[r;ks;k;acc] a:0,+\(r 3)@ks; j:rope.pick[a;k;#ks]
  rope.ndesc[r; ks j; k-a j; acc++/0,j#(r 2)@ks]}
rope.lsAt:{[r;s] ps:&10=(r 1)@s 0; $[(s 1)<#ps; 1+(s 2)+ps s 1; rope.len r]}
rope.lsGo:{[r;k] rope.lsAt[r; rope.ndesc[r;r 5;k;0]]}
rope.lineStart:{[r;row] $[row<1; 0; rope.lsGo[r;row-1]]}

/ ── offset → (row;col) ───────────────────────────────────────────────────────
rope.pdesc:{[r;n;o;na] ks:(r 0)@n; $[0=#ks; (n;o;na); rope.pdesc1[r;ks;o;na]]}
rope.pdesc1:{[r;ks;o;na] a:0,+\(r 2)@ks; j:rope.pick[a;o;#ks]
  rope.pdesc[r; ks j; o-a j; na++/0,j#(r 3)@ks]}
rope.rowOf:{[r;off] s:rope.pdesc[r;r 5;off;0]; (s 2)+rope.nlOf (s 1)#(r 1)@s 0}
rope.pt:{[r;off] rw:rope.rowOf[r;off]; (rw; off-rope.lineStart[r;rw])}
rope.off:{[r;row;col] a:rope.lineStart[r;row]; a+col&rope.lineLen[r;row]}

/ ── range read ───────────────────────────────────────────────────────────────
/ Leaf order + the per-leaf prefix pins the first and last leaf the range touches;
/ everything between is joined and then trimmed. (`n#v` cycles when n exceeds #v, so
/ the take is clamped.)
rope.sub:{[r;a0;n0] a:0|a0&rope.len r; n:0|n0&(rope.len r)-a
  tx:(r 1)@r 6; off:0,+\#'tx; m:#tx
  i:rope.pick[off;a;m]; j:rope.pick[off;a+n;m]
  blk:(a-off i)_,/tx@i+!1+j-i
  (n&#blk)#blk}
rope.lineEnd:{[r;row] $[row<rope.nlines r; -1+rope.lineStart[r;row+1]; rope.len r]}
rope.lineAt:{[r;row] a:rope.lineStart[r;row]; rope.sub[r;a;(rope.lineEnd[r;row])-a]}
rope.lineLen:{[r;row] (rope.lineEnd[r;row])-rope.lineStart[r;row]}

/ ── edits ────────────────────────────────────────────────────────────────────
/ Fast path: the whole replaced range lives in one leaf and the leaf stays a sane
/ size ⇒ rewrite that chunk and push the summary delta up the parent chain.
rope.bump:{[r;n;dc;dn] $[n<0; r; rope.bump1[r;n;dc;dn]]}
rope.bump1:{[r0;n;dc;dn] r:r0; r[2;n]+:dc; r[3;n]+:dn; rope.bump[r;(r 4)@n;dc;dn]}
rope.fast:{[r0;lf;nt] r:r0; t:(r 1)@lf; r[1;lf]:nt
  rope.bump[r; lf; (#nt)-#t; (rope.nlOf nt)-rope.nlOf t]}
/ Slow path: splice across the leaf list, re-chunk the touched span, rebuild.
rope.slow:{[r;a;n;cps] tx:(r 1)@r 6; off:0,+\#'tx; m:#tx
  i:rope.pick[off;a;m]; j:rope.pick[off;a+n;m]
  mid:((a-off i)#tx i),cps,((a+n)-off j)_tx j
  rope.fromChunks (i#tx),(rope.chunks mid),(j+1)_tx}
rope.fits:{[t;lo;n;cps] k:(#t)+(#cps)-n; (~(lo+n)>#t)&(0<k)&k<1+rope.MAXC}
rope.splice:{[r;a0;n0;cps] a:0|a0&rope.len r; n:0|n0&(rope.len r)-a
  d:rope.find[r;a]; lf:d 0; lo:d 1; t:(r 1)@lf
  $[rope.fits[t;lo;n;cps]; rope.fast[r;lf;(lo#t),cps,(lo+n)_t]; rope.slow[r;a;n;cps]]}
rope.ins:{[r;off;cps] rope.splice[r;off;0;cps]}
rope.del:{[r;a;n] rope.splice[r;a;n;0#0]}
