# Ink Libraries

Public namespaced names (`json.parse`, `http.get`, …) **autoload** their module from
`$INK_HOME/lib` on first use — no import needed. Native extensions are shared libraries
(`.dylib`/`.so`) that ship in the ink home; pure-k libs are just `.k` files.
Everything byte-oriented is `C` char vectors in/out.

## Data formats

- **json** — `json.parse s` → value (object arrays columnarise into tables; use
  `json.list s` to keep them as lists), `json.gen v` → string.
- **csv** — `csv.read path`, `csv.write`.
- **parquet** — `parquet.read path` (PLAIN/dict encodings; snappy/gzip/zstd). INT64→i32.
- **safetensors** — `safetensors.read path` → dict name→`[dtype;shape;data]`
  (F16/BF16 widen to f32; I64/U32/U64 clamp→`0N`).
- **image** — `image.read path` → `[width;height;comp;data]` dict (png/jpeg/bmp/tga/gif/
  hdr/tiff), `image.write[path;img]`, `image.scale[img;w;h]`.
- **zip** — `zip.list path` → table, `zip.read path` → dict name→bytes,
  `zip.entry[path;name]`, `zip.write[path;names;datas]`.
- **compress** — `compress.deflate`/`inflate`, `gzip`/`gunzip`, `zlib`/`unzlib`,
  `crc32`, `adler32`.
- Pure-k 3D/geo readers: `gltf` (ReadGltf/ReadGlb), `fbx` (ReadFbx), `usd` (ReadUsdc),
  `shp` (ReadShp shapefiles), plus `font.read` (sfnt).

## Network

- **http** — `http.get url`, `http.post[url;body]`, `http.put`, `http.patch`, `http.del`,
  `http.head`; `http.request[method;url;headers;body]` (headers = flat name/value C pairs).
  Returns `[status;headers;body]` dict or error. TLS, redirects, gzip automatic.
  Streaming (SSE): `http.stream[method;url;headers;body;{[line]…}]` → `[status;headers]`.
- Sockets: `h:<"host:port"`, close with `>h`.

## LLM

- **llm** (pure k, keys from `ANTHROPIC_API_KEY`/`XAI_API_KEY` env):
  `cfg:llm.anthropic model` / `llm.grok model`; `llm.ask[cfg;prompt]` (streams tokens
  live, returns full text); `llm.turn[cfg;history;text]` multi-turn (start history at `()`);
  `llm.stream[cfg;messages]` low-level.
  Agent loop: `llm.agent[cfg;tools;task]` with `llm.tool[name;desc;params;fn]`,
  `llm.obj[properties;required]`, `llm.prop[type;desc]` — `fn` is `inputDict → resultString`.

## Crypto

- Hashes: `crypto.md5/sha1/sha256/sha512/sha3256/blake2b/blake3 msg` → raw digest.
- `crypto.hmac[key;msg]` (SHA-256), `crypto.hkdf[salt;ikm;info]`,
  `crypto.pbkdf2[pw;salt;rounds]`.
- AEAD: `crypto.encrypt/decrypt` (XChaCha20-Poly1305, key 32/nonce 24),
  `crypto.aesEncrypt/aesDecrypt` (AES-256-GCM, key 32/nonce 12) → `ct||tag`.
- Ed25519: `crypto.keypair seed32` → `pub32||secret64`, `crypto.sign[secret;msg]`,
  `crypto.verify[pub;sig;msg]`. X25519: `crypto.x25519pub`, `crypto.x25519[sec;pub]`.
- `crypto.random n`, `crypto.hex/unhex`, `crypto.b64/unb64`, `crypto.equal[a;b]` (const-time).

## Audio

- `audio.play "f.wav"` one-shot; `h:audio.load "f.wav"` voice → `audio.start/stop/volume/
  pitch/loop/seek`; `audio.music "f.mp3"` streamed loop.
- 3D: `audio.pos[h;xyz]`, `audio.vel`, `audio.spatial`, `audio.listener xyz` (each frame).
- Mic: `audio.rec.start[]`, `s:audio.rec.read[]` (drain in a loop), `audio.rec.stop[]`;
  `audio.decode path` → PCM dict, `audio.save[path;ch;rate;samples]`.

## Text & misc

- **regex** — pure-k Thompson NFA (`lib/regex.k`).
- **font** — `font.read path` → face dicts; `font.shape[f;s]` string→gids,
  `font.outline[f;gid;sz]` → flat `F` contours (tessellate for rendering);
  `font.metrics[f;sz]`, `font.glyph[f;cp]`.
- **color** — `hsl2rgb`, `pct2rgb`, OKLCH Tailwind palette constants (`Red500`, …) as
  `[r,g,b,a]` vectors.

## GPU

See [gpu.md](gpu.md) — windowing, 2D/3D drawing, compute, and the dye shader compiler.
