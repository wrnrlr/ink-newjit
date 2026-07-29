/ tools/doc.k — generate the API reference from ink source.
/
/ Usage:
/   ink tools/doc.k                    regenerate doc/api/ + doc/api.md from lib/*.k
/   ink tools/doc.k -o out lib/http.k  write out/http.md for one module
/   ink tools/doc.k -check             report undocumented modules; exit != 0
/   ink tools/doc.k -print lib/http.k  dump one module's markdown to stdout
/
/ The extraction itself lives in lib/doc.k, which the language server and the
/ static site build share — the docs, hover popups and the site all agree
/ because they read the same CST.
/
/ Output is one markdown file per module with a YAML front matter block that
/ carries the machine-readable symbol table (name/sig/kind/type/arity/count),
/ so downstream tooling never has to re-parse the prose.
/
/ The tool's own names live in `kdoc` rather than `doc`: defining a NEW member
/ of an already-loaded autoloadable namespace re-runs the autoload for that
/ namespace, so 30 `doc.x:` definitions here cost 30 reloads of lib/doc.k
/ (11s instead of 0.5s).  See .plan/triage.md.

2:"lib/doc.k"

kdoc.OUT:"doc/api"                 / output directory
kdoc.SRCD:"lib"                    / module directory
kdoc.INDEX:"doc/api.md"            / index page
kdoc.MODE:`gen                     / `gen `check `print
kdoc.FILES:()                      / explicit module list (empty = scan kdoc.SRCD)

/ ── string helpers ──────────────────────────────────────────────────────────
kdoc.rep:{[s;a;b] doc.join[b; a\s]}                / replace every `a` with `b`
kdoc.yq:{[s] "'",kdoc.rep[s;,"'";"''"],"'"}        / single-quoted YAML scalar
kdoc.yl:{[xs] "[",doc.join[", ";kdoc.yq'xs],"]"}   / YAML flow list (commas, not `;`)
kdoc.pad:{[n;s] ((0|n-#s)#" "),s}

/ ── one module → markdown ───────────────────────────────────────────────────
/ front matter: everything a consumer might want without re-reading the prose.
/ NB `x`key` has to be bracketed whenever anything follows it — a bare `m`mod`
/ after a `,` re-associates and silently yields the wrong value.
kdoc.fmSym:{[r] doc.lines(
  "  - name: ",kdoc.yq[r`name]
  "    sig: ",kdoc.yq[r`sig]
  "    kind: ",doc.sym[r`kind]
  "    type: ",doc.sym[r`type]
  "    arity: ",($(r`arity))
  "    count: ",($(r`count))
  "    line: ",($1+(r`line))
  "    params: ",kdoc.yl[r`params]
  "    doc: ",kdoc.yq[r`summary])}

kdoc.front:{[m;ps] doc.lines(
  "---"
  "title: ",kdoc.yq[m`mod]
  "module: ",kdoc.yq[m`mod]
  "file: ",kdoc.yq[m`path]
  "kind: api"
  "summary: ",kdoc.yq[m`title]
  "symbols: ",($#ps)
  $[0=#ps; "api: []"; doc.lines[(,"api:"),kdoc.fmSym'ps]]
  "---")}

/ a definition renders as one bullet: signature, a type tag for non-functions,
/ then the first doc line; any further lines become an indented continuation.
kdoc.tag:{[r] ty:doc.sym[r`type]; c:r`count
  $[(r`kind)~`fn;   ""
  ; (r`kind)~`verb; " *verb*"
  ; c<0;            " *",ty,"*"
  ;                 " *",ty,"·",($c),"*"]}
kdoc.bullet:{[r] hd:"- `",(r`sig),"`",kdoc.tag[r],kdoc.dash[r`summary]
  $[0=#(r`detail); hd; doc.lines[(,hd),kdoc.indent'(r`detail)]]}
kdoc.dash:  {[s] $[0=#s; ""; " — ",s]}
kdoc.indent:{[s] $[0=#s; ""; "  ",s]}

kdoc.apiBlock:{[ps] $[0=#ps
  ; "_No documented API yet — add a comment block above each public binding._"
  ; doc.lines[("## API";""),kdoc.bullet'ps]]}
kdoc.body:{[m;ps] doc.lines(
  "# ",(m`mod)
  $[0=#(m`title); ""; "\n",(m`title)]
  $[1<#(m`head); "\n",doc.lines[1_(m`head)]; ""]
  ""
  kdoc.apiBlock[ps])}

kdoc.render:{[m] ps:doc.pub m; kdoc.front[m;ps],"\n",kdoc.body[m;ps],"\n"}

/ ── file discovery ──────────────────────────────────────────────────────────
/ `dir walks RECURSIVELY, so lib/json/json.k would shadow lib/json.k in the
/ index; keep only the modules that sit directly in `dir`, and sort so the
/ index is stable across filesystem orderings.
kdoc.isK:  {[f] doc.streq[-2#f;".k"]}
kdoc.isTop:{[dir;f] doc.streq[f; dir,"/",*|"/"\f]}
kdoc.kfiles:{[dir] f:`dir dir; ff:f@&kdoc.isK'f; tf:ff@&kdoc.isTop[dir]'ff; tf@<doc.modOf'tf}

/ ── index page ──────────────────────────────────────────────────────────────
kdoc.idxRow:{[m] "| [",(m`mod),"](api/",(m`mod),".md) | ",($#doc.pub m)," | ",(m`title)," |"}
kdoc.index:{[ms] doc.lines[(
  "---"
  "title: 'API reference'"
  "kind: api-index"
  "modules: ",($#ms)
  "---"
  ""
  "# API reference"
  ""
  "Generated from `lib/*.k` by `ink tools/doc.k` — do not edit by hand."
  ""
  "A binding is listed here when it starts its own line and carries a comment"
  "block directly above it; everything else is private."
  ""
  "| Module | API | Summary |"
  "| --- | --- | --- |"),kdoc.idxRow'ms]}

/ ── reporting ───────────────────────────────────────────────────────────────
kdoc.report:{[m] `0:(kdoc.pad[16;m`mod])," ",(kdoc.pad[4;$#doc.pub m])," /",(kdoc.pad[5;$#(m`defs)])," ",$[0=#(m`head);"(no header)";m`title],"\n"}

/ ── drivers ─────────────────────────────────────────────────────────────────
kdoc.write:{[m] p:kdoc.OUT,"/",(m`mod),".md"; p 1: kdoc.render m; p}
kdoc.gen:{[ms] ps:kdoc.write'ms
  kdoc.INDEX 1: kdoc.index[ms],"\n"
  `0:"wrote ",($#ps)," module pages to ",kdoc.OUT,"/ and ",kdoc.INDEX,"\n"
  0}
kdoc.check:{[ms] `0:"module            api / defs  summary\n"
  kdoc.report'ms
  n:+/{0=#doc.pub x}'ms
  `0:"\n",($n)," module",$[1=n;"";"s"]," with no documented API\n"
  n}
kdoc.show:{[ms] {`0:kdoc.render x}'ms; 0}

/ ── argument parsing ────────────────────────────────────────────────────────
kdoc.PREV:""
kdoc.arg:{[a] $[doc.streq[kdoc.PREV;"-o"]; kdoc.setOut a
  ; doc.streq[a;"-o"];     kdoc.setPrev a
  ; doc.streq[a;"-check"]; kdoc.setMode `check
  ; doc.streq[a;"-print"]; kdoc.setMode `print
  ; kdoc.addFile a]}
kdoc.setOut: {[a] kdoc.OUT::a; kdoc.PREV::""; 0}
kdoc.setPrev:{[a] kdoc.PREV::a; 0}
kdoc.setMode:{[k] kdoc.MODE::k; kdoc.PREV::""; 0}
kdoc.addFile:{[a] kdoc.FILES::kdoc.FILES,,a; kdoc.PREV::""; 0}

kdoc.main:{[argv]
  kdoc.arg'argv
  fs:$[#kdoc.FILES; kdoc.FILES; kdoc.kfiles kdoc.SRCD]
  ms:doc.file'fs
  $[kdoc.MODE~`check; kdoc.check ms; kdoc.MODE~`print; kdoc.show ms; kdoc.gen ms]}

/ bind the result: a bare expression statement's value is echoed by the evaluator
kdoc.done: kdoc.main x
