/ lib/csv/csv.k — load CSV extension
/
/ Build first:  zig build csv
/ Load with:    2: "lib/csv/csv.k"

so: "./zig-out/lib/libcsv.dylib"
ReadCsv: so 2: (`ReadCsv; 1)   / ReadCsv "path.csv"  → dict of column arrays
