/// loca — Index to Location.
/// doc/otf/table-loca.md
///
/// The container already decoded loca (short/long format resolved via
/// head.indexToLocFormat) into ctx.loca; we just expose it as an I vector of
/// numGlyphs+1 byte offsets into glyf.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = data;
  return k.ints(u32, ctx.loca);
}
