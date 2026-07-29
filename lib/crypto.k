/
# crypto

Hashes, MACs, key derivation, authenticated encryption and signatures.

Everything is bytes: keys, nonces, messages, digests and ciphertexts are all
C (byte) vectors, so the primitives compose.  Build higher-level protocols by
chaining them — e.g. authenticated encryption with a derived key:

```k
k: crypto.random 32                        / secret key
n: crypto.random 24                         / XChaCha nonce
c: crypto.encrypt[k; n; "attack at dawn"]   / ciphertext || tag
crypto.decrypt[k; n; c]                      / → "attack at dawn"

crypto.hex crypto.sha256 "abc"              / hex digest text
crypto.hmac[k; "msg"]                        / HMAC-SHA256 tag
kp: crypto.keypair crypto.random 32          / Ed25519 pub(32)||secret(64)
s:  crypto.sign[64_kp; "msg"]                / sign with the secret half
crypto.verify[32#kp; s; "msg"]               / → 1b
```

NB: a single-character string is a char ATOM, not a C vector — enlist it
(`,"x"`) when a 1-byte key/message is needed.  Decrypt/unhex/unb64 return an
error value `' on failure (bad tag / malformed input), so guard with `@`.

Build the extension first with `zig build crypto`; the module then loads on the
first reference to any `crypto.*` name.
\

\d crypto
  so: "./zig-out/lib/libcrypto.dylib"

  / ── Hashes (msg → raw digest bytes) ──────────────────────────────────────
  md5:       so 2:(`cryMd5;        1)   / → C[16]
  sha1:      so 2:(`crySha1;       1)   / → C[20]
  sha224:    so 2:(`crySha224;     1)   / → C[28]
  sha256:    so 2:(`crySha256;     1)   / → C[32]
  sha384:    so 2:(`crySha384;     1)   / → C[48]
  sha512:    so 2:(`crySha512;     1)   / → C[64]
  sha3256:   so 2:(`crySha3256;    1)   / → C[32]  (SHA3-256)
  sha3512:   so 2:(`crySha3512;    1)   / → C[64]  (SHA3-512)
  blake2b:   so 2:(`cryBlake2b;    1)   / → C[32]  (BLAKE2b-256)
  blake2b512: so 2:(`cryBlake2b512; 1)  / → C[64]
  blake3:    so 2:(`cryBlake3;     1)   / → C[32]

  / ── MAC (key,msg → tag) ──────────────────────────────────────────────────
  hmac:      so 2:(`cryHmac256;    2)   / HMAC-SHA256 → C[32]
  hmac512:   so 2:(`cryHmac512;    2)   / HMAC-SHA512 → C[64]

  / ── Key derivation ───────────────────────────────────────────────────────
  hkdf:      so 2:(`cryHkdf256;    3)   / [salt;ikm;info] → C[32]  (HKDF-SHA256)
  hkdf512:   so 2:(`cryHkdf512;    3)   / [salt;ikm;info] → C[64]
  pbkdf2:    so 2:(`cryPbkdf2;     3)   / [password;salt;rounds] → C[32]  (SHA256)

  / ── AEAD (key,nonce,data → …) ────────────────────────────────────────────
  / XChaCha20-Poly1305: key 32, nonce 24, tag 16.  encrypt → ct||tag;
  / decrypt → plaintext, or an error `' on authentication failure.
  encrypt:   so 2:(`cryEncrypt;    3)   / [key;nonce;msg] → C
  decrypt:   so 2:(`cryDecrypt;    3)   / [key;nonce;ct]  → C | error
  / AES-256-GCM: key 32, nonce 12, tag 16.
  aesEncrypt: so 2:(`cryAesEncrypt; 3)  / [key;nonce;msg] → C
  aesDecrypt: so 2:(`cryAesDecrypt; 3)  / [key;nonce;ct]  → C | error

  / ── Ed25519 signatures ───────────────────────────────────────────────────
  keypair:   so 2:(`cryEd25519Keypair; 1)  / seed(32) → pub(32)||secret(64)
  sign:      so 2:(`cryEd25519Sign;    2)  / [secret(64);msg] → sig(64)
  verify:    so 2:(`cryEd25519Verify;  3)  / [public(32);sig(64);msg] → boolean

  / ── X25519 key exchange ──────────────────────────────────────────────────
  x25519pub: so 2:(`cryX25519Public;   1)  / secret(32) → public(32)
  x25519:    so 2:(`cryX25519Shared;   2)  / [secret(32);public(32)] → shared(32)

  / ── Random & encoding ────────────────────────────────────────────────────
  random:    so 2:(`cryRandom;     1)   / n → C[n] secure random bytes
  hex:       so 2:(`cryHex;        1)   / bytes → lowercase hex text
  unhex:     so 2:(`cryUnhex;      1)   / hex text → bytes
  b64:       so 2:(`cryB64;        1)   / bytes → base64 text
  unb64:     so 2:(`cryUnb64;      1)   / base64 text → bytes
  equal:     so 2:(`cryEqual;      2)   / [a;b] → boolean (constant-time)
\d
