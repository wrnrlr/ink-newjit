/// Per-face parse context shared with every table parser.
///
/// The container layer (sfnt.zig) parses the table directory and a handful of
/// "header" scalars that other tables depend on (glyph count, loca format,
/// metric counts), then hands a *const Ctx to each table's parse function.
/// Tables that need a sibling table reach it via `slice(tagFrom("..."))`.

const std = @import("std");
const reader = @import("reader.zig");

pub const TableRec = struct {
  tag: u32,
  off: u32,
  len: u32,
};

pub const Ctx = struct {
  /// The whole font file (a TTC shares one buffer across faces).
  file: []const u8,
  /// This face's table directory.
  recs: []const TableRec,

  // Header scalars resolved up-front (0 if the source table is absent).
  numGlyphs: u16 = 0,
  unitsPerEm: u16 = 0,
  indexToLocFormat: i16 = 0,
  numberOfHMetrics: u16 = 0,
  numberOfVMetrics: u16 = 0,

  /// Glyph data is in `glyf` (TrueType outlines) or `CFF `/`CFF2` (PostScript).
  isCFF: bool = false,

  /// Parsed glyph offsets from `loca` (length numGlyphs+1), empty for CFF.
  loca: []const u32 = &.{},

  /// The byte slice of a table by tag, bounds-checked, or null if absent.
  pub fn slice(self: *const Ctx, tag: u32) ?[]const u8 {
    for (self.recs) |r| {
      if (r.tag != tag) continue;
      const end = @as(usize, r.off) + @as(usize, r.len);
      if (r.off > self.file.len or end > self.file.len) return null;
      return self.file[r.off..end];
    }
    return null;
  }

  pub fn has(self: *const Ctx, tag: u32) bool {
    for (self.recs) |r| {
      if (r.tag == tag) return true;
    }
    return false;
  }
};
