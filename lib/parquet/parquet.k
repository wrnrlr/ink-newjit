/ lib/parquet/parquet.k — load Parquet extension
/
/ Build first:  zig build parquet
/ Load with:    2: "lib/parquet/parquet.k"

so: "./zig-out/lib/libparquet.dylib"
ReadParquet: so 2: (`ReadParquet; 1)   / ReadParquet "path.parquet"  → table
