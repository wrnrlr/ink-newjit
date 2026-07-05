/ lib/bmp.k — BMP image module (native libbmp extension).
/   bmp.read  "path"   → image dict `width`height`comp`data
/   bmp.write [p;img]  → 1b   (24-bit for opaque, 32-bit when alpha present)
\d bmp read write
  so:    "./zig-out/lib/libbmp.dylib"
  read:  so 2:(`BmpRead;  1)
  wr:    so 2:(`BmpWrite; 1)
  write: {[p;img] wr (p; img`width; img`height; img`comp; img`data)}
\d
