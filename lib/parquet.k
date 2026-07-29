/
# parquet

Reads Parquet files into tables, across encodings, codecs and row groups.

Build the extension first with `zig build parquet`; the module then loads on the
first reference to any `parquet.*` name.
\

\d parquet read
so: "./zig-out/lib/libparquet.dylib"
read: so 2: (`ReadParquet; 1)   / parquet.read "path.parquet"  → table
\d
