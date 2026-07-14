/ test/crypto.k — smoke test for the crypto module (lib/crypto.k).
/ Run: ./zig-out/bin/ink test/crypto.k
2:"lib/crypto.k"

ok:{[nm;c] `0:nm," ",$[c;"ok";"FAIL"],"\n"}

/ ── Hash known-answer tests (vs shasum / md5) ──────────────────────────────
ok["sha256"; (crypto.hex crypto.sha256 "abc")~"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]
ok["sha1";   (crypto.hex crypto.sha1 "abc")~"a9993e364706816aba3e25717850c26c9cd0d89d"]
ok["sha512"; (crypto.hex crypto.sha512 "abc")~"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"]
ok["md5";    (crypto.hex crypto.md5 "abc")~"900150983cd24fb0d6963f7d28e17f72"]
/ NB: a single-char string is a char ATOM, not a C vector — enlist it (`,"k"`).
ok["hmac";   (crypto.hex crypto.hmac[,"k"; "abc"])~"342e519ce0ad6c03a36b98eeb3f1d130db4813b9df4d1160eda488d712dc78ee"]

/ digest lengths
ok["sha3256 len";  32~#crypto.sha3256 "abc"]
ok["blake3 len";   32~#crypto.blake3 "abc"]
ok["blake2b len";  32~#crypto.blake2b "abc"]

/ ── hex / base64 round-trips ───────────────────────────────────────────────
ok["hex round";  "hello"~crypto.unhex crypto.hex "hello"]
ok["b64 round";  "hello world"~crypto.unb64 crypto.b64 "hello world"]
ok["b64 val";    "aGVsbG8="~crypto.b64 "hello"]

/ ── random ──────────────────────────────────────────────────────────────────
ok["random len";  16~#crypto.random 16]
ok["random diff"; ~(crypto.random 16)~crypto.random 16]

/ ── AEAD: XChaCha20-Poly1305 round-trip + tamper detection ─────────────────
k: crypto.random 32
n: crypto.random 24
msg: "attack at dawn"
ct: crypto.encrypt[k; n; msg]
ok["xchacha rt";   msg~crypto.decrypt[k; n; ct]]
ok["xchacha size"; (#msg)+16=#ct]
/ wrong key → error value, not the plaintext
ok["xchacha auth"; ~msg~crypto.decrypt[crypto.random 32; n; ct]]

/ ── AEAD: AES-256-GCM round-trip ───────────────────────────────────────────
an: crypto.random 12
act: crypto.aesEncrypt[k; an; msg]
ok["aesgcm rt"; msg~crypto.aesDecrypt[k; an; act]]

/ ── KDF ─────────────────────────────────────────────────────────────────────
ok["hkdf len";   32~#crypto.hkdf["salt"; "ikm"; "info"]]
ok["hkdf det";   (crypto.hkdf["s"; "i"; "c"])~crypto.hkdf["s"; "i"; "c"]]
ok["pbkdf2 len"; 32~#crypto.pbkdf2["pw"; "salt"; 1000]]

/ ── Ed25519 sign / verify ───────────────────────────────────────────────────
seed: crypto.random 32
kp: crypto.keypair seed
pk: 32#kp        / public half  (first 32 bytes)
sk: 32_kp        / secret half  (drop 32 → last 64 bytes)
sig: crypto.sign[sk; "sign me"]
ok["ed25519 siglen"; 64~#sig]
ok["ed25519 verify"; crypto.verify[pk; sig; "sign me"]]
ok["ed25519 reject"; ~crypto.verify[pk; sig; "tampered"]]

/ ── X25519 ECDH: two parties derive the same shared secret ─────────────────
aSec: crypto.random 32
bSec: crypto.random 32
aPub: crypto.x25519pub aSec
bPub: crypto.x25519pub bSec
ok["x25519 agree"; (crypto.x25519[aSec; bPub])~crypto.x25519[bSec; aPub]]

/ ── constant-time equal ─────────────────────────────────────────────────────
ok["equal yes"; crypto.equal["abcd"; "abcd"]]
ok["equal no";  ~crypto.equal["abcd"; "abce"]]

`0:"done\n"
