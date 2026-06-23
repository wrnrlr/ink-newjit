/// meta — Metadata Table.
/// doc/otf/table-meta.md
///
/// Tagged metadata blobs (e.g. `dlng`/`slng` design/supported languages, as
/// comma-delimited text). Normalized to parallel columns `tag` (L of 4-char
/// strings) and `value` (L of C strings, raw bytes).

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);
  _ = try r.uint32(); // version
  _ = try r.uint32(); // flags
  _ = try r.uint32(); // reserved
  const count32 = try r.uint32(); // dataMapsCount
  const count: usize = if (count32 > 4096) 0 else count32;

  const tag = k.KL(count) orelse return null;
  const value = k.KL(count) orelse return null;
  var i: usize = 0;
  while (i < count) : (i += 1) {
    const t = try r.uint32();
    const off = try r.uint32();
    const len = try r.uint32();
    const tb = reader.tagBytes(t);
    k.listSet(tag, i, k.str(&tb));
    const raw: []const u8 = if (off + len <= data.len) data[off .. off + len] else &.{};
    k.listSet(value, i, k.str(raw));
  }

  const keys = [_][*:0]const u8{ "tag", "value" };
  const vals = [_]?k.K{ tag, value };
  return k.dict(&keys, &vals);
}
