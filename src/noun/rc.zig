const std = @import("std");

// 16-byte header (four u32 fields). `cap` is the number of element slots actually backed by the
// underlying allocation (i.e. `(bytes_allocated - data_offset) / @sizeOf(T)`).
// Callers may write into positions [len, cap) without re-allocating, as long
// as `rc == 1` and the immutable flag is clear. `deinit` reads `cap` to
// compute the freed byte count, so `cap` must always match what was alloc'd.
pub const Rc = extern struct {
  rc:    u32,
  len:   u32,
  cap:   u32,
  // Packed: low 8 bits = flags (ArrayFlags), high 24 bits = "dirty epoch" — a
  // version stamp that is fresh at every allocation and bumped on in-place
  // mutation (see V.cow). Two snapshots of the `epoch` verb compare unequal iff
  // the array/dict was reallocated or written in between — the basis for change
  // detection (rebuild a render buffer only when its data dirties). Packed into
  // one word so the header stays 16 bytes: a larger header would break the
  // `data_offset` divisibility the slab allocator's free-size depends on.
  meta:  u32 = 0,
  pub fn data(r: *Rc, comptime T: type) [*]T {
    return @as([*]T, @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(r) + @sizeOf(Rc), @alignOf(T))));
  }

  pub inline fn getEpoch(r: *const Rc) u32 { return r.meta >> 8; }
  // Stamp a fresh epoch while preserving the flag bits.
  pub inline fn stampEpoch(r: *Rc) void { r.meta = (r.meta & 0xff) | (next24() << 8); }
  // Initial `meta` for a freshly-allocated header: flags clear, fresh epoch.
  pub fn freshMeta() u32 { return next24() << 8; }
};

// Monotonic source of 24-bit epoch stamps. Single-threaded VM, so a plain
// wrapping counter suffices; a collision needs 2^24 stamps between two snapshots
// (never within a frame), and only weakens change detection, never correctness.
var epoch_counter: u32 = 0;
fn next24() u32 {
  epoch_counter = (epoch_counter +% 1) & 0xff_ffff;
  if (epoch_counter == 0) epoch_counter = 1;
  return epoch_counter;
}
