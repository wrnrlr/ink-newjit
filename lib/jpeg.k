/ lib/jpeg.k — JPEG image module (native libjpeg extension; baseline+progressive).
/   jpeg.read   "path" → image dict `width`height`comp`data  (1 or 3 channels)
/   jpeg.header "path" → marker layout dict
/       `width`height`precision`ncomp`progressive`components`quant`huffman`restart`app
\d jpeg read header
  so:     "./zig-out/lib/libjpeg.dylib"
  read:   so 2:(`JpegRead;   1)
  header: so 2:(`JpegHeader; 1)
\d
