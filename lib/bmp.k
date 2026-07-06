/ lib/bmp.k — BMP image module (native libbmp extension).
/
/ Two views of a BMP:
/   bmp.read "path"    → the raw file STRUCTURE, exposed for array code:
/       `magic`header`dib[`masks][`palette]`pixels
/       magic  : "BM"                               (per-format marker)
/       header : `size`reserved`offset               (BITMAPFILEHEADER)
/       dib    : `size`width`height`planes`depth`compression`imagesize
/                `xppm`yppm`colors`important          (compression is a symbol)
/       masks  : `r`g`b`a         (only for bitfields / V4+ headers)
/       palette: (n;4) RGBA matrix (only for depth<=8)
/       pixels : raw bytes, bottom-up + row-padded, exactly as stored (char vec)
/   bmp.decode "path"  → a decoded image dict `width`height`comp`data (RGBA/RGB)
/
/ bmp.write[path; x] takes EITHER a structure dict (round-trips the raw pixels)
/ or a decoded image dict (re-encodes as 24/32-bit).  Helpers below index the raw
/ pixel array without a full decode.
\d bmp read decode write compression ccode stride rows xy at
  so:     "./zig-out/lib/libbmp.dylib"
  read:   so 2:(`BmpRead;   1)
  decode: so 2:(`BmpDecode; 1)
  enc:    so 2:(`BmpEncode; 1)
  wrs:    so 2:(`BmpWriteS; 1)

  / BI_* compression: the symbol enum, and symbol→code (codes are non-contiguous).
  compression: `rgb`rle8`rle4`bitfields`jpeg`png`alphabitfields`cmyk`cmykrle8`cmykrle4
  ccode: compression!(0 1 2 3 4 5 6 11 12 13)

  / Row size in bytes (each scanline is padded to a 4-byte boundary).
  stride: {[b] d: b`dib; wd: abs d`width; dep: d`depth; 4 * _ ((dep*wd)+31) % 32}

  / Raw pixels reshaped to a top-down (height; stride) byte matrix. Rows are
  / stored bottom-up on disk (positive height), so flip them.
  rows: {[b] d:b`dib;hh:abs b`dib`height;st:stride b;
    m:(hh;st)#b`pixels;
    $[(d`height)>0;|m;m]}

  / Linear pixel index → (x; y).
  xy: {[b;i] d: b`dib; wd: abs d`width; (i mod wd;_i%wd)}

  / Pixel at (x;y) of a DECODED image dict → its comp-length sample vector.
  at: {[img;x;y] w: img`width; c: img`comp; o: c * x + y * w; (img`data) @ o + !c}

  / Write a structure dict back (raw pixels preserved), or re-encode an image dict.
  wrStruct: {[path;b] d: b`dib;
    hasm: `masks in !b
    m:   $[hasm; b`masks; ()]
    msk: $[hasm; (m`r; m`g; m`b; m`a); 0 0 0 0]
    pal: $[`palette in !b; ,/ b`palette; !0]
    cc:  ccode d`compression
    wrs (path; d`width; d`height; d`depth; cc; msk; pal; b`pixels)}
  write: {[path;b] $[`pixels in !b; wrStruct[path;b]; enc (path; b`width; b`height; b`comp; b`data)]}
