/// Crypto extension for ink — thin bindings over Zig's `std.crypto`, loaded via
/// lib/crypto.k.  Everything speaks bytes: inputs and outputs are C (char/byte)
/// vectors, so the primitives compose freely — hash a message, HMAC it, feed a
/// derived key into an AEAD, encode the result as hex, and so on.
///
/// Build first:  zig build crypto
/// Load with:    2:"lib/crypto.k"   (or reference any `crypto.*` name to autoload)
///
/// K API (registered names → what lib/crypto.k binds them to):
///   Hashes (msg → raw digest bytes):
///     cryMd5 crySha1 crySha224 crySha256 crySha384 crySha512
///     crySha3256 crySha3512 cryBlake2b cryBlake2b512 cryBlake3
///   MAC (key,msg → tag):        cryHmac256  cryHmac512
///   KDF:  cryHkdf256[salt;ikm;info]  cryHkdf512[…]  cryPbkdf2[pass;salt;rounds]
///   AEAD (key,nonce,data → …):
///     XChaCha20-Poly1305:  cryEncrypt  cryDecrypt   (key 32, nonce 24)
///     AES-256-GCM:         cryAesEncrypt cryAesDecrypt (key 32, nonce 12)
///     Both return ciphertext||tag(16); decrypt returns plaintext or an error.
///   Signatures (Ed25519):
///     cryEd25519Keypair seed(32) → pub(32)||secret(64)
///     cryEd25519Sign[secret(64);msg] → sig(64)
///     cryEd25519Verify[public(32);sig(64);msg] → boolean
///   Key exchange (X25519):
///     cryX25519Public secret(32) → public(32)
///     cryX25519Shared[secret(32);public(32)] → shared(32)
///   Random:    cryRandom n → n cryptographically-secure bytes
///   Encoding:  cryHex/cryUnhex (lower hex)  cryB64/cryUnb64 (std base64)
///   cryEqual[a;b] → boolean (constant-time byte compare)

const std = @import("std");
const K = *anyopaque;

// Mirror of the canonical k-ABI table (src/kabi.zig).  We only wire up the
// handful of entries this extension uses.
const KRegistry = @import("kabi").KRegistry(K);

const KApi = struct {
  kb:         *const fn (c_int)   callconv(.c) ?K,
  kerr:       *const fn ()        callconv(.c) ?K,
  KC:         *const fn (i32)     callconv(.c) ?K,
  kn:         *const fn (?K)      callconv(.c) i32,
  ki_val:     *const fn (?K)      callconv(.c) i32,
  kcp:        *const fn (?K)      callconv(.c) ?[*]u8,
  ku:         *const fn (?K)      callconv(.c) void,
};
var g_api: ?KApi = null;

fn kb(v: bool) ?K       { return g_api.?.kb(if (v) 1 else 0); }
fn kerr() ?K            { return g_api.?.kerr(); }
fn kn(x: ?K) i32        { return g_api.?.kn(x); }
fn ki_val(x: ?K) i32    { return g_api.?.ki_val(x); }
fn kcp(x: ?K) ?[*]u8    { return g_api.?.kcp(x); }
fn ku(x: ?K) void       { g_api.?.ku(x); }

// Borrow the byte payload of a C (or any byte-backed) K value as a slice.
fn bytes(x: ?K) ?[]const u8 {
  const n = kn(x);
  if (n < 0) return null;
  if (n == 0) return &[_]u8{};
  const p = kcp(x) orelse return null;
  return p[0..@intCast(n)];
}

// Fresh C vector of length n whose contents are undefined (caller fills it).
fn newC(n: usize) ?K {
  return g_api.?.KC(@intCast(n));
}

// Fresh C vector holding a copy of `data`.
fn outBytes(data: []const u8) ?K {
  const out = newC(data.len) orelse return null;
  if (data.len > 0) @memcpy(kcp(out).?[0..data.len], data);
  return out;
}

// ── Hashes ────────────────────────────────────────────────────────────────
// One monadic export per algorithm; they all share the same shape via Hash().

fn hashFn(comptime Hsh: type) fn (?K) callconv(.c) ?K {
  return struct {
    fn f(x: ?K) callconv(.c) ?K {
      const m = bytes(x) orelse return null;
      var digest: [Hsh.digest_length]u8 = undefined;
      Hsh.hash(m, &digest, .{});
      return outBytes(&digest);
    }
  }.f;
}

const H = std.crypto.hash;
export const cryMd5       = hashFn(H.Md5);
export const crySha1      = hashFn(H.Sha1);
export const crySha224    = hashFn(H.sha2.Sha224);
export const crySha256    = hashFn(H.sha2.Sha256);
export const crySha384    = hashFn(H.sha2.Sha384);
export const crySha512    = hashFn(H.sha2.Sha512);
export const crySha3256   = hashFn(H.sha3.Sha3_256);
export const crySha3512   = hashFn(H.sha3.Sha3_512);
export const cryBlake2b   = hashFn(H.blake2.Blake2b256);
export const cryBlake2b512 = hashFn(H.blake2.Blake2b512);
export const cryBlake3    = hashFn(H.Blake3);

// ── HMAC ──────────────────────────────────────────────────────────────────
// cryHmacN[key; msg] → tag

fn hmacFn(comptime M: type) fn (?K, ?K) callconv(.c) ?K {
  return struct {
    fn f(key_k: ?K, msg_k: ?K) callconv(.c) ?K {
      const key = bytes(key_k) orelse return null;
      const msg = bytes(msg_k) orelse return null;
      var tag: [M.mac_length]u8 = undefined;
      M.create(&tag, msg, key);
      return outBytes(&tag);
    }
  }.f;
}

const Hmac = std.crypto.auth.hmac.sha2;
export const cryHmac256 = hmacFn(Hmac.HmacSha256);
export const cryHmac512 = hmacFn(Hmac.HmacSha512);

// ── HKDF (extract + expand to one PRK-length block) ─────────────────────────
// cryHkdfN[salt; ikm; info] → prk_length bytes

fn hkdfFn(comptime Hk: type) fn (?K, ?K, ?K) callconv(.c) ?K {
  return struct {
    fn f(salt_k: ?K, ikm_k: ?K, info_k: ?K) callconv(.c) ?K {
      const salt = bytes(salt_k) orelse return null;
      const ikm  = bytes(ikm_k) orelse return null;
      const info = bytes(info_k) orelse return null;
      const prk = Hk.extract(salt, ikm);
      var out: [Hk.prk_length]u8 = undefined;
      Hk.expand(&out, info, prk);
      return outBytes(&out);
    }
  }.f;
}

const Kdf = std.crypto.kdf.hkdf;
export const cryHkdf256 = hkdfFn(Kdf.HkdfSha256);
export const cryHkdf512 = hkdfFn(Kdf.HkdfSha512);

// cryPbkdf2[password; salt; rounds] → 32-byte derived key (HMAC-SHA256 PRF)
export fn cryPbkdf2(pass_k: ?K, salt_k: ?K, rounds_k: ?K) callconv(.c) ?K {
  const pass = bytes(pass_k) orelse return null;
  const salt = bytes(salt_k) orelse return null;
  const rounds = ki_val(rounds_k);
  if (rounds <= 0) return null;
  var dk: [32]u8 = undefined;
  std.crypto.pwhash.pbkdf2(&dk, pass, salt, @intCast(rounds), Hmac.HmacSha256) catch return null;
  return outBytes(&dk);
}

// ── AEAD ────────────────────────────────────────────────────────────────────
// encrypt[key; nonce; msg]  → ciphertext || tag(16)
// decrypt[key; nonce; ct]   → plaintext, or an error on authentication failure.

fn aeadEncrypt(comptime A: type) fn (?K, ?K, ?K) callconv(.c) ?K {
  return struct {
    fn f(key_k: ?K, nonce_k: ?K, msg_k: ?K) callconv(.c) ?K {
      const key = bytes(key_k) orelse return null;
      const nonce = bytes(nonce_k) orelse return null;
      const msg = bytes(msg_k) orelse return null;
      if (key.len != A.key_length or nonce.len != A.nonce_length) return null;
      const out = newC(msg.len + A.tag_length) orelse return null;
      const op = kcp(out).?;
      var tag: [A.tag_length]u8 = undefined;
      A.encrypt(op[0..msg.len], &tag, msg, "", nonce[0..A.nonce_length].*, key[0..A.key_length].*);
      @memcpy(op[msg.len..][0..A.tag_length], &tag);
      return out;
    }
  }.f;
}

fn aeadDecrypt(comptime A: type) fn (?K, ?K, ?K) callconv(.c) ?K {
  return struct {
    fn f(key_k: ?K, nonce_k: ?K, ct_k: ?K) callconv(.c) ?K {
      const key = bytes(key_k) orelse return null;
      const nonce = bytes(nonce_k) orelse return null;
      const ct = bytes(ct_k) orelse return null;
      if (key.len != A.key_length or nonce.len != A.nonce_length) return null;
      if (ct.len < A.tag_length) return kerr();
      const clen = ct.len - A.tag_length;
      const out = newC(clen) orelse return null;
      const op = kcp(out).?;
      A.decrypt(
        op[0..clen], ct[0..clen], ct[clen..][0..A.tag_length].*,
        "", nonce[0..A.nonce_length].*, key[0..A.key_length].*,
      ) catch { ku(out); return kerr(); };
      return out;
    }
  }.f;
}

const XChaCha = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const AesGcm  = std.crypto.aead.aes_gcm.Aes256Gcm;
export const cryEncrypt    = aeadEncrypt(XChaCha);
export const cryDecrypt    = aeadDecrypt(XChaCha);
export const cryAesEncrypt = aeadEncrypt(AesGcm);
export const cryAesDecrypt = aeadDecrypt(AesGcm);

// ── Ed25519 signatures ──────────────────────────────────────────────────────
const Ed25519 = std.crypto.sign.Ed25519;

// cryEd25519Keypair seed(32) → public(32) || secret(64)
export fn cryEd25519Keypair(seed_k: ?K) callconv(.c) ?K {
  const seed = bytes(seed_k) orelse return null;
  if (seed.len != Ed25519.KeyPair.seed_length) return null;
  const kp = Ed25519.KeyPair.generateDeterministic(seed[0..Ed25519.KeyPair.seed_length].*) catch return null;
  const pubk = kp.public_key.toBytes();
  const sec = kp.secret_key.toBytes();
  const out = newC(pubk.len + sec.len) orelse return null;
  const op = kcp(out).?;
  @memcpy(op[0..pubk.len], &pubk);
  @memcpy(op[pubk.len..][0..sec.len], &sec);
  return out;
}

// cryEd25519Sign[secret(64); msg] → signature(64)
export fn cryEd25519Sign(secret_k: ?K, msg_k: ?K) callconv(.c) ?K {
  const sec = bytes(secret_k) orelse return null;
  const msg = bytes(msg_k) orelse return null;
  if (sec.len != Ed25519.SecretKey.encoded_length) return null;
  const skey = Ed25519.SecretKey.fromBytes(sec[0..Ed25519.SecretKey.encoded_length].*) catch return null;
  const kp = Ed25519.KeyPair.fromSecretKey(skey) catch return null;
  const sig = kp.sign(msg, null) catch return null;
  const sb = sig.toBytes();
  return outBytes(&sb);
}

// cryEd25519Verify[public(32); sig(64); msg] → boolean
export fn cryEd25519Verify(pub_k: ?K, sig_k: ?K, msg_k: ?K) callconv(.c) ?K {
  const pubk = bytes(pub_k) orelse return null;
  const sigb = bytes(sig_k) orelse return null;
  const msg = bytes(msg_k) orelse return null;
  if (pubk.len != Ed25519.PublicKey.encoded_length) return kb(false);
  if (sigb.len != Ed25519.Signature.encoded_length) return kb(false);
  const pk = Ed25519.PublicKey.fromBytes(pubk[0..Ed25519.PublicKey.encoded_length].*) catch return kb(false);
  const sig = Ed25519.Signature.fromBytes(sigb[0..Ed25519.Signature.encoded_length].*);
  sig.verify(msg, pk) catch return kb(false);
  return kb(true);
}

// ── X25519 key exchange ─────────────────────────────────────────────────────
const X25519 = std.crypto.dh.X25519;

// cryX25519Public secret(32) → public(32)
export fn cryX25519Public(secret_k: ?K) callconv(.c) ?K {
  const sec = bytes(secret_k) orelse return null;
  if (sec.len != X25519.secret_length) return null;
  const pubk = X25519.recoverPublicKey(sec[0..X25519.secret_length].*) catch return null;
  return outBytes(&pubk);
}

// cryX25519Shared[secret(32); public(32)] → shared(32)
export fn cryX25519Shared(secret_k: ?K, pub_k: ?K) callconv(.c) ?K {
  const sec = bytes(secret_k) orelse return null;
  const pubk = bytes(pub_k) orelse return null;
  if (sec.len != X25519.secret_length or pubk.len != X25519.public_length) return null;
  const shared = X25519.scalarmult(sec[0..X25519.secret_length].*, pubk[0..X25519.public_length].*) catch return null;
  return outBytes(&shared);
}

// ── Random ──────────────────────────────────────────────────────────────────
// cryRandom n → n cryptographically-secure bytes
export fn cryRandom(n_k: ?K) callconv(.c) ?K {
  const n = ki_val(n_k);
  if (n < 0) return null;
  const out = newC(@intCast(n)) orelse return null;
  if (n == 0) return out;
  const io = std.Io.Threaded.global_single_threaded.io();
  io.randomSecure(kcp(out).?[0..@intCast(n)]) catch { ku(out); return null; };
  return out;
}

// ── Encoding helpers ────────────────────────────────────────────────────────
const hex_lower = "0123456789abcdef";

// cryHex bytes → lowercase hex text
export fn cryHex(x: ?K) callconv(.c) ?K {
  const b = bytes(x) orelse return null;
  const out = newC(b.len * 2) orelse return null;
  const op = kcp(out).?;
  for (b, 0..) |byte, i| {
    op[i * 2 + 0] = hex_lower[byte >> 4];
    op[i * 2 + 1] = hex_lower[byte & 0xf];
  }
  return out;
}

fn hexVal(c: u8) ?u8 {
  return switch (c) {
    '0'...'9' => c - '0',
    'a'...'f' => c - 'a' + 10,
    'A'...'F' => c - 'A' + 10,
    else => null,
  };
}

// cryUnhex hexText → bytes  (error on odd length or bad digit)
export fn cryUnhex(x: ?K) callconv(.c) ?K {
  const h = bytes(x) orelse return null;
  if (h.len % 2 != 0) return kerr();
  const out = newC(h.len / 2) orelse return null;
  const op = kcp(out).?;
  var i: usize = 0;
  while (i < h.len) : (i += 2) {
    const hi = hexVal(h[i]) orelse { ku(out); return kerr(); };
    const lo = hexVal(h[i + 1]) orelse { ku(out); return kerr(); };
    op[i / 2] = (hi << 4) | lo;
  }
  return out;
}

// cryB64 bytes → standard base64 text
export fn cryB64(x: ?K) callconv(.c) ?K {
  const b = bytes(x) orelse return null;
  const enc = std.base64.standard.Encoder;
  const out = newC(enc.calcSize(b.len)) orelse return null;
  _ = enc.encode(kcp(out).?[0..enc.calcSize(b.len)], b);
  return out;
}

// cryUnb64 base64Text → bytes  (error on malformed input)
export fn cryUnb64(x: ?K) callconv(.c) ?K {
  const s = bytes(x) orelse return null;
  const dec = std.base64.standard.Decoder;
  const n = dec.calcSizeForSlice(s) catch return kerr();
  const out = newC(n) orelse return null;
  dec.decode(kcp(out).?[0..n], s) catch { ku(out); return kerr(); };
  return out;
}

// cryEqual[a; b] → boolean, constant-time (false if lengths differ)
export fn cryEqual(a_k: ?K, b_k: ?K) callconv(.c) ?K {
  const a = bytes(a_k) orelse return null;
  const b = bytes(b_k) orelse return null;
  if (a.len != b.len) return kb(false);
  // Constant-time compare over a runtime length (timing_safe.eql is arrays only).
  var diff: u8 = 0;
  for (a, b) |x, y| diff |= x ^ y;
  return kb(diff == 0);
}

// ── Init ────────────────────────────────────────────────────────────────────
fn inkInit(reg: *anyopaque) void {
  const r: *const KRegistry = @ptrCast(@alignCast(reg));
  g_api = .{
    .kb = r.kb, .kerr = r.kerr, .KC = r.KC, .kn = r.kn,
    .ki_val = r.ki_val, .kcp = r.kcp, .ku = r.ku,
  };
  // Register every callable by name and arity.
  inline for (.{
    .{ "cryMd5", &cryMd5, 1 },            .{ "crySha1", &crySha1, 1 },
    .{ "crySha224", &crySha224, 1 },      .{ "crySha256", &crySha256, 1 },
    .{ "crySha384", &crySha384, 1 },      .{ "crySha512", &crySha512, 1 },
    .{ "crySha3256", &crySha3256, 1 },    .{ "crySha3512", &crySha3512, 1 },
    .{ "cryBlake2b", &cryBlake2b, 1 },    .{ "cryBlake2b512", &cryBlake2b512, 1 },
    .{ "cryBlake3", &cryBlake3, 1 },
    .{ "cryHmac256", &cryHmac256, 2 },    .{ "cryHmac512", &cryHmac512, 2 },
    .{ "cryHkdf256", &cryHkdf256, 3 },    .{ "cryHkdf512", &cryHkdf512, 3 },
    .{ "cryPbkdf2", &cryPbkdf2, 3 },
    .{ "cryEncrypt", &cryEncrypt, 3 },    .{ "cryDecrypt", &cryDecrypt, 3 },
    .{ "cryAesEncrypt", &cryAesEncrypt, 3 }, .{ "cryAesDecrypt", &cryAesDecrypt, 3 },
    .{ "cryEd25519Keypair", &cryEd25519Keypair, 1 },
    .{ "cryEd25519Sign", &cryEd25519Sign, 2 },
    .{ "cryEd25519Verify", &cryEd25519Verify, 3 },
    .{ "cryX25519Public", &cryX25519Public, 1 },
    .{ "cryX25519Shared", &cryX25519Shared, 2 },
    .{ "cryRandom", &cryRandom, 1 },
    .{ "cryHex", &cryHex, 1 },            .{ "cryUnhex", &cryUnhex, 1 },
    .{ "cryB64", &cryB64, 1 },            .{ "cryUnb64", &cryUnb64, 1 },
    .{ "cryEqual", &cryEqual, 2 },
  }) |e| {
    r.k_register(e[0], @ptrCast(e[1]), e[2]);
  }
}

export fn terse_init(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
export fn ink_ext_init_crypto(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
