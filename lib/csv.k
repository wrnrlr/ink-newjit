/
# csv

Reads a CSV file into a dict of typed column arrays.

Build the extension first with `zig build csv`; the module then loads on the
first reference to any `csv.*` name.
\

\d csv read
so: "./zig-out/lib/libcsv.dylib"
read: so 2: (`ReadCsv; 1)   / csv.read "path.csv"  → dict of column arrays
\d
