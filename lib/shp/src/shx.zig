/// .shx index parser → dict `offset`len!(I;I).
///
/// One entry per record: byte offset into the .shp file where the record begins
/// (after its 8-byte record header → +8 reaches the content), and the record's
/// content length in bytes. Both are stored on disk as 16-bit-word counts and
/// converted to bytes here.

const std = @import("std");
const k = @import("kbuild.zig");
const Cursor = @import("read.zig").Cursor;

pub fn parse(alloc: std.mem.Allocator, buf: []const u8) !?k.K {
  if (buf.len < 100) return null;
  var c = Cursor.init(buf);
  if (c.i32be() != 9994) return null;

  const nrec = (buf.len -| 100) / 8;
  var offs = try alloc.alloc(i32, nrec);
  defer alloc.free(offs);
  var lens = try alloc.alloc(i32, nrec);
  defer alloc.free(lens);

  c.seek(100);
  for (0..nrec) |i| {
    offs[i] = c.i32be() *| 2; // word offset → byte offset
    lens[i] = c.i32be() *| 2; // content length words → bytes
  }

  var keys = [_][*:0]const u8{ "offset", "len" };
  var vals = [_]?k.K{ k.ints(offs), k.ints(lens) };
  return k.dict(&keys, &vals);
}
