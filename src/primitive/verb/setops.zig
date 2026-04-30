//! Shared primitives for set-based verb implementations (has, distinct, group).
//!
//! Adaptive strategy ("Big L"):
//!   n ≤ threshold → linear scan: zero hashmap allocation, lives on the stack.
//!   n >  threshold → ordered hash set: O(n) build + O(1) amortised query/key.
//!
//! Thresholds are intentionally separate so each verb can be tuned independently.
//! A rough rule of thumb: hashmap allocation overhead ≈ linear scan of ~32 i64s.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// Haystack size below which linear scan beats hash-map overhead in has/in.
pub const HAS_THRESHOLD: usize = 32;

/// Input size below which stack-linear dedup beats hash-map overhead in distinct.
pub const DEDUP_THRESHOLD: usize = 32;

/// Build an insertion-order-preserving hash set from a typed slice.
/// Supports both .contains() (for has) and .keys() (for distinct).
/// Caller must defer map.deinit().
pub fn buildOrderedSet(comptime T: type, alloc: Alloc, data: []const T) !std.AutoArrayHashMapUnmanaged(T, void) {
  var map: std.AutoArrayHashMapUnmanaged(T, void) = .{};
  try map.ensureTotalCapacity(alloc, data.len);
  for (data) |v| try map.put(alloc, v, {});
  return map;
}

/// NaN-safe linear membership test for f32: compares by bit pattern.
pub inline fn containsF64(data: []const f32, val: f32) bool {
  const bits: u32 = @bitCast(val);
  for (data) |d| if (@as(u32, @bitCast(d)) == bits) return true;
  return false;
}

/// Haystack size below which linear scan beats hash-map overhead in find.
pub const FIND_THRESHOLD: usize = 32;

/// Build a HashMap mapping each unique value to its first-occurrence index.
/// Caller must defer map.deinit().
pub fn buildIndexMap(comptime T: type, alloc: Alloc, data: []const T) !std.AutoHashMap(T, i32) {
  var map = std.AutoHashMap(T, i32).init(alloc);
  try map.ensureTotalCapacity(@intCast(data.len));
  for (data, 0..) |v, i| {
    const gop = try map.getOrPut(v);
    if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
  }
  return map;
}

/// NaN-safe linear find for f32: returns first index where bits match, or null.
pub inline fn indexOfF64(data: []const f32, val: f32) ?usize {
  const bits: u32 = @bitCast(val);
  for (data, 0..) |d, i| if (@as(u32, @bitCast(d)) == bits) return i;
  return null;
}
