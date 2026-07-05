/ lib/hdr.k — Radiance HDR module (native libhdr extension).
/   hdr.read "path" → image dict with an F (float) `data column (linear RGB)
\d hdr read
  read: ("./zig-out/lib/libhdr.dylib") 2:(`HdrRead; 1)
\d
