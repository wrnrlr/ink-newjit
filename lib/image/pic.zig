/// Softimage PIC decode, ported from stb_image's public-domain PIC reader
/// (8-bit channels, uncompressed / pure-RLE / mixed-RLE packets). Returns an
/// 8-bit common.Image with 3 or 4 channels.

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const common = @import("common.zig");

const Alloc = std.mem.Allocator;
const Error = common.Error;
const Image = common.Image;

pub fn isPic(file: []const u8) bool {
  if (file.len < 92) return false;
  const magic = [4]u8{ 0x53, 0x80, 0xF6, 0x34 };
  if (!std.mem.eql(u8, file[0..4], &magic)) return false;
  return std.mem.eql(u8, file[88..92], "PICT");
}

const Packet = struct { size: u8, type: u8, channel: u8 };

fn readVal(r: *Reader, channel: u8, dest: []u8) void {
  var mask: u8 = 0x80;
  var i: usize = 0;
  while (i < 4) : ({
    i += 1;
    mask >>= 1;
  }) {
    if (channel & mask != 0) dest[i] = r.get8();
  }
}

fn copyVal(channel: u8, dest: []u8, src: []const u8) void {
  var mask: u8 = 0x80;
  var i: usize = 0;
  while (i < 4) : ({
    i += 1;
    mask >>= 1;
  }) {
    if (channel & mask != 0) dest[i] = src[i];
  }
}

pub fn decode(alloc: Alloc, file: []const u8) Error!Image {
  var r = Reader.init(file);
  var i: usize = 0;
  while (i < 92) : (i += 1) _ = r.get8();
  const w: usize = r.get16be();
  const h: usize = r.get16be();
  if (w == 0 or h == 0) return Error.Corrupt;
  if (w > common.MAX_DIM or h > common.MAX_DIM) return Error.TooLarge;
  _ = r.get32be(); // ratio
  _ = r.get16be(); // fields
  _ = r.get16be(); // pad

  const rgba = alloc.alloc(u8, try common.checkedSize(w, h, 4)) catch return Error.OutOfMemory;
  errdefer alloc.free(rgba);
  @memset(rgba, 0xff);

  // Packet list
  var packets: [10]Packet = undefined;
  var num_packets: usize = 0;
  var act_comp: u8 = 0;
  var chained: u8 = 1;
  while (chained != 0) {
    if (num_packets == packets.len) return Error.Corrupt;
    chained = r.get8();
    const size = r.get8();
    const typ = r.get8();
    const channel = r.get8();
    packets[num_packets] = .{ .size = size, .type = typ, .channel = channel };
    num_packets += 1;
    act_comp |= channel;
    if (r.atEof()) return Error.Corrupt;
    if (size != 8) return Error.Unsupported;
  }
  const comp: usize = if (act_comp & 0x10 != 0) 4 else 3;

  var y: usize = 0;
  while (y < h) : (y += 1) {
    var pi: usize = 0;
    while (pi < num_packets) : (pi += 1) {
      const packet = packets[pi];
      const dest_row = rgba[y * w * 4 ..];
      switch (packet.type) {
        0 => { // uncompressed
          var x: usize = 0;
          while (x < w) : (x += 1) readVal(&r, packet.channel, dest_row[x * 4 ..]);
        },
        1 => { // pure RLE
          var left = w;
          while (left > 0) {
            var count: usize = r.get8();
            if (r.atEof()) return Error.Corrupt;
            if (count > left) count = left;
            var value = [4]u8{ 0, 0, 0, 0 };
            readVal(&r, packet.channel, &value);
            var z: usize = 0;
            while (z < count) : (z += 1) copyVal(packet.channel, dest_row[(w - left + z) * 4 ..], &value);
            left -= count;
          }
        },
        2 => { // mixed RLE
          var left = w;
          while (left > 0) {
            var count: usize = r.get8();
            if (r.atEof()) return Error.Corrupt;
            if (count >= 128) {
              if (count == 128) count = r.get16be() else count -= 127;
              if (count > left) return Error.Corrupt;
              var value = [4]u8{ 0, 0, 0, 0 };
              readVal(&r, packet.channel, &value);
              var z: usize = 0;
              while (z < count) : (z += 1) copyVal(packet.channel, dest_row[(w - left + z) * 4 ..], &value);
            } else {
              count += 1;
              if (count > left) return Error.Corrupt;
              var z: usize = 0;
              while (z < count) : (z += 1) readVal(&r, packet.channel, dest_row[(w - left + z) * 4 ..]);
            }
            left -= count;
          }
        },
        else => return Error.Unsupported,
      }
    }
  }

  if (comp == 4) return .{ .w = w, .h = h, .comp = 4, .src_comp = 4, .data = rgba, .alloc = alloc };
  const out = try common.convertFormat(alloc, rgba, 4, 3, w, h);
  return .{ .w = w, .h = h, .comp = 3, .src_comp = 3, .data = out, .alloc = alloc };
}
