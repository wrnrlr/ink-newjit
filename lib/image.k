/ lib/image.k — format-agnostic image front end (native libimage extension).
/
/ image.read dispatches on the file's magic bytes to the matching per-format
/ module (png/jpeg/bmp/gif/tga/hdr/pic), each of which auto-loads on first use —
/ so a program that only ever reads PNGs never pulls in the JPEG decoder.
/
/   image.read  "path"          → image dict `width`height`comp`data
/   image.write ["path"; img]   → 1b   (chooses the encoder from the extension)
/   image.scale [img; nw; nh]   → image dict resampled to nw×nh (bilinear)
/   image.sniff "path"          → `png `jpeg `bmp `gif `tga `hdr `pic | `unknown
/
/ An image dict is `width`height`comp`data ! (w; h; channels; DATA) where DATA is
/ a row-major, top-left-first, channel-interleaved vector of length w*h*comp — an
/ I vector for 8/16-bit sources or an F vector for HDR.
\d image read write scale sniff
  so:     "./zig-out/lib/libimage.dylib"
  sniff:  so 2:(`ImgSniff; 1)
  scale0: so 2:(`ImgScale; 1)

  read: {[p] f: sniff p;
    $[f=`png;  png.read  p
      f=`jpeg; jpeg.read p
      f=`bmp;  bmp.read  p
      f=`gif;  gif.read  p
      f=`tga;  tga.read  p
      f=`hdr;  hdr.read  p
      f=`pic;  pic.read  p
      '"image.read: unknown image format"]}

  / Resize an image dict to nw×nh (bilinear, integer channels).
  scale: {[img;nw;nh] d: scale0 ((img`width); (img`height); (img`comp); (img`data); nw; nh);
    `width`height`comp`data!(nw; nh; img`comp; d)}

  / Encode by file extension.
  write: {[p;img] e: -4#p;
    $[e~".png"; png.write[p;img]
      e~".bmp"; bmp.write[p;img]
      '"image.write: no encoder for that extension"]}
\d
