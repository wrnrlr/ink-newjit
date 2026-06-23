/// CFF — Compact Font Format, version 1 (Adobe Tech Note #5176).
/// doc/otf/table-CFF.md (stub; decoded from the Adobe CFF spec).
///
/// This parser exposes the *structure* of a CFF FontSet plus the raw per-glyph
/// Type2 charstrings. It does NOT interpret charstrings into outlines — that is
/// a separate, deferred step (see lib/font/table/glyf.zig for the equivalent
/// outline materialization on the TrueType side).
///
/// Layout (all offsets are from the start of the table = data[0]):
///   Header                — major, minor, hdrSize, offSize
///   Name INDEX            — at hdrSize
///   Top DICT INDEX        — right after Name INDEX
///   String INDEX          — right after Top DICT INDEX
///   Global Subr INDEX     — right after String INDEX
/// The Top DICT then points (by absolute offset) at the charset, Encoding,
/// CharStrings INDEX, Private DICT (size+offset) and, for CID fonts, the FDArray
/// and FDSelect.
///
/// Normalized to a dict:
///   header       : dict {major; minor; hdrSize; offSize}
///   name         : L of C strings (the Name INDEX entries; usually one)
///   topDict      : dict (operator-name → F operand vector)
///   strings      : L of C strings (the String INDEX; SID 391+ string pool)
///   globalSubrs  : L of C strings (raw global subroutine charstrings)
///   charStrings  : L of C strings (one raw Type2 charstring per glyph)
///   privateDict  : dict (present only if the Top DICT has a Private entry)
///   localSubrs   : L of C strings (present only if the Private DICT has Subrs)
///   fdArray      : L of dicts   (CID fonts only — one Font DICT per FD)
///   fdSelect     : I per-glyph FD index (CID fonts only)
///
/// INDEX → an L of C strings (one per entry); DICT → an operator-keyed dict.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

// ── INDEX ────────────────────────────────────────────────────────────────────
//
// count u16, offSize u8, offsets[count+1] (offSize bytes each, 1-based, relative
// to the byte preceding the data block), then the contiguous data. An empty
// INDEX is just a count of 0 (2 bytes, no offSize/offsets).

pub const Index = struct {
  /// Each entry aliases the source buffer (no copy).
  entries: std.ArrayList([]const u8),
  /// First byte after the INDEX.
  endPos: usize,

  pub fn deinit(self: *Index) void {
    self.entries.deinit(alloc);
  }
};

/// Parse an INDEX at `pos` within `data`. Returns the borrowed entry slices and
/// the position just past the INDEX. On malformed data the entry list is left as
/// far as it could be filled and endPos points at the failure site.
pub fn readIndex(data: []const u8, pos: usize) reader.Error!Index {
  var r = Reader.at(data, pos);
  var out: Index = .{ .entries = .empty, .endPos = pos };
  const count = try r.uint16();
  if (count == 0) {
    out.endPos = r.pos;
    return out;
  }
  const offSize = try r.uint8();
  if (offSize < 1 or offSize > 4) return reader.Error.EndOfStream;

  // Read the count+1 offsets.
  const offs = alloc.alloc(u32, @as(usize, count) + 1) catch return reader.Error.EndOfStream;
  defer alloc.free(offs);
  var i: usize = 0;
  while (i < offs.len) : (i += 1) {
    var v: u32 = 0;
    var b: usize = 0;
    while (b < offSize) : (b += 1) v = (v << 8) | @as(u32, try r.uint8());
    offs[i] = v;
  }

  // Data starts at the byte *preceding* object data; offsets are 1-based from
  // there, so the data base is (cursor - 1).
  const dataBase = r.pos -% 1;
  i = 0;
  while (i < count) : (i += 1) {
    const lo = dataBase + offs[i];
    const hi = dataBase + offs[i + 1];
    if (hi < lo or hi > data.len) return reader.Error.EndOfStream;
    out.entries.append(alloc, data[lo..hi]) catch return reader.Error.EndOfStream;
  }
  out.endPos = dataBase + offs[count];
  return out;
}

/// An INDEX's entries as an L of C strings.
fn indexList(idx: *const Index) ?k.K {
  const list = k.KL(idx.entries.items.len) orelse return null;
  for (idx.entries.items, 0..) |e, i| k.listSet(list, i, k.str(e));
  return list;
}

/// Read an INDEX at `pos` and build it as an L of C strings, returning the K
/// value and the end position. On failure returns an empty list at `pos`.
fn indexAt(data: []const u8, pos: usize) struct { k: ?k.K, end: usize } {
  var idx = readIndex(data, pos) catch return .{ .k = k.KL(0), .end = pos };
  defer idx.deinit();
  return .{ .k = indexList(&idx), .end = idx.endPos };
}

// ── DICT ─────────────────────────────────────────────────────────────────────
//
// A flat byte stream: operands accumulate on a stack; an operator (1 byte, or
// 12+next for the two-byte "escape" range) consumes them as the value for that
// key. Operand encodings (shared by CFF1 and CFF2 DICTs):
//   32..246   → b0 - 139
//   247..250  → (b0-247)*256 + b1 + 108
//   251..254  → -(b0-251)*256 - b1 - 108
//   28        → int16 (b1 b2)
//   29        → int32 (b1..b4)        (DICT only)
//   30        → binary-coded-decimal real
// b0 values 0..21 are operators (12 = escape). The CFF2 32-bit / blend
// behaviour is handled by passing `cff2 = true` (29 still reads int32; blend
// operator 23 is keyed but its operands are left on the stack as-is).

/// Map an operator code to a short stable key. `esc` operators are the 12,xx
/// two-byte forms. Unknown operators get an "op_<n>" / "op_12_<n>" key written
/// into `buf`.
fn opName(op: u16, esc: bool, buf: []u8) [:0]const u8 {
  if (!esc) {
    return switch (op) {
      0 => "version",
      1 => "Notice",
      2 => "FullName",
      3 => "FamilyName",
      4 => "Weight",
      5 => "FontBBox",
      6 => "BlueValues",
      7 => "OtherBlues",
      8 => "FamilyBlues",
      9 => "FamilyOtherBlues",
      10 => "StdHW",
      11 => "StdVW",
      13 => "UniqueID",
      14 => "XUID",
      15 => "charset",
      16 => "Encoding",
      17 => "CharStrings",
      18 => "Private",
      19 => "Subrs",
      20 => "defaultWidthX",
      21 => "nominalWidthX",
      22 => "vsindex",
      23 => "blend",
      24 => "vstore",
      else => numKey(buf, "op_", op),
    };
  }
  return switch (op) {
    0 => "Copyright",
    1 => "isFixedPitch",
    2 => "ItalicAngle",
    3 => "UnderlinePosition",
    4 => "UnderlineThickness",
    5 => "PaintType",
    6 => "CharstringType",
    7 => "FontMatrix",
    8 => "StrokeWidth",
    9 => "BlueScale",
    10 => "BlueShift",
    11 => "BlueFuzz",
    12 => "StemSnapH",
    13 => "StemSnapV",
    14 => "ForceBold",
    17 => "LanguageGroup",
    18 => "ExpansionFactor",
    19 => "initialRandomSeed",
    20 => "SyntheticBase",
    21 => "PostScript",
    22 => "BaseFontName",
    23 => "BaseFontBlend",
    30 => "ROS",
    31 => "CIDFontVersion",
    32 => "CIDFontRevision",
    33 => "CIDFontType",
    34 => "CIDCount",
    35 => "UIDBase",
    36 => "FDArray",
    37 => "FDSelect",
    38 => "FontName",
    else => numKey(buf, "op_12_", op),
  };
}

fn numKey(buf: []u8, comptime prefix: []const u8, op: u16) [:0]const u8 {
  const s = std.fmt.bufPrint(buf, prefix ++ "{d}\x00", .{op}) catch {
    buf[0] = '?';
    buf[1] = 0;
    return buf[0..1 :0];
  };
  return buf[0 .. s.len - 1 :0];
}

/// Parse a real (operator 30) at the reader, appending its f64 value to `stack`.
fn readReal(r: *Reader, stack: *std.ArrayList(f64)) void {
  var tmp: [64]u8 = undefined;
  var n: usize = 0;
  done: while (true) {
    const byte = r.uint8() catch break;
    var half: u8 = 0;
    while (half < 2) : (half += 1) {
      const nib: u8 = if (half == 0) (byte >> 4) else (byte & 0x0F);
      const s: []const u8 = switch (nib) {
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9 => &[_]u8{'0' + nib},
        0xa => ".",
        0xb => "E",
        0xc => "E-",
        0xe => "-",
        0xf => break :done,
        else => "", // 0xd reserved → skip
      };
      for (s) |ch| {
        if (n < tmp.len) {
          tmp[n] = ch;
          n += 1;
        }
      }
    }
  }
  const val = std.fmt.parseFloat(f64, tmp[0..n]) catch 0;
  stack.append(alloc, val) catch {};
}

pub const DictResult = struct {
  /// operator-name keys (each its own owned, NUL-terminated buffer).
  keys: std.ArrayList([:0]const u8),
  /// parallel F-vector values.
  vals: std.ArrayList(?k.K),

  pub fn deinit(self: *DictResult) void {
    for (self.keys.items) |kk| alloc.free(kk[0 .. kk.len + 1]);
    self.keys.deinit(alloc);
    self.vals.deinit(alloc);
  }

  /// Look up an operator's first operand (as usize) by key. Returns null if absent.
  pub fn first(self: *const DictResult, name: []const u8) ?f64 {
    for (self.keys.items, self.vals.items) |kk, vv| {
      if (!std.mem.eql(u8, kk, name)) continue;
      if (vv) |v| if (k.fp(v)) |p| if (k.reg.?.kn(v) > 0) return p[0];
      return null;
    }
    return null;
  }

  /// Look up an operator's i-th operand, or null.
  pub fn nth(self: *const DictResult, name: []const u8, i: usize) ?f64 {
    for (self.keys.items, self.vals.items) |kk, vv| {
      if (!std.mem.eql(u8, kk, name)) continue;
      if (vv) |v| if (k.fp(v)) |p| if (k.reg.?.kn(v) > @as(i32, @intCast(i))) return p[i];
      return null;
    }
    return null;
  }

  pub fn toDict(self: *const DictResult) ?k.K {
    const n = self.keys.items.len;
    const kptrs = std.heap.c_allocator.alloc([*:0]const u8, n) catch return null;
    defer std.heap.c_allocator.free(kptrs);
    for (self.keys.items, 0..) |kk, i| kptrs[i] = kk.ptr;
    const d = k.reg.?.k_make_dict(@intCast(n), kptrs.ptr, self.vals.items.ptr);
    for (self.vals.items) |v| k.unref(v);
    return d;
  }
};

/// Decode a DICT byte block into operator-keyed F-vector entries. The result
/// owns its key buffers; callers must `deinit` it. `cff2` selects 32-bit-aware
/// behaviour for the blend operator (operands are kept verbatim either way).
pub fn readDict(block: []const u8, cff2: bool) DictResult {
  _ = cff2;
  var res: DictResult = .{ .keys = .empty, .vals = .empty };
  var stack: std.ArrayList(f64) = .empty;
  defer stack.deinit(alloc);
  var r = Reader.init(block);

  while (!r.eof()) {
    const b0 = r.uint8() catch break;
    if (b0 >= 32 and b0 <= 246) {
      stack.append(alloc, @as(f64, @floatFromInt(@as(i32, b0) - 139))) catch {};
    } else if (b0 >= 247 and b0 <= 250) {
      const b1 = r.uint8() catch break;
      stack.append(alloc, @as(f64, @floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108))) catch {};
    } else if (b0 >= 251 and b0 <= 254) {
      const b1 = r.uint8() catch break;
      stack.append(alloc, @as(f64, @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108))) catch {};
    } else if (b0 == 28) {
      const v = r.int16() catch break;
      stack.append(alloc, @as(f64, @floatFromInt(v))) catch {};
    } else if (b0 == 29) {
      const v = r.int32() catch break;
      stack.append(alloc, @as(f64, @floatFromInt(v))) catch {};
    } else if (b0 == 30) {
      readReal(&r, &stack);
    } else if (b0 <= 21) {
      // Operator. 12 introduces a two-byte escape code.
      var op: u16 = b0;
      var esc = false;
      if (b0 == 12) {
        op = r.uint8() catch break;
        esc = true;
      }
      var buf: [16]u8 = undefined;
      const name = opName(op, esc, &buf);
      // Own a NUL-terminated copy of the key.
      const owned = alloc.allocSentinel(u8, name.len, 0) catch {
        stack.clearRetainingCapacity();
        continue;
      };
      @memcpy(owned[0..name.len], name);
      const vec = k.floats(f64, stack.items);
      res.keys.append(alloc, owned) catch {
        alloc.free(owned[0 .. name.len + 1]);
        k.unref(vec);
      };
      res.vals.append(alloc, vec) catch {};
      stack.clearRetainingCapacity();
    } else {
      // b0 in 22..27 / 31 are reserved in DICT; ignore and clear.
      stack.clearRetainingCapacity();
    }
  }
  return res;
}

/// Clamp a DICT operand (a float offset) to a sane byte position. Negative,
/// non-finite or absurdly large values become an out-of-range offset so the
/// subsequent bounds check fails cleanly instead of panicking on @intFromFloat.
pub fn offsetOf(v: f64, limit: usize) usize {
  if (!(v >= 0) or v > @as(f64, @floatFromInt(limit))) return limit + 1;
  return @intFromFloat(v);
}

// ── FDSelect / FDArray (CID fonts) ────────────────────────────────────────────

/// Decode an FDSelect table (format 0 or 3) into an I[numGlyphs] of FD indices.
fn readFDSelect(data: []const u8, off: usize, numGlyphs: usize) ?k.K {
  var r = Reader.at(data, off);
  const format = r.uint8() catch return null;
  const out = k.KI(numGlyphs) orelse return null;
  const p = k.ip(out) orelse return out;
  var i: usize = 0;
  while (i < numGlyphs) : (i += 1) p[i] = 0;
  if (format == 0) {
    i = 0;
    while (i < numGlyphs) : (i += 1) p[i] = r.uint8() catch break;
  } else if (format == 3) {
    const nRanges = r.uint16() catch return out;
    var prevFirst = r.uint16() catch return out;
    var rng: usize = 0;
    while (rng < nRanges) : (rng += 1) {
      const fd = r.uint8() catch break;
      const next = r.uint16() catch break;
      var g: usize = prevFirst;
      while (g < next and g < numGlyphs) : (g += 1) p[g] = fd;
      prevFirst = next;
    }
  }
  return out;
}

/// Decode the FDArray (a Font DICT INDEX) into an L of dicts.
fn readFDArray(data: []const u8, off: usize) ?k.K {
  var idx = readIndex(data, off) catch return k.KL(0);
  defer idx.deinit();
  const list = k.KL(idx.entries.items.len) orelse return null;
  for (idx.entries.items, 0..) |e, i| {
    var d = readDict(e, false);
    defer d.deinit();
    k.listSet(list, i, d.toDict());
  }
  return list;
}

/// For a CID font, the local subrs live in each Font DICT's Private DICT.
/// → L (one per FD) of (L of C strings); empty L when an FD has no Subrs.
fn readFDLocalSubrs(data: []const u8, off: usize) ?k.K {
  var idx = readIndex(data, off) catch return k.KL(0);
  defer idx.deinit();
  const list = k.KL(idx.entries.items.len) orelse return null;
  for (idx.entries.items, 0..) |e, i| {
    var d = readDict(e, false);
    defer d.deinit();
    var subrs: ?k.K = k.KL(0);
    if (d.first("Private")) |psize| {
      const poff = d.nth("Private", 1) orelse 0;
      const pStart = offsetOf(poff, data.len);
      const pLen = offsetOf(psize, data.len);
      if (pStart <= data.len and pStart + pLen <= data.len and pLen > 0) {
        var pd = readDict(data[pStart .. pStart + pLen], false);
        defer pd.deinit();
        if (pd.first("Subrs")) |subrOff| {
          subrs = indexAt(data, offsetOf(@as(f64, @floatFromInt(pStart)) + subrOff, data.len)).k;
        }
      }
    }
    k.listSet(list, i, subrs);
  }
  return list;
}

// ── parse ─────────────────────────────────────────────────────────────────────

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  if (data.len < 4) return null;
  var r = Reader.init(data);
  const major = try r.uint8();
  const minor = try r.uint8();
  const hdrSize = try r.uint8();
  const offSize = try r.uint8();

  const headerDict = k.dict(
    &[_][*:0]const u8{ "major", "minor", "hdrSize", "offSize" },
    &[_]?k.K{ k.ki(major), k.ki(minor), k.ki(hdrSize), k.ki(offSize) },
  );

  // The Name, Top DICT, String and Global Subr INDEXes follow the header in
  // sequence, each starting where the previous ended.
  const nameIdx = indexAt(data, hdrSize);

  // The Top DICT INDEX holds one Top DICT per font in the set; OpenType requires
  // exactly one. Decode the first entry (and remember where the INDEX ends so the
  // String and Global Subr INDEXes can follow it).
  var topEnd = nameIdx.end;
  var topDict: DictResult = blk: {
    var ti = readIndex(data, nameIdx.end) catch break :blk DictResult{ .keys = .empty, .vals = .empty };
    defer ti.deinit();
    topEnd = ti.endPos;
    if (ti.entries.items.len == 0) break :blk DictResult{ .keys = .empty, .vals = .empty };
    break :blk readDict(ti.entries.items[0], false);
  };
  defer topDict.deinit();

  const strIdx = indexAt(data, topEnd);
  const gsubr = indexAt(data, strIdx.end);

  // CharStrings INDEX (op 17): one raw Type2 charstring per glyph.
  var charStrings: ?k.K = k.KL(0);
  if (topDict.first("CharStrings")) |csOff| {
    charStrings = indexAt(data, offsetOf(csOff, data.len)).k;
  }

  // Private DICT (op 18 = size offset) → Local Subrs (op 19, relative to Private).
  var privateDict: ?k.K = null;
  var localSubrs: ?k.K = null;
  if (topDict.first("Private")) |psize| {
    const poff = topDict.nth("Private", 1) orelse 0;
    const pStart = offsetOf(poff, data.len);
    const pLen = offsetOf(psize, data.len);
    if (pStart <= data.len and pStart + pLen <= data.len and pLen > 0) {
      var pd = readDict(data[pStart .. pStart + pLen], false);
      defer pd.deinit();
      privateDict = pd.toDict();
      if (pd.first("Subrs")) |subrOff| {
        localSubrs = indexAt(data, offsetOf(@as(f64, @floatFromInt(pStart)) + subrOff, data.len)).k;
      }
    }
  }

  // CID fonts (ROS present) carry an FDArray and FDSelect.
  var fdArray: ?k.K = null;
  var fdLocalSubrs: ?k.K = null;
  var fdSelect: ?k.K = null;
  if (topDict.first("ROS") != null) {
    if (topDict.first("FDArray")) |fa| {
      fdArray = readFDArray(data, offsetOf(fa, data.len));
      fdLocalSubrs = readFDLocalSubrs(data, offsetOf(fa, data.len));
    }
    if (topDict.first("FDSelect")) |fs| {
      const ng: usize = if (charStrings) |cs| @intCast(@max(0, k.reg.?.kn(cs))) else ctx.numGlyphs;
      fdSelect = readFDSelect(data, offsetOf(fs, data.len), ng);
    }
  }

  // Assemble. Optional members are only included when present.
  var keys: std.ArrayList([*:0]const u8) = .empty;
  var vals: std.ArrayList(?k.K) = .empty;
  defer keys.deinit(alloc);
  defer vals.deinit(alloc);

  keys.append(alloc, "header") catch {};
  vals.append(alloc, headerDict) catch {};
  keys.append(alloc, "name") catch {};
  vals.append(alloc, nameIdx.k) catch {};
  keys.append(alloc, "topDict") catch {};
  vals.append(alloc, topDict.toDict()) catch {};
  keys.append(alloc, "strings") catch {};
  vals.append(alloc, strIdx.k) catch {};
  keys.append(alloc, "globalSubrs") catch {};
  vals.append(alloc, gsubr.k) catch {};
  keys.append(alloc, "charStrings") catch {};
  vals.append(alloc, charStrings) catch {};
  if (privateDict) |pd| {
    keys.append(alloc, "privateDict") catch {};
    vals.append(alloc, pd) catch {};
  }
  if (localSubrs) |ls| {
    keys.append(alloc, "localSubrs") catch {};
    vals.append(alloc, ls) catch {};
  }
  if (fdArray) |fa| {
    keys.append(alloc, "fdArray") catch {};
    vals.append(alloc, fa) catch {};
  }
  if (fdLocalSubrs) |fl| {
    keys.append(alloc, "fdLocalSubrs") catch {};
    vals.append(alloc, fl) catch {};
  }
  if (fdSelect) |fs| {
    keys.append(alloc, "fdSelect") catch {};
    vals.append(alloc, fs) catch {};
  }

  return k.dict(keys.items, vals.items);
}
