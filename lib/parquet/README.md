# Parquet extension

Reads Apache Parquet files into an ink table, analogous to the CSV extension but
for the binary columnar format.

## Build & use

```bash
zig build parquet            # builds zig-out/lib/libparquet.dylib
```

```k
t: ReadParquet "data/file.parquet"   / → table, one column per Parquet leaf field
```

`ReadParquet` auto-loads on first use (via `lib/parquet.k`). The shared library
path is resolved relative to the current directory, so run from the repo root or
adjust `so:` in `lib/parquet.k`.

## Type mapping

| Parquet physical type              | ink column |
|------------------------------------|------------|
| `BOOLEAN`, `INT32`, `INT64`        | `I` (i32)  |
| `FLOAT`, `DOUBLE`                  | `F` (f32)  |
| `BYTE_ARRAY`, `FIXED_LEN_BYTE_ARRAY` | `L` of `C` (list of char vectors) |

Nulls become `0N` (int), `0n`/nan (float), or `""` (string).

## Supported

- Flat schemas (one row of scalar values per record)
- `REQUIRED` and `OPTIONAL` columns (definition levels)
- Encodings: `PLAIN`, `PLAIN_DICTIONARY`, `RLE_DICTIONARY`, and `RLE` for booleans
  (Arrow's default boolean encoding) and definition levels
- Codecs: `UNCOMPRESSED`, `SNAPPY`, `GZIP`, `ZSTD`
- Data pages v1 and v2
- Multiple row groups

Verified against both DuckDB (page v1) and PyArrow (page v1 and v2) output across
all four codecs.

## Limitations

- **No 64-bit numbers.** ink's value model has only i32/f32. `INT64` values that
  exceed the i32 range read back as `0N`; `DOUBLE` is narrowed to f32.
- Nested / repeated columns (lists, maps, structs) are rejected with an error.
- Encodings `DELTA_*` and `BYTE_STREAM_SPLIT`, and codecs `LZO`/`BROTLI`/`LZ4`
  are not implemented.
- `INT96` (legacy timestamps) reads as `0N`.
- Decryption (modular encryption) is not supported.

## Layout

- `parquet.k` / `../parquet.k` — loaders (the latter enables auto-loading)
- `src/main.zig` — k-ABI glue, `ReadParquet` export, table builder
- `src/reader.zig` — metadata parsing + page decoding into typed columns
- `src/thrift.zig` — Thrift TCompactProtocol reader
- `src/snappy.zig` — Snappy block decompressor
