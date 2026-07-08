/ lib/tiff.k — TIFF image module (native libtiff extension).  Auto-loads on first
/ reference to tiff.read.  Baseline TIFF only: 8-bit chunky RGB/grayscale,
/ uncompressed or Deflate (with an optional horizontal predictor).
/   tiff.read  "path"   → image dict `width`height`comp`data (I data; samples 0..255)
\d tiff read
  so:   "./zig-out/lib/libtiff.dylib"
  read: so 2:(`TiffRead; 1)
\d
