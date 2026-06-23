/// name — Naming Table.
/// (No doc/otf/table-name.md exists; implemented from the OpenType spec.)
///
/// Normalized to parallel columns over the name records, with each record's
/// string decoded to UTF-8:
///   platform encoding language nameID value
/// `value` is an L of C strings. Flip with `+` to get a per-record table.
/// Family name = nameID 1 (or 16), style = nameID 2 (or 17).

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

/// Decode one name string into `buf` as UTF-8, returning the written slice.
/// Unicode (platform 0) and Windows (platform 3) records are UTF-16BE; Mac
/// (platform 1) records are treated as Latin-1.
fn decode(platform: u16, raw: []const u8, buf: []u8) []u8 {
  if (platform == 0 or platform == 3) {
    var j: usize = 0;
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 2) {
      const cp: u21 = (@as(u21, raw[i]) << 8) | raw[i + 1];
      var tmp: [4]u8 = undefined;
      const n = std.unicode.utf8Encode(cp, &tmp) catch continue;
      if (j + n > buf.len) break;
      @memcpy(buf[j .. j + n], tmp[0..n]);
      j += n;
    }
    return buf[0..j];
  }
  // Latin-1 → UTF-8
  var j: usize = 0;
  for (raw) |b| {
    if (b < 0x80) {
      if (j >= buf.len) break;
      buf[j] = b;
      j += 1;
    } else {
      if (j + 2 > buf.len) break;
      buf[j] = 0xC0 | (b >> 6);
      buf[j + 1] = 0x80 | (b & 0x3F);
      j += 2;
    }
  }
  return buf[0..j];
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  _ = try r.uint16(); // format (0 or 1; langTagRecords of format 1 ignored)
  const count = try r.uint16();
  const stringOffset = try r.uint16();

  const platform = k.KI(count) orelse return null;
  const encoding = k.KI(count) orelse return null;
  const language = k.KI(count) orelse return null;
  const nameID = k.KI(count) orelse return null;
  const value = k.KL(count) orelse return null;
  const pp = k.ip(platform) orelse return null;
  const ep = k.ip(encoding) orelse return null;
  const gp = k.ip(language) orelse return null;
  const np = k.ip(nameID) orelse return null;

  var buf: [4096]u8 = undefined;
  var i: usize = 0;
  while (i < count) : (i += 1) {
    const plat = try r.uint16();
    const enc = try r.uint16();
    const lang = try r.uint16();
    const nid = try r.uint16();
    const len = try r.uint16();
    const off = try r.uint16();
    pp[i] = plat;
    ep[i] = enc;
    gp[i] = lang;
    np[i] = nid;

    const start = @as(usize, stringOffset) + off;
    const raw: []const u8 = if (start + len <= data.len) data[start .. start + len] else &.{};
    const s = decode(plat, raw, &buf);
    k.listSet(value, i, k.str(s));
  }

  const keys = [_][*:0]const u8{ "platform", "encoding", "language", "nameID", "value" };
  const vals = [_]?k.K{ platform, encoding, language, nameID, value };
  return k.dict(&keys, &vals);
}
