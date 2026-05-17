const std = @import("std");

pub const Rc = extern struct {
  rc:    u32,
  len:   u32,
  flags: u8    = 0,
  _pad:  [7]u8 = .{0, 0, 0, 0, 0, 0, 0},
  pub fn data(r: *Rc, comptime T: type) [*]T {
    return @as([*]T, @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(r) + @sizeOf(Rc), @alignOf(T))));
  }
};
