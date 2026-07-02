/ lib/json.k — JSON extension
/
/ Build first:  zig build json
/ Use:          json.read "path.json"   (auto-loads on first use)
/               json.parse "{...}"      (parse a string)
/
/ NB: `parse` is a reserved verb, so the member is written with its explicit
/ qualified name `json.parse:` (which lexes as one identifier, not the verb).

\d json read
so: "./zig-out/lib/libjson.dylib"
read:       so 2: (`ReadJson; 1)   / json.read  "path.json"  → K value
json.parse: so 2: (`ParseJson; 1)  / json.parse "{...}"      → K value (from a string)
\d
