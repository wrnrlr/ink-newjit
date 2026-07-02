/ lib/parquet.k — Parquet extension
/
/ Build first:  zig build parquet
/ Use:          parquet.read "path.parquet"   (auto-loads on first use)

\d parquet read
so: "./zig-out/lib/libparquet.dylib"
read: so 2: (`ReadParquet; 1)   / parquet.read "path.parquet"  → table
\d
