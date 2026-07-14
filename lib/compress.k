/ lib/compress.k — DEFLATE compression module (native Zig std.compress.flate).
/
/ Build first:  zig build compress
/ Load with:    2:"lib/compress.k"   (or reference any `compress.*` name)
/
/ Bytes in, bytes out.  Round-trip:
/   c: compress.deflate "the quick brown fox"
/   compress.inflate c                 / → "the quick brown fox"
/   compress.gzip x / compress.gunzip  / gzip container (RFC 1952)
/   compress.zlib x / compress.unzlib  / zlib container (RFC 1950)
/
/ Decompressors return an error value `' on corrupt input, so guard with `@`.

\d compress
  so: "./zig-out/lib/libcompress.dylib"

  deflate:  so 2:(`compDeflate; 1)   / bytes → raw DEFLATE stream
  inflate:  so 2:(`compInflate; 1)   / raw DEFLATE stream → bytes | error
  gzip:     so 2:(`compGzip;    1)   / bytes → gzip container
  gunzip:   so 2:(`compGunzip;  1)   / gzip container → bytes | error
  zlib:     so 2:(`compZlib;    1)   / bytes → zlib container
  unzlib:   so 2:(`compUnzlib;  1)   / zlib container → bytes | error
  crc32:    so 2:(`compCrc32;   1)   / bytes → i32 CRC-32  (gzip/zip checksum)
  adler32:  so 2:(`compAdler32; 1)   / bytes → i32 Adler-32 (zlib checksum)
\d
