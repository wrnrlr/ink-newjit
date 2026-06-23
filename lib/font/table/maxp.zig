/// maxp — Maximum Profile.
/// doc/otf/table-maxp.md
///
/// Version 0.5 (CFF) carries only numGlyphs; version 1.0 (TrueType) adds the
/// memory-sizing maxima. Both shapes are returned as a scalar dict.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const version = try r.fixed();
  const numGlyphs = try r.uint16();

  if (version < 1.0) {
    const keys = [_][*:0]const u8{ "version", "numGlyphs" };
    const vals = [_]?k.K{ k.kf(version), k.ki(numGlyphs) };
    return k.dict(&keys, &vals);
  }

  const maxPoints = try r.uint16();
  const maxContours = try r.uint16();
  const maxCompositePoints = try r.uint16();
  const maxCompositeContours = try r.uint16();
  const maxZones = try r.uint16();
  const maxTwilightPoints = try r.uint16();
  const maxStorage = try r.uint16();
  const maxFunctionDefs = try r.uint16();
  const maxInstructionDefs = try r.uint16();
  const maxStackElements = try r.uint16();
  const maxSizeOfInstructions = try r.uint16();
  const maxComponentElements = try r.uint16();
  const maxComponentDepth = try r.uint16();

  const keys = [_][*:0]const u8{
    "version",            "numGlyphs",          "maxPoints",        "maxContours",
    "maxCompositePoints", "maxCompositeContours", "maxZones",       "maxTwilightPoints",
    "maxStorage",         "maxFunctionDefs",    "maxInstructionDefs", "maxStackElements",
    "maxSizeOfInstructions", "maxComponentElements", "maxComponentDepth",
  };
  const vals = [_]?k.K{
    k.kf(version),            k.ki(numGlyphs),          k.ki(maxPoints),        k.ki(maxContours),
    k.ki(maxCompositePoints), k.ki(maxCompositeContours), k.ki(maxZones),       k.ki(maxTwilightPoints),
    k.ki(maxStorage),         k.ki(maxFunctionDefs),    k.ki(maxInstructionDefs), k.ki(maxStackElements),
    k.ki(maxSizeOfInstructions), k.ki(maxComponentElements), k.ki(maxComponentDepth),
  };
  return k.dict(&keys, &vals);
}
