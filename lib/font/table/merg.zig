/// MERG — Merge Table.
/// doc/otf/table-MERG.md
///
/// Rarely used; the merge-class matrix and class-def offsets are not expanded.
/// Header counts only: `version`, `mergeClassCount`, `classDefCount`.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);
  const version = try r.uint16();
  const mergeClassCount = try r.uint16();
  _ = try r.uint16(); // mergeDataOffset
  const classDefCount = try r.uint16();

  const keys = [_][*:0]const u8{ "version", "mergeClassCount", "classDefCount" };
  const vals = [_]?k.K{ k.ki(version), k.ki(mergeClassCount), k.ki(classDefCount) };
  return k.dict(&keys, &vals);
}
