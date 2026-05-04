const std = @import("std");
const Alloc = std.mem.Allocator;

const SpecialSymbol = enum {
  blank, err,
  b, i, f, s, c, m, x,// scalars types
  B, I, F, S, C, M, L,
  p, // parse
  j, // json
  argc, // arguments
  env, 
  t, // current time
  
};

pub const Pool = struct {
  alloc: Alloc,
  table: std.StringHashMap(u32),
  strings: std.ArrayList([]const u8) = .empty,

  pub fn init(alloc: Alloc) Pool {
    return .{ .alloc = alloc, .table = std.StringHashMap(u32).init(alloc) };
  }

  pub fn deinit(self: *Pool) void {
    self.table.deinit();
    for (self.strings.items) |s| self.alloc.free(s);
    self.strings.deinit(self.alloc);
  }

  pub fn intern(self: *Pool, s: []const u8) !u32 {
    if (self.table.get(s)) |idx| return idx;
    const copy = try self.alloc.dupe(u8, s);
    const idx = self.strings.items.len;
    try self.strings.append(self.alloc, copy);
    try self.table.put(copy, @intCast(idx));
    return @intCast(idx);
  }

  pub fn get(self: *const Pool, idx: u32) []const u8 { return self.strings.items[idx]; }
  pub fn count(self: *const Pool) usize { return self.strings.items.len; }
};
