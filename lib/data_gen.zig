/// data_gen — write lib/data.kb from the unicode tables in lib/font/data.zig.
///
/// The output is a k binary dict (version 0x03, tag m=10):
///   keys:   S vector of table names
///   values: L list, one entry per table — either I (i32) or C (u8) vector
///
/// Type tags (from src/noun/class.zig K.fromCode):
///   m=10  dict
///   I=14  i32 vector: tag + u32 count + count*i32 LE
///   C=17  u8  vector: tag + u32 count + count bytes
///   L=9   list:       tag + u32 count + count*value
///   S=16  symbol vec: tag + u32 count + count*(u32 len + utf8 bytes)
///
/// Usage: zig build data   (writes lib/data.kb relative to project root)

const std = @import("std");
const data = @import("font/data.zig");

const alloc = std.heap.c_allocator;

const VERSION: u8 = 0x03;
const TAG_L: u8   = 9;
const TAG_M: u8   = 10;
const TAG_I: u8   = 14;
const TAG_C: u8   = 17;
const TAG_S: u8   = 16;

fn appendU32(buf: *std.ArrayList(u8), v: u32) !void {
  var b: [4]u8 = undefined;
  std.mem.writeInt(u32, &b, v, .little);
  try buf.appendSlice(alloc, &b);
}

fn appendI32(buf: *std.ArrayList(u8), v: i32) !void {
  var b: [4]u8 = undefined;
  std.mem.writeInt(i32, &b, v, .little);
  try buf.appendSlice(alloc, &b);
}

fn appendSymVec(buf: *std.ArrayList(u8), names: []const []const u8) !void {
  try buf.append(alloc, TAG_S);
  try appendU32(buf, @intCast(names.len));
  for (names) |name| {
    try appendU32(buf, @intCast(name.len));
    try buf.appendSlice(alloc, name);
  }
}

fn appendIVecI32(buf: *std.ArrayList(u8), items: []const i32) !void {
  try buf.append(alloc, TAG_I);
  try appendU32(buf, @intCast(items.len));
  for (items) |v| try appendI32(buf, v);
}

fn appendIVecU16AsI32(buf: *std.ArrayList(u8), items: []const u16) !void {
  try buf.append(alloc, TAG_I);
  try appendU32(buf, @intCast(items.len));
  for (items) |v| try appendI32(buf, @intCast(v));
}

fn appendIVecU32AsI32(buf: *std.ArrayList(u8), items: []const u32) !void {
  try buf.append(alloc, TAG_I);
  try appendU32(buf, @intCast(items.len));
  for (items) |v| try appendI32(buf, @bitCast(v));
}

fn appendCVec(buf: *std.ArrayList(u8), items: []const u8) !void {
  try buf.append(alloc, TAG_C);
  try appendU32(buf, @intCast(items.len));
  try buf.appendSlice(alloc, items);
}

pub fn main() !void {
  // Table names (order must match values appended below)
  const names = [_][]const u8{
    "UnicodeParentDeltas",
    "UnicodeWordBreakClass_PageIndices",
    "UnicodeWordBreakClass_Data",
    "UnicodeLineBreakClass_PageIndices",
    "UnicodeLineBreakClass_Data",
    "UnicodeGraphemeBreakClass_PageIndices",
    "UnicodeGraphemeBreakClass_Data",
    "UnicodeFlags_PageIndices",
    "UnicodeFlags_Data",
    "UnicodeBidirectionalClass_PageIndices",
    "UnicodeBidirectionalClass_Data",
    "UnicodeScriptExtension_PageIndices",
    "UnicodeScriptExtension_Data",
    "UnicodeMirrorCodepoint_PageIndices",
    "UnicodeMirrorCodepoint_Data",
  };
  const n_tables = names.len;

  var buf: std.ArrayList(u8) = .empty;
  defer buf.deinit(alloc);

  // Version byte
  try buf.append(alloc, VERSION);

  // Dict header (m = 10)
  try buf.append(alloc, TAG_M);

  // Keys: S vector of table names
  try appendSymVec(&buf, &names);

  // Values: L list of n_tables entries
  try buf.append(alloc, TAG_L);
  try appendU32(&buf, n_tables);

  // UnicodeParentDeltas — i32 → I
  try appendIVecI32(&buf, &data.UnicodeParentDeltas);

  // UnicodeWordBreakClass_PageIndices — u8 → C
  try appendCVec(&buf, &data.UnicodeWordBreakClass_PageIndices);

  // UnicodeWordBreakClass_Data — u8 → C
  try appendCVec(&buf, &data.UnicodeWordBreakClass_Data);

  // UnicodeLineBreakClass_PageIndices — u8 → C
  try appendCVec(&buf, &data.UnicodeLineBreakClass_PageIndices);

  // UnicodeLineBreakClass_Data — u8 → C
  try appendCVec(&buf, &data.UnicodeLineBreakClass_Data);

  // UnicodeGraphemeBreakClass_PageIndices — u8 → C
  try appendCVec(&buf, &data.UnicodeGraphemeBreakClass_PageIndices);

  // UnicodeGraphemeBreakClass_Data — u8 → C
  try appendCVec(&buf, &data.UnicodeGraphemeBreakClass_Data);

  // UnicodeFlags_PageIndices — u8 → C
  try appendCVec(&buf, &data.UnicodeFlags_PageIndices);

  // UnicodeFlags_Data — u8 → C
  try appendCVec(&buf, &data.UnicodeFlags_Data);

  // UnicodeBidirectionalClass_PageIndices — u8 → C
  try appendCVec(&buf, &data.UnicodeBidirectionalClass_PageIndices);

  // UnicodeBidirectionalClass_Data — u8 → C
  try appendCVec(&buf, &data.UnicodeBidirectionalClass_Data);

  // UnicodeScriptExtension_PageIndices — u8 → C
  try appendCVec(&buf, &data.UnicodeScriptExtension_PageIndices);

  // UnicodeScriptExtension_Data — u16 → I
  try appendIVecU16AsI32(&buf, &data.UnicodeScriptExtension_Data);

  // UnicodeMirrorCodepoint_PageIndices — u8 → C
  try appendCVec(&buf, &data.UnicodeMirrorCodepoint_PageIndices);

  // UnicodeMirrorCodepoint_Data — u32 (codepoints ≤ 0x10FFFF, fit in i32) → I
  try appendIVecU32AsI32(&buf, &data.UnicodeMirrorCodepoint_Data);

  const io = std.Io.Threaded.global_single_threaded.io();
  const out_path = "lib/data.kb";
  const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
  defer file.close(io);
  try file.writePositionalAll(io, buf.items, 0);

  try std.Io.File.stdout().writeStreamingAll(io, "wrote lib/data.kb\n");
}
