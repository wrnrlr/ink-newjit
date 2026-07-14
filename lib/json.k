/ lib/json.k — JSON extension
/
/ Build first:  zig build json
/ Use:          json.read "path.json"   (auto-loads on first use)
/               json.parse "{...}"      (parse a string)
/
/ NB: `parse` is a reserved verb, so the member is written with its explicit
/ qualified name `json.parse:` (which lexes as one identifier, not the verb).

\d json read gen parse list
so: "./zig-out/lib/libjson.dylib"
read:       so 2: (`ReadJson; 1)   / json.read  "path.json"  → K value
json.parse: so 2: (`ParseJson; 1)  / json.parse "{...}"      → K value (from a string)
list:       so 2: (`ParseJsonList; 1) / like parse, but keeps object arrays as
  / general lists instead of promoting them to a column table (for API responses)

/ ── gen: K value → JSON text (pure k, rough inverse of json.parse) ──────────
/   dict→object, general/typed vector→array, char-vec/symbol→string,
/   i/f→number, b→true/false, and the symbol `null → JSON null.
hexd: "0123456789abcdef"
uesc: {[c] n:`i$c; "\\u00",(,hexd@(n div 16)),(,hexd@(n mod 16))}
/ Compare by char code: ink literals can't express CR (`"\r"` decodes to `r`),
/ so `c="\r"` would wrongly match every 'r'. Output-side escapes only use the
/ supported `\\` / `\"` forms.
ec:   {[c] n:`i$c; $[n=34;"\\\"";n=92;"\\\\";n=10;"\\n";n=13;"\\r";n=9;"\\t";n<32;uesc c;,c]}
esc:  {[s] $[0=#s;s;,/({ec x}'s)]}
jstr: {[c] "\"",(esc c),"\""}
gen: {[x] t:@x;
  $[x~`null; "null"
   / values via `x@!x` (index the dict by its own keys) — arity-correct for any
   / key count and, unlike `. x`, never unwraps a single-key dict's lone value.
   ;t=`m; $[0=#x;"{}";"{",(","/((!x){[ky;vl](jstr(1_$ky)),":",gen vl}'(x@!x))),"}"]
   ;t=`C; jstr x
   ;t=`c; jstr(,x)
   ;t=`s; jstr(1_$x)
   ;t=`b; $[x;"true";"false"]
   ;t=`i; $x
   ;t=`f; $x
   ;$[0=#x;"[]";"[",(","/({gen x}'x)),"]"]]}
\d
