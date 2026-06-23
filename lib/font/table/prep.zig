/// prep — Control Value Program ("pre-program").
/// doc/otf/table-prep.md
///
/// TrueType instruction bytecode run whenever the point size or transform
/// changes. Exposed as an I vector of opcode bytes (0-255).

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  return k.ints(u8, data);
}
