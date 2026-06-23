/// OS/2 — OS/2 and Windows Metrics.
/// (No doc/otf spec file; implemented from the OpenType spec.)
///
/// Scalar dict of the broadly useful fields. weightClass/widthClass/fsSelection
/// drive the bold/italic/weight/width flags the K layer derives. Version-gated
/// fields (xHeight, capHeight, …) are 0 when the source font predates them.
/// `panose` is an I[10] vector, `unicodeRange` an I[4] bitfield vector.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const version = try r.uint16();
  const avgCharWidth = try r.int16();
  const weightClass = try r.uint16();
  const widthClass = try r.uint16();
  const fsType = try r.uint16();
  r.skip(20); // 8× sub/superscript int16 + strikeoutSize + strikeoutPos (not exposed)
  const familyClass = try r.int16();

  const panose = k.KI(10) orelse return null;
  if (k.ip(panose)) |p| {
    var i: usize = 0;
    while (i < 10) : (i += 1) p[i] = try r.uint8();
  }
  const unicodeRange = k.KI(4) orelse return null;
  if (k.ip(unicodeRange)) |p| {
    var i: usize = 0;
    while (i < 4) : (i += 1) p[i] = @bitCast(try r.uint32());
  }
  r.skip(4); // achVendID tag

  const fsSelection = try r.uint16();
  const firstChar = try r.uint16();
  const lastChar = try r.uint16();
  const typoAscender = try r.int16();
  const typoDescender = try r.int16();
  const typoLineGap = try r.int16();
  const winAscent = try r.uint16();
  const winDescent = try r.uint16();

  var xHeight: i32 = 0;
  var capHeight: i32 = 0;
  var defaultChar: i32 = 0;
  var breakChar: i32 = 0;
  var maxContext: i32 = 0;
  if (version >= 2) {
    r.skip(8); // ulCodePageRange1/2 (v1+)
    xHeight = try r.int16();
    capHeight = try r.int16();
    defaultChar = try r.uint16();
    breakChar = try r.uint16();
    maxContext = try r.uint16();
  }

  const keys = [_][*:0]const u8{
    "version",      "avgCharWidth",  "weightClass",  "widthClass",   "fsType",
    "familyClass",  "panose",        "unicodeRange", "fsSelection",  "firstChar",
    "lastChar",     "typoAscender",  "typoDescender", "typoLineGap", "winAscent",
    "winDescent",   "xHeight",       "capHeight",    "defaultChar",  "breakChar",
    "maxContext",
  };
  const vals = [_]?k.K{
    k.ki(version),      k.ki(avgCharWidth), k.ki(weightClass),  k.ki(widthClass),  k.ki(fsType),
    k.ki(familyClass),  panose,             unicodeRange,       k.ki(fsSelection), k.ki(firstChar),
    k.ki(lastChar),     k.ki(typoAscender), k.ki(typoDescender), k.ki(typoLineGap), k.ki(winAscent),
    k.ki(winDescent),   k.ki(xHeight),      k.ki(capHeight),    k.ki(defaultChar), k.ki(breakChar),
    k.ki(maxContext),
  };
  return k.dict(&keys, &vals);
}
