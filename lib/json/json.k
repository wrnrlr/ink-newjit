/ lib/json/json.k — load JSON extension
/
/ Build first:  zig build json
/ Load with:    2: "lib/json/json.k"

so: "./zig-out/lib/libjson.dylib"
ReadJson: so 2: (`ReadJson; 1)   / ReadJson "path.json"  → K value
ParseJson: so 2: (`ParseJson; 1) / ParseJson "{...}"     → K value (parse a string)
