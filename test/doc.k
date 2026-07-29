/ test/doc.k — the API-doc extractor (lib/doc.k).
/ Run: ink test/doc.k
/
/ Every case is a small synthetic module fed through doc.scan, so the visibility
/ rule ("first thing on its line, comment block directly above") and the
/ type/arity readout are pinned against source you can read next to the answer.

2:"lib/doc.k"

pass: 0
fail: 0
chkN: 0
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; {[n;g;w] fail::fail+1; `0 0:"FAIL #",($chkN)," ",n; `0 0:"  got  ",($g); `0 0:"  want ",($w)}[name;got;want]]; 0}

/ scan a source string and answer questions about it
M: ()
load: {[src] M:: doc.scan["t.k"; src]; 0}
pubN: {[z] #doc.pub M}
names:{[z] {x`name}'doc.pub M}
of:   {[nm] doc.find[M;nm]}
fld:  {[nm;k] r:doc.find[M;nm]; $[`m~@r; r@k; `absent]}

/ ── visibility ──────────────────────────────────────────────────────────────
load "/ doc\na:1\n"
chk["commented binding is public";        pubN 0; 1]
load "a:1\n"
chk["uncommented binding is private";     pubN 0; 0]
load "/ doc\n\na:1\n"
chk["blank line breaks the doc block";    pubN 0; 0]
load "/ doc\nz:0;a:1\n"
chk["binding after other code is private";pubN 0; 1]
chk["  ...and it is the FIRST one";       names 0; ,,"z"]
load "/ doc\n  a:1\n"
chk["indentation is still line-leading";  pubN 0; 1]
load "/ ── section ──────\na:1\n"
chk["a section banner is not doc";        pubN 0; 0]
load "a:1  / trailing\n"
chk["a trailing comment documents too";   pubN 0; 1]

/ ── the file header is not the first binding's doc ──────────────────────────
load "/ mod.k — a module\n/ more\n\n/ doc\na:1\n"
chk["header is split off";                #M`head; 2]
chk["title comes after the em dash";      M`title; "a module"]
chk["header does not leak into the def";  fld["a";`doc]; ,"doc"]
load "/ mod.k — a module\na:1\n"
chk["a header running into a binding documents it"; #M`head; 0]
chk["  ...and the binding is public";     pubN 0; 1]

/ ── namespaces ──────────────────────────────────────────────────────────────
load "\\d ns\n/ doc\na:1\n"
chk["\\d qualifies the name";             names 0; ,"ns.a"]
load "\\d ns b\n/ doc\na:1\n/ doc\nb:2\n"
chk["an export list hides non-members";   names 0; ,"ns.b"]

/ ── kind, type, arity, count ────────────────────────────────────────────────
load "/ d\nf:{[p;q] p}\n"
chk["lambda arity";                       fld["f";`arity]; 2]
chk["lambda params";                      fld["f";`params]; (,"p";,"q")]
chk["signature";                          fld["f";`sig]; "f[p;q]"]
load "/ d\nf:{x+y}\n"
chk["implicit x/y arity";                 fld["f";`arity]; 2]
chk["implicit params";                    fld["f";`params]; (,"x";,"y")]
load "/ d\nf:{x+{y}x}\n"
chk["a nested lambda's y is not ours";    fld["f";`arity]; 1]
load "/ d\nv:1 2 3\n"
chk["int vector type";                    fld["v";`type]; `I]
chk["int vector count";                   fld["v";`count]; 3]
load "/ d\nv:1.5 2.5\n"
chk["float vector type";                  fld["v";`type]; `F]
load "/ d\nv:`a`b`c\n"
chk["symbol vector count";                fld["v";`count]; 3]
load "/ d\nv:\"hey\"\n"
chk["string type";                        fld["v";`type]; `C]
chk["string count";                       fld["v";`count]; 3]
load "/ d\nv:(1;\"two\";`three)\n"
chk["list type";                          fld["v";`type]; `L]
chk["list count";                         fld["v";`count]; 3]
load "/ d\nv:42\n"
chk["int atom type";                      fld["v";`type]; `i]
chk["atoms have no count";                fld["v";`count]; -1]
load "/ d\nv:1+2\n"
chk["a computed value has no literal type";fld["v";`type]; `expr]
load "/ d\nv:*\n"
chk["a bare verb is a verb";              fld["v";`kind]; `verb]
load "/ d\nf:so 2:(`CFunc; 3)\n"
chk["FFI binding is a function";          fld["f";`kind]; `fn]
chk["FFI arity comes from the pair";      fld["f";`arity]; 3]
load "/ d\na::1\n"
chk["`::` binds like `:`";                pubN 0; 1]

/ ── doc text ────────────────────────────────────────────────────────────────
load "/ first line\n/ second line\nf:{[p] p}\n"
chk["whole block is kept";                fld["f";`doc]; ("first line";"second line")]
chk["summary is the first line";          fld["f";`summary]; "first line"]
chk["detail is the rest";                 fld["f";`detail]; ,"second line"]
load "// slashslash comments work\nf:{[p] p}\n"
chk["// is a comment marker too";         fld["f";`summary]; "slashslash comments work"]

/ ── degenerate inputs (each of these used to hang or miscount) ──────────────
load ""
chk["empty source";                       pubN 0; 0]
load "a:1\nb:2\n"
chk["a file with no comments at all";     pubN 0; 0]
load "/ only a comment\n"
chk["a file with no bindings";            pubN 0; 0]

`0 0:""
`0 0:($chkN)," assertions: ",($pass)," passed, ",($fail)," failed"
`0 0:$[fail=0; "ALL PASS"; "FAILURES"]
