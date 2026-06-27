/// .sbn spatial-index parser → table `+`id`xmin`ymin`xmax`ymax!(...).
///
/// The .sbn/.sbx pair is ESRI's proprietary (reverse-engineered) spatial index:
/// a binary tree of "bins", each holding feature ids with coordinates quantised
/// to 0–255 inside the file's bounding box. It is a query accelerator and is
/// fully regenerable from the .shp, so decoding it is low priority.
///
/// This reader is a conservative, type-stable stub: it validates the header and
/// returns the per-feature MBR table *schema* (empty unless decoding lands).
/// Full bin decoding is intentionally deferred until there is a fixture to test
/// against — shipping untested binary tree-walking would be worse than an
/// honest empty result.

const std = @import("std");
const k = @import("kbuild.zig");
const Cursor = @import("read.zig").Cursor;

pub fn parse(alloc: std.mem.Allocator, buf: []const u8) !?k.K {
  _ = alloc;
  if (buf.len >= 4) {
    var c = Cursor.init(buf);
    if (c.i32be() != 9994) return null; // not a shapefile-family index
  }
  // Empty (id; xmin; ymin; xmax; ymax) table — see module doc.
  var keys = [_][*:0]const u8{ "id", "xmin", "ymin", "xmax", "ymax" };
  var vals = [_]?k.K{ k.KI(0), k.KF(0), k.KF(0), k.KF(0), k.KF(0) };
  return k.table(&keys, &vals);
}
