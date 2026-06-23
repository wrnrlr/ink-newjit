/// CBDT — Color Bitmap Data Table.
/// doc/otf/table-CBDT.md (shares its format with EBDT; doc/otf/table-EBDT.md)
///
/// The raw bitmap glyph data referenced by CBLC. CBDT and EBDT share the same
/// header (just a version), so the decode lives here and ebdt.zig re-exports it.
///
/// Normalized to a dict { version, size }. `version` is major.minor as F; `size`
/// is the table length in bytes as I.
///
/// DEFERRED: per-glyph image extraction. The bitmap data for each glyph is
/// addressed indirectly through the CBLC/EBLC IndexSubtables (which we do not
/// expand to per-glyph offsets), so individual images cannot be sliced here.
/// Only the version and overall data size are exposed.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

/// Shared CBDT/EBDT body. `data` is the whole bitmap-data table slice.
pub fn decode(data: []const u8) reader.Error!?k.K {
  var r = reader.Reader.init(data);
  const major = try r.uint16();
  const minor = try r.uint16();
  const version = @as(f32, @floatFromInt(major)) + @as(f32, @floatFromInt(minor)) / 10.0;

  const keys = [_][*:0]const u8{ "version", "size" };
  const vals = [_]?k.K{ k.kf(version), k.ki(@intCast(data.len)) };
  return k.dict(&keys, &vals);
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  return decode(data);
}
