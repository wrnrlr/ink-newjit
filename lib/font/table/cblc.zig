/// CBLC — Color Bitmap Location Table.
/// doc/otf/table-CBLC.md (shares its format with EBLC; doc/otf/table-EBLC.md)
///
/// Locators for color (CBDT) embedded bitmaps. CBLC and EBLC are the identical
/// format — only the version number and the companion data table (CBDT vs EBDT)
/// differ — so the decode lives here and eblc.zig re-exports it.
///
/// Normalized to a dict { version, strikes }. `version` is major.minor as F.
/// `strikes` is an L, one element per BitmapSize record, each a dict:
///   ppemX ppemY bitDepth startGlyph endGlyph ascender descender subtables
/// `ascender`/`descender` come from the horizontal SbitLineMetrics. `subtables`
/// is a columns dict over the IndexSubtableList (flip with `+`):
///   firstGlyph lastGlyph indexFormat imageFormat imageDataOffset
/// imageDataOffset is the offset into the companion CBDT/EBDT table.
///
/// DEFERRED: per-glyph image offsets (index formats 1–5) are not expanded — the
/// IndexSubHeader fields (format + imageDataOffset base) are exposed instead,
/// which is enough to locate each range's image data within CBDT/EBDT.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const alloc = std.heap.c_allocator;

/// Collected IndexSubtable headers for one strike.
const Subtables = struct {
  firstGlyph: std.ArrayList(i32) = .empty,
  lastGlyph: std.ArrayList(i32) = .empty,
  indexFormat: std.ArrayList(i32) = .empty,
  imageFormat: std.ArrayList(i32) = .empty,
  imageDataOffset: std.ArrayList(i32) = .empty,

  fn deinit(self: *Subtables) void {
    self.firstGlyph.deinit(alloc);
    self.lastGlyph.deinit(alloc);
    self.indexFormat.deinit(alloc);
    self.imageFormat.deinit(alloc);
    self.imageDataOffset.deinit(alloc);
  }

  fn toDict(self: *Subtables) ?k.K {
    const keys = [_][*:0]const u8{ "firstGlyph", "lastGlyph", "indexFormat", "imageFormat", "imageDataOffset" };
    const vals = [_]?k.K{
      k.ints(i32, self.firstGlyph.items),
      k.ints(i32, self.lastGlyph.items),
      k.ints(i32, self.indexFormat.items),
      k.ints(i32, self.imageFormat.items),
      k.ints(i32, self.imageDataOffset.items),
    };
    return k.dict(&keys, &vals);
  }
};

/// Shared CBLC/EBLC body. `data` is the whole location table slice.
pub fn decode(data: []const u8) reader.Error!?k.K {
  var r = reader.Reader.init(data);
  const major = try r.uint16();
  const minor = try r.uint16();
  const numSizes = try r.uint32();
  const version = @as(f32, @floatFromInt(major)) + @as(f32, @floatFromInt(minor)) / 10.0;

  const strikes = k.KL(numSizes) orelse return null;

  var si: usize = 0;
  while (si < numSizes) : (si += 1) {
    // BitmapSize record (48 bytes): offsets/counts, two SbitLineMetrics (12B each),
    // start/end glyph, ppemX/Y, bitDepth, flags.
    const indexSubtableListOffset = try r.uint32();
    _ = try r.uint32(); // indexSubtableListSize
    const numberOfIndexSubtables = try r.uint32();
    _ = try r.uint32(); // colorRef

    // hori SbitLineMetrics: ascender, descender, then 10 more bytes.
    const ascender = try r.int8();
    const descender = try r.int8();
    r.skip(10);
    // vert SbitLineMetrics: skip entirely (12 bytes).
    r.skip(12);

    const startGlyph = try r.uint16();
    const endGlyph = try r.uint16();
    const ppemX = try r.uint8();
    const ppemY = try r.uint8();
    const bitDepth = try r.uint8();
    _ = try r.int8(); // flags (horizontal/vertical metrics direction)

    var subs = Subtables{};
    defer subs.deinit();

    // IndexSubtableList lives at indexSubtableListOffset from table start; it is
    // an array of IndexSubtableRecord {firstGlyph, lastGlyph, offset-to-subtable}.
    var lr = reader.Reader.at(data, indexSubtableListOffset);
    var ix: usize = 0;
    while (ix < numberOfIndexSubtables) : (ix += 1) {
      const first = lr.uint16() catch break;
      const last = lr.uint16() catch break;
      const subOffset = lr.uint32() catch break;
      // The IndexSubHeader sits at indexSubtableListOffset + subOffset.
      var hr = reader.Reader.at(data, @as(usize, indexSubtableListOffset) + subOffset);
      const indexFormat = hr.uint16() catch 0;
      const imageFormat = hr.uint16() catch 0;
      const imageDataOffset = hr.uint32() catch 0;

      subs.firstGlyph.append(alloc, first) catch break;
      subs.lastGlyph.append(alloc, last) catch break;
      subs.indexFormat.append(alloc, indexFormat) catch break;
      subs.imageFormat.append(alloc, imageFormat) catch break;
      subs.imageDataOffset.append(alloc, @intCast(imageDataOffset)) catch break;
    }

    const keys = [_][*:0]const u8{ "ppemX", "ppemY", "bitDepth", "startGlyph", "endGlyph", "ascender", "descender", "subtables" };
    const vals = [_]?k.K{
      k.ki(ppemX),
      k.ki(ppemY),
      k.ki(bitDepth),
      k.ki(startGlyph),
      k.ki(endGlyph),
      k.ki(ascender),
      k.ki(descender),
      subs.toDict(),
    };
    k.listSet(strikes, si, k.dict(&keys, &vals));
  }

  const keys = [_][*:0]const u8{ "version", "strikes" };
  const vals = [_]?k.K{ k.kf(version), strikes };
  return k.dict(&keys, &vals);
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  return decode(data);
}
