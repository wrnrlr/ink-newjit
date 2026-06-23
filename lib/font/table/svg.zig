/// SVG — The SVG (Scalable Vector Graphics) Table.
/// doc/otf/table-SVG.md
///
/// SVG glyph descriptions, one document per record covering a glyph ID range.
/// Normalized to a dict { startGid, endGid, doc }: startGid/endGid are
/// equal-length I columns over the document records (one row each), and `doc`
/// is an L of raw SVG document byte strings. Documents may be gzip-compressed
/// per spec; the bytes are kept verbatim (not decompressed).

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);
  _ = try r.uint16(); // version (set to 0)
  const listOffset = try r.uint32();
  _ = try r.uint32(); // reserved

  if (listOffset >= data.len) return null;
  // svgDocOffset fields are measured from the start of the document list.
  const list = data[listOffset..];

  var lr = reader.Reader.init(list);
  const numEntries = try lr.uint16();

  const startGid = k.KI(numEntries) orelse return null;
  const endGid = k.KI(numEntries) orelse return null;
  const doc = k.KL(numEntries) orelse return null;
  const sp = k.ip(startGid) orelse return null;
  const ep = k.ip(endGid) orelse return null;

  var i: usize = 0;
  while (i < numEntries) : (i += 1) {
    const start = try lr.uint16();
    const end = try lr.uint16();
    const docOffset = try lr.uint32();
    const docLength = try lr.uint32();
    sp[i] = start;
    ep[i] = end;

    const begin = docOffset;
    const finish = @as(usize, docOffset) + docLength;
    const raw: []const u8 = if (begin <= list.len and finish <= list.len and begin <= finish)
      list[begin..finish]
    else
      &.{};
    k.listSet(doc, i, k.str(raw));
  }

  const keys = [_][*:0]const u8{ "startGid", "endGid", "doc" };
  const vals = [_]?k.K{ startGid, endGid, doc };
  return k.dict(&keys, &vals);
}
