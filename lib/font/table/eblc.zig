/// EBLC — Embedded Bitmap Location Table.
/// doc/otf/table-EBLC.md
///
/// Locators for monochrome/grayscale (EBDT) embedded bitmaps. EBLC and CBLC are
/// the identical format (only version number and companion data table differ),
/// so this re-exports the shared decode in cblc.zig. See cblc.zig for the
/// normalized shape and the per-glyph-offset deferral note.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;
const cblc = @import("cblc.zig");

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  return cblc.decode(data);
}
