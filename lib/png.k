/ lib/png.k — PNG image module (native libpng extension).  Auto-loads on first
/ reference to png.read / png.write / png.info.
/   png.read  "path"   → image dict `width`height`comp`data (I data; samples 0..255/65535)
/   png.info  "path"   → header dict `width`height`depth`color`interlace`comp
/   png.write [p;img]  → 1b   (writes an 8-bit PNG; img is an image dict)
\d png read write info
  so:    "./zig-out/lib/libpng.dylib"
  read:  so 2:(`PngRead;  1)
  info:  so 2:(`PngInfo;  1)
  wr:    so 2:(`PngWrite;  1)
  write: {[p;img] wr (p; img`width; img`height; img`comp; img`data)}
\d
