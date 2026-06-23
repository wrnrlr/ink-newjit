/// DSIG — Digital Signature.
/// doc/otf/table-DSIG.md
///
/// The signature blobs are opaque PKCS#7; only the header is normalized:
/// `version`, `numSignatures`, `flags`.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);
  const version = try r.uint32();
  const numSignatures = try r.uint16();
  const flags = try r.uint16();

  const keys = [_][*:0]const u8{ "version", "numSignatures", "flags" };
  const vals = [_]?k.K{ k.ki(@bitCast(version)), k.ki(numSignatures), k.ki(flags) };
  return k.dict(&keys, &vals);
}
