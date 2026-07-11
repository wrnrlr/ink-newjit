/ lib/image.k — format-agnostic image front end (native libimage extension).
/
/ image.read dispatches on the file's magic bytes to the matching per-format
/ module (png/jpeg/bmp/gif/tga/hdr/pic/tiff), each of which auto-loads on first
/ use — so a program that only reads PNGs never pulls in the JPEG decoder.
/ (tiff is baseline only: 8-bit chunky RGB/gray, uncompressed or Deflate.)
/
/   image.read  "path"          → image dict `width`height`comp`data
/   image.write ["path"; img]   → 1b   (chooses the encoder from the extension)
/   image.scale [img; nw; nh]   → image dict resampled to nw×nh (bilinear)
/   image.sniff "path"          → `png `jpeg `bmp `gif `tga `hdr `pic `tiff | `unknown
/
/ An image dict is `width`height`comp`data ! (w; h; channels; DATA) where DATA is
/ a row-major, top-left-first, channel-interleaved vector of length w*h*comp — an
/ I vector for 8/16-bit sources or an F vector for HDR.
\d image read write scale sniff
  so:     "./zig-out/lib/libimage.dylib"
  sniff:  so 2:(`ImgSniff; 1)
  scale0: so 2:(`ImgScale; 1)

  read: {[path] f: sniff path;
    $[f=`png;  png.read  path
      f=`jpeg; jpeg.read path
      f=`bmp;  bmp.decode path
      f=`gif;  gif.read  path
      f=`tga;  tga.read  path
      f=`hdr;  hdr.read  path
      f=`pic;  pic.read  path
      f=`tiff; tiff.read path
      '"image.read: unknown image format"]}

  / Resize an image dict to nw×nh (bilinear, integer channels).
  scale: {[img;nw;nh] d: scale0 ((img`width); (img`height); (img`comp); (img`data); nw; nh);
    `width`height`comp`data!(nw; nh; img`comp; d)}

  / Encode by file extension.
  write: {[path;img] e: -4#path;
    $[e~".png"; png.write[path;img]
      e~".bmp"; bmp.write[path;img]
      '"image.write: no encoder for that extension"]}

/ lib/tga.k — TGA image module (native libtga extension).  tga.read "path" → image dict
\d tga read
  read: ("./zig-out/lib/libtga.dylib") 2:(`TgaRead; 1)

\d png read write info
  so:    "./zig-out/lib/libpng.dylib"
  read:  so 2:(`PngRead;  1)  / png.read  "path"   → image dict `width`height`comp`data (I data; samples 0..255/65535)
  info:  so 2:(`PngInfo;  1)  / png.info  "path"   → header dict `width`height`depth`color`interlace`comp
  wr:    so 2:(`PngWrite;  1)
  write: {[p;img] wr (p; img`width; img`height; img`comp; img`data)} / png.write [p;img]  → 1b   (writes an 8-bit PNG; img is an image dict)

\d pic read
  / lib/pic.k — Softimage PIC module (native libpic extension).  pic.read "path" → image dict
  read: ("./zig-out/lib/libpic.dylib") 2:(`PicRead; 1)

\d jpeg read header
  so:     "./zig-out/lib/libjpeg.dylib"
  / jpeg.read   "path" → image dict `width`height`comp`data  (1 or 3 channels)
  read:   so 2:(`JpegRead;   1)
  / jpeg.header "path" → marker layout dict: `width`height`precision`ncomp`progressive`components`quant`huffman`restart`app
  header: so 2:(`JpegHeader; 1)

\d gif read
  / gif.read "path" → image dict (always 4-channel RGBA)
  read: ("./zig-out/lib/libgif.dylib") 2:(`GifRead; 1)

\d hdr read
  / hdr.read "path" → image dict with an F (float) `data column (linear RGB)
  read: ("./zig-out/lib/libhdr.dylib") 2:(`HdrRead; 1)

/ lib/tiff.k — TIFF image module (native libtiff extension).  Auto-loads on first
/ reference to tiff.read.  Baseline TIFF only: 8-bit chunky RGB/grayscale,
/ uncompressed or Deflate (with an optional horizontal predictor).
/   tiff.read  "path"   → image dict `width`height`comp`data (I data; samples 0..255)
\d tiff read
  so:   "./zig-out/lib/libtiff.dylib"
  read: so 2:(`TiffRead; 1)

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
