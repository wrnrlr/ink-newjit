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
| `bmp`  | ✓ | ✓ | `bmp.read`   | full file structure (magic/header/dib/masks/palette/raw pixels); 1/4/8-bit palette, 16/24/32-bit direct or BI_BITFIELDS (no RLE) |
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

bmp.read   "path"          / → raw file STRUCTURE dict (see below)
bmp.decode "path"          / → decoded image dict (RGBA/RGB)
bmp.write  ["path"; x]      / x = a structure dict (round-trips raw pixels) OR an
                           /     image dict (re-encode 24/32-bit)
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

## BMP as raw structure (`bmp.read`)

`bmp.read` doesn't decode pixels — it hands back the on-disk layout so array code
can pick it apart or rebuild it. `magic` comes first as a per-format marker
(the same idea will front every format's structural read):

```
`magic`header`dib[`masks][`palette]`pixels
```

* `magic`   — `"BM"`
* `header`  — `` `size`reserved`offset `` (the 14-byte BITMAPFILEHEADER)
* `dib`     — `` `size`width`height`planes`depth`compression`imagesize`xppm`yppm`colors`important ``
  (`size` tells the header version: 12/40/52/56/108/124; `compression` is a
  **symbol** — see `bmp.compression`; `height` may be negative for top-down)
* `masks`   — `` `r`g`b`a `` — present only for BI_BITFIELDS / V4+ headers
* `palette` — an `(n;4)` **RGBA matrix** — present only for `depth<=8`
* `pixels`  — the raw pixel bytes as a **char vector**, exactly as stored
  (bottom-up, each row padded to 4 bytes)

Helpers in the `bmp` namespace:

```
bmp.compression   / `rgb`rle8`rle4`bitfields`jpeg`png`alphabitfields`cmyk`cmykrle8`cmykrle4
bmp.ccode         / that enum as a symbol→BI_* code dict
bmp.stride b      / padded row width in bytes
bmp.rows b        / raw pixels reshaped to a top-down (height; stride) byte matrix
bmp.xy [b; i]     / linear pixel index → (x; y)
bmp.at [img;x;y]  / sample vector at (x;y) of a *decoded* image dict
```

Edit-in-place round-trips losslessly — read the structure, replace `pixels` (or
`palette`), and write it back:

```k
s: bmp.read "in.bmp"
s[`pixels]: `c$ (#s`pixels) # 0    / paint it black
bmp.write["out.bmp"; s]           / raw pixels preserved byte-for-byte
```

Build one from scratch (an 8-bit palettized image):

```k
pal: (2;4)# 0 0 0 255  255 255 255 255           / index 0 black, 1 white
p8: `magic`header`dib`palette`pixels!(
  "BM"; `size`reserved`offset!(0;0;0);
  `width`height`depth`compression!(2;2;8;`rgb);
  pal; `c$ 1 0 0 0  0 1 0 0)                      / indices, 2 rows, stride 4
bmp.write["pal.bmp"; p8]
```

The writer normalizes the header to a v3 BITMAPINFOHEADER (adding BI_BITFIELDS
masks when `compression` is `` `bitfields``/`` `alphabitfields``), so a
read→write cycle preserves pixels and dimensions but not byte-exact headers.

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
