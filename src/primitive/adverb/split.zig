const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const V = value.V;
const N = value.N;

// split: C\ — split string by separator
// "ra"\"abracadabra" → ("ab";"cadab";"")
pub fn split(vm: *VM, sep: V, str: V) !V {
  const sep_chars = if (sep == .C) sep.C.slice() else &[_]u8{sep.c};
  const str_chars = if (str == .C) str.C.slice() else &[_]u8{str.c};
  if (sep_chars.len == 0) return .{ .err = .domain };

  var parts: std.ArrayList(V) = .empty;
  defer parts.deinit(vm.alloc);

  var start: usize = 0;
  var i: usize = 0;
  while (i + sep_chars.len <= str_chars.len) {
    if (std.mem.eql(u8, str_chars[i..i + sep_chars.len], sep_chars)) {
      try parts.append(vm.alloc, try V.charsFromSlice(vm.alloc, str_chars[start..i]));
      i += sep_chars.len;
      start = i;
    } else {
      i += 1;
    }
  }
  try parts.append(vm.alloc, try V.charsFromSlice(vm.alloc, str_chars[start..]));
  return V.valuesFromSlice(vm.alloc, parts.items);
}
