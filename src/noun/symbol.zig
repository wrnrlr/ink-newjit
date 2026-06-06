const std = @import("std");
const Alloc = std.mem.Allocator;

// Symbols prefilled into the pool at fixed indices. Index 0 MUST be the empty
// symbol (""): the `s == 0` test in class.zig encodes the null/blank symbol,
// so a real symbol must never land at index 0. (Type-name letters like `i `f
// are intentionally NOT prefilled — they collide with common user symbols and
// would perturb index-ordered ops such as group/distinct.)
pub const builtin_symbols = [_][]const u8{
  "", // 0: empty/blank symbol (null sentinel)
};

pub const Pool = struct {
  alloc: Alloc,
  table: std.StringHashMap(u32),
  strings: std.ArrayList([]const u8) = .empty,

  pub fn init(alloc: Alloc) Pool {
    return .{ .alloc = alloc, .table = std.StringHashMap(u32).init(alloc) };
  }

  // Intern the builtin symbols at their fixed indices (call once, right after
  // init, before any other interning).
  pub fn prefill(self: *Pool) !void {
    std.debug.assert(self.strings.items.len == 0);
    for (builtin_symbols) |s| _ = try self.intern(s);
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
