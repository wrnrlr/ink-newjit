/// VVAR — Vertical Metrics Variations Table.
/// doc/otf/table-VVAR.md
///
/// The vertical analogue of HVAR. Carries an ItemVariationStore plus up to four
/// optional DeltaSetIndexMap subtables: advance heights, top and bottom side
/// bearings, and Y coordinates of vertical origins. version is normalized to
/// major.minor. Each mapping is included only when its header offset is
/// non-zero; an absent advanceMap means glyph ids are used directly as the
/// varStore inner index (outer index zero).

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;
const common = @import("../common.zig");

const alloc = std.heap.c_allocator;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const major = try r.uint16();
  const minor = try r.uint16();
  const itemVariationStoreOffset = try r.uint32();
  const advanceHeightMappingOffset = try r.uint32();
  const tsbMappingOffset = try r.uint32();
  const bsbMappingOffset = try r.uint32();
  const vOrgMappingOffset = try r.uint32();

  const version: f32 = @as(f32, @floatFromInt(major)) + (@as(f32, @floatFromInt(minor)) / 10.0);

  var keys: std.ArrayList([*:0]const u8) = .empty;
  var vals: std.ArrayList(?k.K) = .empty;
  defer keys.deinit(alloc);
  defer vals.deinit(alloc);

  keys.append(alloc, "version") catch {};
  vals.append(alloc, k.kf(version)) catch {};

  keys.append(alloc, "varStore") catch {};
  vals.append(alloc, common.itemVariationStore(data, itemVariationStoreOffset)) catch {};

  if (advanceHeightMappingOffset != 0) {
    keys.append(alloc, "advanceMap") catch {};
    vals.append(alloc, common.deltaSetIndexMap(data, advanceHeightMappingOffset)) catch {};
  }
  if (tsbMappingOffset != 0) {
    keys.append(alloc, "tsbMap") catch {};
    vals.append(alloc, common.deltaSetIndexMap(data, tsbMappingOffset)) catch {};
  }
  if (bsbMappingOffset != 0) {
    keys.append(alloc, "bsbMap") catch {};
    vals.append(alloc, common.deltaSetIndexMap(data, bsbMappingOffset)) catch {};
  }
  if (vOrgMappingOffset != 0) {
    keys.append(alloc, "vorgMap") catch {};
    vals.append(alloc, common.deltaSetIndexMap(data, vOrgMappingOffset)) catch {};
  }

  return k.dict(keys.items, vals.items);
}
