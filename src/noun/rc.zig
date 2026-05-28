const std = @import("std");

// 16-byte header. `cap` is the number of element slots actually backed by the
// underlying allocation (i.e. `(bytes_allocated - data_offset) / @sizeOf(T)`).
// Callers may write into positions [len, cap) without re-allocating, as long
// as `rc == 1` and the immutable flag is clear. `deinit` reads `cap` to
// compute the freed byte count, so `cap` must always match what was alloc'd.
pub const Rc = extern struct {
  rc:    u32,
  len:   u32,
  cap:   u32,
  flags: u8    = 0,
  _pad:  [3]u8 = .{0, 0, 0},
  pub fn data(r: *Rc, comptime T: type) [*]T {
    return @as([*]T, @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(r) + @sizeOf(Rc), @alignOf(T))));
  }
};
