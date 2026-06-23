/// EBDT — Embedded Bitmap Data Table.
/// doc/otf/table-EBDT.md
///
/// The raw monochrome/grayscale bitmap glyph data referenced by EBLC. EBDT and
/// CBDT share the same header, so this re-exports the shared decode in cbdt.zig.
/// See cbdt.zig for the normalized shape and the per-glyph extraction deferral.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;
const cbdt = @import("cbdt.zig");

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  return cbdt.decode(data);
}
