const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const V = value.V;
const N = value.N;

// join: C/ — join strings with separator
// "ra"/("ab";"cadab";"") → "abracadabra"
pub fn join(vm: *VM, sep: V, parts: V) V {
  if (parts != .L) return .{ .err = .rank };
  const sep_chars = if (sep == .C) sep.C.slice() else &[_]u8{sep.c};
  const n = parts.len();
  if (n == 0) return V.Chars(vm.alloc, "") catch return V{ .err = .memory };

  // Calculate total length
  var total: usize = 0;
  for (0..n) |i| {
    const p = parts.at(i);
    defer p.deinit(vm.alloc);
    total += p.len();
  }
  total += sep_chars.len * (if (n > 0) n - 1 else 0);

  var buf = vm.alloc.alloc(u8, total) catch return V{ .err = .memory };
  defer vm.alloc.free(buf);
  var pos: usize = 0;
  for (0..n) |i| {
    if (i > 0) {
      @memcpy(buf[pos..pos + sep_chars.len], sep_chars);
      pos += sep_chars.len;
    }
    const p = parts.at(i);
    defer p.deinit(vm.alloc);
    const pchars = if (p == .C) p.C.slice() else &[_]u8{p.c};
    @memcpy(buf[pos..pos + pchars.len], pchars);
    pos += pchars.len;
  }
  return V.Chars(vm.alloc, buf) catch return V{ .err = .memory };
}
