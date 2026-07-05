/ lib/gif.k — GIF image module (native libgif extension, first frame).
/   gif.read "path" → image dict (always 4-channel RGBA)
\d gif read
  read: ("./zig-out/lib/libgif.dylib") 2:(`GifRead; 1)
\d
