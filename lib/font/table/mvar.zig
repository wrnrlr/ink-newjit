/// MVAR — Metrics Variations Table.
/// doc/otf/table-MVAR.md
///
/// Provides variation deltas for font-wide metric values (OS/2, hhea, vhea,
/// post, gasp). An array of value records pairs a four-byte tag with a delta-set
/// index (outer, inner) into the table's ItemVariationStore. version is
/// normalized to major.minor; the value records are returned as parallel
/// columns {tag; outer; inner}. valueRecordSize is honored for striding so
/// future record extensions are skipped cleanly.

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
  _ = try r.uint16(); // reserved
  const valueRecordSize = try r.uint16();
  const valueRecordCount = try r.uint16();
  const itemVariationStoreOffset = try r.uint16();

  const version: f32 = @as(f32, @floatFromInt(major)) + (@as(f32, @floatFromInt(minor)) / 10.0);

  // The value records begin immediately after the header (12 bytes in).
  const recordsBase: usize = r.pos;

  const tag = k.KL(valueRecordCount) orelse return null;
  const outer = k.KI(valueRecordCount) orelse {
    k.unref(tag);
    return null;
  };
  const inner = k.KI(valueRecordCount) orelse {
    k.unref(tag);
    k.unref(outer);
    return null;
  };
  const op = k.ip(outer);
  const ip = k.ip(inner);

  var i: usize = 0;
  while (i < valueRecordCount) : (i += 1) {
    var rr = reader.Reader.at(data, recordsBase + i * valueRecordSize);
    const valueTag = rr.tag() catch 0;
    const deltaSetOuterIndex = rr.uint16() catch 0;
    const deltaSetInnerIndex = rr.uint16() catch 0;
    k.listSet(tag, i, k.str(&reader.tagBytes(valueTag)));
    if (op) |p| p[i] = deltaSetOuterIndex;
    if (ip) |p| p[i] = deltaSetInnerIndex;
  }

  const recKeys = [_][*:0]const u8{ "tag", "outer", "inner" };
  const recVals = [_]?k.K{ tag, outer, inner };
  const valueRecords = k.dict(&recKeys, &recVals);

  const keys = [_][*:0]const u8{ "version", "valueRecords", "varStore" };
  const vals = [_]?k.K{
    k.kf(version),
    valueRecords,
    if (itemVariationStoreOffset != 0) common.itemVariationStore(data, itemVariationStoreOffset) else k.KL(0),
  };
  return k.dict(&keys, &vals);
}
