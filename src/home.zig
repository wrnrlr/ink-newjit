// Ink home directory and host-platform helpers, shared by the host binary and
// the command line tools.  The home dir ($INK_HOME, default ~/.ink) holds the
// distributed binaries (bin/), the k library (lib/), and per-platform native
// extensions (share/<platform>/).
const std = @import("std");
const builtin = @import("builtin");

pub const os_name = switch (builtin.os.tag) {
  .macos   => "macos",
  .linux   => "linux",
  .windows => "windows",
  else     => "unknown",
};

pub const arch_name = switch (builtin.cpu.arch) {
  .aarch64 => "arm64",
  .x86_64  => "x64",
  else     => "unknown",
};

/// Host platform tag used in binary names and share/ subdirs (e.g. macos-arm64).
pub const platform = os_name ++ "-" ++ arch_name;

/// Native shared-library extension for the host platform.
pub const lib_ext = switch (builtin.os.tag) {
  .macos   => "dylib",
  .windows => "dll",
  else     => "so",
};

/// Resolve the ink home directory into `buf`: $INK_HOME if set, else $HOME/.ink.
/// Returns the slice (no trailing slash), or null when neither var is set.
pub fn dir(buf: []u8) ?[]const u8 {
  if (std.c.getenv("INK_HOME")) |h| {
    const s = std.mem.sliceTo(h, 0);
    if (s.len == 0 or s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
  }
  const home = std.c.getenv("HOME") orelse return null;
  const hs = std.mem.sliceTo(home, 0);
  const suffix = "/.ink";
  if (hs.len + suffix.len > buf.len) return null;
  @memcpy(buf[0..hs.len], hs);
  @memcpy(buf[hs.len..][0..suffix.len], suffix);
  return buf[0 .. hs.len + suffix.len];
}
