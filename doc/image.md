# Image modules

Native image decoders/encoders for ink, ported from the public-domain
[stb_image](https://github.com/nothings/stb) (the same subset SDL_image builds
on). Performance-critical code is Zig; the k side is thin dispatch + layout
helpers, mirroring how `lib/font` exposes the sfnt tables.

## Formats

| Module | read | write | layout | notes |
|--------|------|-------|--------|-------|
| `png`  | ✓ | ✓ | `png.info`   | 1/2/4/8/16-bit, grey/RGB/palette, tRNS, Adam7 interlace, iPhone CgBI |
| `jpeg` | ✓ |   | `jpeg.header`| baseline **and** progressive; YCbCr/RGB/CMYK/YCCK; no 12-bit / arithmetic |
| `bmp`  | ✓ | ✓ |             | 1/4/8-bit palette, 16/24/32-bit direct or BI_BITFIELDS (no RLE) |
| `tga`  | ✓ |   |             | 8-bit grey, 15/16/24/32-bit, colormapped, RLE |
| `gif`  | ✓ |   |             | first frame; global/local palettes, LZW, interlace, transparency |
| `hdr`  | ✓ |   |             | Radiance RGBE → 3-channel **float** image |
| `pic`  | ✓ |   |             | Softimage PIC (uncompressed / RLE) |
| `image`| dispatch | dispatch | `image.sniff` | magic-byte front end + `image.scale` |

Each format is its own shared library (`libpng.dylib`, `libjpeg.dylib`, …) with
the format-agnostic helpers in `libimage.dylib`, so `ink bundle` links only the
decoders a program actually references.

## Build

```bash
zig build images      # all of them
zig build png         # or one at a time: png jpeg bmp tga gif hdr pic image
```

## The image dict

Every `*.read` returns a plain symbol-keyed dict:

```
`width`height`comp`data ! (w; h; channels; DATA)
```

`DATA` is a **row-major, top-left-first, channel-interleaved** vector of length
`w*h*comp` — an `I` vector for 8/16-bit sources (samples `0..255` or `0..65535`)
or an `F` vector for HDR. Channel order is grey / grey+α / RGB / RGBA by count.
This is the shape `image.scale` and `png.write`/`bmp.write` consume, and it drops
straight into a GPU texture upload.

## K API

```k
png.read   "path"          / → image dict
png.write  ["path"; img]    / 8-bit PNG (filter 0 + stored zlib); → 1b
png.info   "path"          / → `width`height`depth`color`interlace`comp

jpeg.read  "path"          / → image dict (1 or 3 channels)
jpeg.header "path"         / → structured marker layout (see below)

bmp.read / bmp.write        / like png; 24-bit opaque, 32-bit when alpha present
tga.read / gif.read / hdr.read / pic.read

image.read  "path"         / sniff magic bytes → dispatch to the right module
                           /   (which auto-loads); → image dict
image.write ["path"; img]  / choose encoder by file extension (.png / .bmp)
image.scale [img; nw; nh]  / bilinear resize → new image dict
image.sniff "path"         / → `png `jpeg `bmp `gif `tga `hdr `pic | `unknown
```

`image.read` only loads the decoder it needs — a program that reads PNGs never
pulls in the JPEG code.

## JPEG marker layout (`jpeg.header`)

Follows the SOI → APPn → DQT → SOF → DHT → DRI → SOS structure of a JFIF file:

```
`width`height`precision`ncomp`progressive`components`quant`huffman`restart`app
```

* `components` — table `(id; h; v; tq)` (one row per colour component, with its
  sampling factors and quant-table index)
* `huffman`    — table `(class; id; count)` (0 = DC / 1 = AC tables, symbol count)
* `quant`      — `I` of quant-table ids present
* `app`        — table `(marker; length)` of the APPn / COM segments
* `restart`    — DRI restart interval (0 if none)

Example (`data/ambientcg/Grass005_1K-JPG/Grass005_1K-JPG_Color.jpg`):

```
[width:1024;height:1024;precision:8;ncomp:3;progressive:0b;
 components:[[]id:1 2 3;h:1 1 1;v:1 1 1;tq:0 1 1];
 quant:0 1;huffman:[[]class:0 1 0 1;id:0 0 1 1;count:10 31 9 40];
 restart:0;app:[[]marker:224 225;length:14 968]]
```

## Layout under `lib/image/`

* `reader.zig`  — big/little-endian byte cursor over the in-memory file
* `kbuild.zig`  — the shared k-value builder (atoms/vectors/dicts/tables)
* `common.zig`  — `Image`, channel conversion, size math, the K image-dict
  builders, and file-I/O over a k path
* `zlib.zig`    — DEFLATE inflate (stb port) + a stored-block zlib encoder
* `png.zig` `jpeg.zig` `bmp.zig` `tga.zig` `gif.zig` `hdr.zig` `pic.zig` —
  one decoder per format
* `image.zig`   — magic-byte sniff + bilinear `scale`
* `*_ext.zig`   — the FFI roots (one per shared library) that register the
  callable functions with the host

See `test/image.k` for a worked example.
