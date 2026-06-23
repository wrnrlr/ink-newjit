/// CFF2 — Compact Font Format, version 2.
/// doc/otf/table-CFF2.md
///
/// CFF2 is a slimmed, variation-aware successor to CFF1. It drops the Name /
/// String / charset / Encoding machinery and relies on the rest of the OpenType
/// font instead, but keeps the same INDEX and DICT byte formats — so the shared
/// `readIndex` / `readDict` helpers live in cff.zig and are reused here.
///
/// Layout (offsets from data[0]):
///   Header           — major(2), minor, hdrSize(5), topDictLength(u16)
///   Top DICT         — a single DICT at hdrSize, topDictLength bytes long
///   GlobalSubrINDEX  — at hdrSize + topDictLength
///   CharStringINDEX  — Top DICT op 17
///   FontDICTINDEX    — Top DICT op 12,36 (FDArray)
///   FontDICTSelect   — Top DICT op 12,37 (FDSelect; optional)
///   VariationStore   — Top DICT op 24 (vstore; optional)
///
/// CFF2 DICTs use the same operand encodings as CFF1 (29 → int32) and add the
/// `blend` operator; charstring interpretation is DEFERRED, so charstrings are
/// exposed as raw C strings only.
///
/// Normalized to a dict:
///   header       : dict {major; minor; hdrSize; topDictLength}
///   topDict      : dict (operator-name → F operand vector)
///   globalSubrs  : L of C strings (raw global subroutine charstrings)
///   charStrings  : L of C strings (one raw CFF2 charstring per glyph)
///   varStore     : common.itemVariationStore (present only if vstore is set)
///   fdArray      : L of dicts (the Font DICT INDEX entries)
///   fdSelect     : I per-glyph FD index (present only if FDSelect is set)

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;
const common = @import("../common.zig");
const cff = @import("cff.zig");

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

/// Read an INDEX as an L of C strings; empty list on failure.
fn indexList(data: []const u8, pos: usize) ?k.K {
  var idx = cff.readIndex(data, pos) catch return k.KL(0);
  defer idx.deinit();
  const list = k.KL(idx.entries.items.len) orelse return null;
  for (idx.entries.items, 0..) |e, i| k.listSet(list, i, k.str(e));
  return list;
}

/// Decode the FontDICTINDEX (FDArray) into an L of Font DICTs.
fn readFDArray(data: []const u8, off: usize) ?k.K {
  var idx = cff.readIndex(data, off) catch return k.KL(0);
  defer idx.deinit();
  const list = k.KL(idx.entries.items.len) orelse return null;
  for (idx.entries.items, 0..) |e, i| {
    var d = cff.readDict(e, true);
    defer d.deinit();
    k.listSet(list, i, d.toDict());
  }
  return list;
}

/// Decode an FDSelect table (format 0, 3 or 4) into an I[numGlyphs] of FD indices.
fn readFDSelect(data: []const u8, off: usize, numGlyphs: usize) ?k.K {
  var r = Reader.at(data, off);
  const format = r.uint8() catch return null;
  const out = k.KI(numGlyphs) orelse return null;
  const p = k.ip(out) orelse return out;
  var i: usize = 0;
  while (i < numGlyphs) : (i += 1) p[i] = 0;
  switch (format) {
    0 => {
      i = 0;
      while (i < numGlyphs) : (i += 1) p[i] = r.uint8() catch break;
    },
    3 => {
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
    },
    4 => {
      const nRanges = r.uint32() catch return out;
      var prevFirst = r.uint32() catch return out;
      var rng: usize = 0;
      while (rng < nRanges) : (rng += 1) {
        const fd = r.uint16() catch break;
        const next = r.uint32() catch break;
        var g: usize = prevFirst;
        while (g < next and g < numGlyphs) : (g += 1) p[g] = @intCast(fd);
        prevFirst = next;
      }
    },
    else => {},
  }
  return out;
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  if (data.len < 5) return null;
  var r = Reader.init(data);
  const major = try r.uint8();
  const minor = try r.uint8();
  const hdrSize = try r.uint8();
  const topDictLength = try r.uint16();

  const headerDict = k.dict(
    &[_][*:0]const u8{ "major", "minor", "hdrSize", "topDictLength" },
    &[_]?k.K{ k.ki(major), k.ki(minor), k.ki(hdrSize), k.ki(topDictLength) },
  );

  // Top DICT: a single DICT block (no enclosing INDEX in CFF2), topDictLength
  // bytes starting at hdrSize.
  const topStart: usize = hdrSize;
  const topEnd: usize = topStart + topDictLength;
  var topDict: cff.DictResult = if (topEnd <= data.len)
    cff.readDict(data[topStart..topEnd], true)
  else
    cff.readDict(&.{}, true);
  defer topDict.deinit();

  // GlobalSubrINDEX immediately follows the Top DICT.
  const globalSubrs = indexList(data, topEnd);

  // CharStringINDEX (op 17).
  var charStrings: ?k.K = k.KL(0);
  if (topDict.first("CharStrings")) |csOff| {
    charStrings = indexList(data, cff.offsetOf(csOff, data.len));
  }
  const numGlyphs: usize = if (charStrings) |cs|
    @intCast(@max(0, k.reg.?.kn(cs)))
  else
    ctx.numGlyphs;

  // FDArray (op 12,36) — required in CFF2; FDSelect (op 12,37) optional.
  var fdArray: ?k.K = null;
  var fdSelect: ?k.K = null;
  if (topDict.first("FDArray")) |fa| fdArray = readFDArray(data, cff.offsetOf(fa, data.len));
  if (topDict.first("FDSelect")) |fs| fdSelect = readFDSelect(data, cff.offsetOf(fs, data.len), numGlyphs);

  // VariationStore (op 24) — present only in variable fonts.
  var varStore: ?k.K = null;
  if (topDict.first("vstore")) |vs| {
    // The vstore offset points at a uint16 length field, then the
    // ItemVariationStore proper begins.
    const vsOff = cff.offsetOf(vs, data.len);
    if (vsOff <= data.len and vsOff + 2 <= data.len) varStore = common.itemVariationStore(data, vsOff + 2);
  }

  var keys: std.ArrayList([*:0]const u8) = .empty;
  var vals: std.ArrayList(?k.K) = .empty;
  defer keys.deinit(alloc);
  defer vals.deinit(alloc);

  keys.append(alloc, "header") catch {};
  vals.append(alloc, headerDict) catch {};
  keys.append(alloc, "topDict") catch {};
  vals.append(alloc, topDict.toDict()) catch {};
  keys.append(alloc, "globalSubrs") catch {};
  vals.append(alloc, globalSubrs) catch {};
  keys.append(alloc, "charStrings") catch {};
  vals.append(alloc, charStrings) catch {};
  if (varStore) |vs| {
    keys.append(alloc, "varStore") catch {};
    vals.append(alloc, vs) catch {};
  }
  if (fdArray) |fa| {
    keys.append(alloc, "fdArray") catch {};
    vals.append(alloc, fa) catch {};
  }
  if (fdSelect) |fs| {
    keys.append(alloc, "fdSelect") catch {};
    vals.append(alloc, fs) catch {};
  }

  return k.dict(keys.items, vals.items);
}
