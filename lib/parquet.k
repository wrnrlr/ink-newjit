/ lib/parquet.k — load Parquet extension
/
/ Build first:  zig build parquet
/ Public name ReadParquet auto-loads this file on first use.

so: "./zig-out/lib/libparquet.dylib"
ReadParquet: so 2: (`ReadParquet; 1)   / ReadParquet "path.parquet"  → table
