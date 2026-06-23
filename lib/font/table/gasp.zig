/// gasp — Grid-fitting And Scan-conversion Procedure.
/// doc/otf/table-gasp.md
///
/// version + parallel range columns. Each range applies its behavior bitfield
/// up to and including rangeMaxPPEM. Returned as a dict; the `maxPPEM`/`behavior`
/// columns flip to a table.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);
  const version = try r.uint16();
  const numRanges = try r.uint16();

  const ppem = k.KI(numRanges) orelse return null;
  const behavior = k.KI(numRanges) orelse {
    k.unref(ppem);
    return null;
  };
  const pp = k.ip(ppem) orelse return null;
  const bp = k.ip(behavior) orelse return null;
  var i: usize = 0;
  while (i < numRanges) : (i += 1) {
    pp[i] = try r.uint16();
    bp[i] = try r.uint16();
  }

  const keys = [_][*:0]const u8{ "version", "maxPPEM", "behavior" };
  const vals = [_]?k.K{ k.ki(version), ppem, behavior };
  return k.dict(&keys, &vals);
}
