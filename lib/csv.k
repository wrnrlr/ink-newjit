/ lib/csv.k — CSV extension
/
/ Build first:  zig build csv
/ Use:          csv.read "path.csv"   (auto-loads this file on first use)

\d csv read
so: "./zig-out/lib/libcsv.dylib"
read: so 2: (`ReadCsv; 1)   / csv.read "path.csv"  → dict of column arrays
\d
