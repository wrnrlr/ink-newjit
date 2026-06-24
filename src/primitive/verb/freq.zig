const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

// freq x — frequency of each distinct value, as a plain count vector.
//
// This is the internal verb the compiler peephole emits for the idiom `#'=x`
// (tally-each over group). It returns EXACTLY what `#'=x` returns: the per-group
// counts, in the same order group lists its keys (I/S/B/C sorted by key; F and L
// in first-occurrence order). It does the histogram directly — no index-list
// materialization — which is the whole point of recognizing the idiom.
pub const Freq = struct {
  pub const op = .freq;
  _B: VM.Monad = genFreqHash(.B),
  _I: VM.Monad = genFreqHash(.I),
  _S: VM.Monad = genFreqHash(.S),
  _F: VM.Monad = freqFloatsFn,
  _C: VM.Monad = freqByteFn,
  _L: VM.Monad = freqValuesFn,
};

fn genFreqHash(comptime k: K) VM.Monad {
  return struct {
    fn f(vm: *VM, x: V) V {
      return freqHash(K.backing(k), vm.alloc, @field(x, @tagName(k)).slice());
    }
  }.f;
}

fn freqByteFn(vm: *VM, x: V) V { return freqByte(vm.alloc, x.C.slice()); }
fn freqFloatsFn(vm: *VM, x: V) V { return freqFloats(vm.alloc, x.F.slice()); }
fn freqValuesFn(vm: *VM, x: V) V { return freqValues(vm.alloc, x.L.slice()); }

fn intsFrom(alloc: Alloc, counts: []const usize) V {
  const arr = N(i32).init(alloc, counts.len) catch return V{ .err = .memory };
  for (counts, arr.slice()) |c, *d| d.* = @intCast(c);
  return .{ .I = arr };
}

// I/S/B: counts in ascending-key order (mirrors group.zig groupHash).
fn freqHash(comptime T: type, alloc: Alloc, data: []const T) V {
  if (data.len == 0) return intsFrom(alloc, &.{});

  var map: std.AutoArrayHashMapUnmanaged(T, void) = .{};
  defer map.deinit(alloc);
  map.ensureTotalCapacity(alloc, data.len) catch return V{ .err = .memory };
  for (data) |val| map.put(alloc, val, {}) catch return V{ .err = .memory };
  const n_groups = map.count();
  const raw_keys = map.keys();

  const sort_perm = alloc.alloc(usize, n_groups) catch return V{ .err = .memory };
  defer alloc.free(sort_perm);
  for (sort_perm, 0..) |*p, i| p.* = i;
  std.mem.sort(usize, sort_perm, raw_keys, struct {
    fn lt(ks: []const T, a: usize, b: usize) bool {
      return if (comptime T == bool)
        (@intFromBool(ks[a]) < @intFromBool(ks[b]))
      else
        (ks[a] < ks[b]);
    }
  }.lt);

  // inv_perm[unsorted_idx] = sorted_idx
  const inv_perm = alloc.alloc(usize, n_groups) catch return V{ .err = .memory };
  defer alloc.free(inv_perm);
  for (sort_perm, 0..) |orig, sorted| inv_perm[orig] = sorted;

  const counts = alloc.alloc(usize, n_groups) catch return V{ .err = .memory };
  defer alloc.free(counts);
  @memset(counts, 0);
  for (data) |val| counts[inv_perm[map.getIndex(val).?]] += 1;

  return intsFrom(alloc, counts);
}

// C: counts for present bytes in ascending order (mirrors groupByte).
fn freqByte(alloc: Alloc, data: []const u8) V {
  if (data.len == 0) return intsFrom(alloc, &.{});

  var counts: [256]usize = .{0} ** 256;
  var seen:   [256]bool  = .{false} ** 256;
  var order:  [256]u8    = undefined;
  var n_groups: usize    = 0;

  for (data) |c| {
    if (!seen[c]) { seen[c] = true; order[n_groups] = c; n_groups += 1; }
    counts[c] += 1;
  }
  std.mem.sort(u8, order[0..n_groups], {}, struct {
    fn lt(_: void, a: u8, b: u8) bool { return a < b; }
  }.lt);

  const res = N(i32).init(alloc, n_groups) catch return V{ .err = .memory };
  for (order[0..n_groups], res.slice()) |c, *d| d.* = @intCast(counts[c]);
  return .{ .I = res };
}

// F: counts in first-occurrence order (mirrors groupFloats — no sort).
fn freqFloats(alloc: Alloc, data: []const f32) V {
  if (data.len == 0) return intsFrom(alloc, &.{});
  const bits = alloc.alloc(u32, data.len) catch return V{ .err = .memory };
  defer alloc.free(bits);
  for (data, bits) |f, *b| b.* = @bitCast(f);

  var map: std.AutoArrayHashMapUnmanaged(u32, void) = .{};
  defer map.deinit(alloc);
  map.ensureTotalCapacity(alloc, data.len) catch return V{ .err = .memory };
  for (bits) |b| map.put(alloc, b, {}) catch return V{ .err = .memory };
  const n_groups = map.count();

  const counts = alloc.alloc(usize, n_groups) catch return V{ .err = .memory };
  defer alloc.free(counts);
  @memset(counts, 0);
  for (bits) |b| counts[map.getIndex(b).?] += 1;

  return intsFrom(alloc, counts);
}

// L: counts in first-occurrence order (mirrors groupValues — O(n²) eq scan).
fn freqValues(alloc: Alloc, data: []const V) V {
  if (data.len == 0) return intsFrom(alloc, &.{});

  var keys: std.ArrayList(V) = .empty;
  defer { for (keys.items) |k| k.deinit(alloc); keys.deinit(alloc); }
  var counts: std.ArrayList(usize) = .empty;
  defer counts.deinit(alloc);

  for (data) |val| {
    var found = false;
    for (keys.items, 0..) |key, j| {
      if (val.eq(key)) { counts.items[j] += 1; found = true; break; }
    }
    if (!found) {
      keys.append(alloc, val.ref()) catch return V{ .err = .memory };
      counts.append(alloc, 1) catch return V{ .err = .memory };
    }
  }
  return intsFrom(alloc, counts.items);
}
