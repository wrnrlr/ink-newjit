const std = @import("std");
const builtin = @import("builtin");
const Alloc = std.mem.Allocator;
const V = @import("noun/value.zig").V;
const VM = @import("runtime/vm.zig").VM;

// Path to the running executable.  May be relative; callers open it via cwd().
pub fn selfExePath(buf: *[4096]u8) ![]const u8 {
  if (builtin.os.tag == .macos) {
    var size: u32 = buf.len;
    if (std.c._NSGetExecutablePath(buf, &size) != 0) return error.PathTooLong;
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
  } else if (builtin.os.tag == .linux) {
    const n = std.c.readlink("/proc/self/exe", buf, buf.len);
    if (n <= 0) return error.NoExePath;
    return buf[0..@intCast(n)];
  }
  return error.Unsupported;
}

pub fn clamp(x: anytype, min_val: @TypeOf(x), max_val: @TypeOf(x)) @TypeOf(x) {
  std.debug.assert(min_val <= max_val);
  return @min(@max(x, min_val), max_val);
}

pub const ApplyFn = *const fn (*VM, V, []const V) V;

pub const MockWriter = struct {
  buffer: std.ArrayList(u8),
  alloc: Alloc,
  pub const Writer = struct {
    mock: *MockWriter,
    interface: std.Io.Writer,
    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
      _ = splat;
      const self: *Writer = @fieldParentPtr("interface", io_w);
      var total_written: usize = 0;
      for (data) |slice| {
        self.mock.buffer.appendSlice(self.mock.alloc, slice) catch return error.WriteFailed;
        total_written += slice.len;
      }
      return total_written;
    }
  };
  const writer_vtable = std.Io.Writer.VTable{ .drain = Writer.drain };
  pub fn init(allocator: Alloc) !MockWriter {
    return .{ .buffer = try std.ArrayList(u8).initCapacity(allocator, 0), .alloc = allocator };
  }
  pub fn deinit(self: *MockWriter) void { self.buffer.deinit(self.alloc); }
  pub fn writer(self: *MockWriter) Writer {
    return .{ .mock = self, .interface = std.Io.Writer{ .buffer = &.{}, .vtable = &writer_vtable } };
  }
  pub fn getText(self: *MockWriter) []const u8 { return self.buffer.items; }
};
