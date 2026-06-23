/// PCLT — PCL 5 Table (deprecated).
/// doc/otf/table-PCLT.md
///
/// Legacy HP PCL metadata. The broadly useful scalar fields plus the `typeface`
/// string are normalized; characterComplement/fileName are dropped.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const version = try r.version16dot16();
  const fontNumber = try r.uint32();
  const pitch = try r.uint16();
  const xHeight = try r.uint16();
  const style = try r.uint16();
  const typeFamily = try r.uint16();
  const capHeight = try r.uint16();
  const symbolSet = try r.uint16();
  const typeface = try r.bytes(16);
  r.skip(8); // characterComplement[8]
  r.skip(6); // fileName[6]
  const strokeWeight = try r.int8();
  const widthType = try r.int8();
  const serifStyle = try r.uint8();

  // Trim NUL/space padding from the typeface name.
  var tlen: usize = typeface.len;
  while (tlen > 0 and (typeface[tlen - 1] == 0 or typeface[tlen - 1] == ' ')) tlen -= 1;

  const keys = [_][*:0]const u8{
    "version",   "fontNumber",  "pitch",      "xHeight",   "style",
    "typeFamily", "capHeight",  "symbolSet",  "typeface",  "strokeWeight",
    "widthType", "serifStyle",
  };
  const vals = [_]?k.K{
    k.kf(version),    k.ki(@bitCast(fontNumber)), k.ki(pitch),     k.ki(xHeight),  k.ki(style),
    k.ki(typeFamily), k.ki(capHeight),           k.ki(symbolSet), k.str(typeface[0..tlen]), k.ki(strokeWeight),
    k.ki(widthType),  k.ki(serifStyle),
  };
  return k.dict(&keys, &vals);
}
