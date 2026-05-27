const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Group = struct {
  pub const op = .@"=";
  _B: util.MonadFn = genGroupHash(.B),
  _I: util.MonadFn = genGroupHash(.I),
  _S: util.MonadFn = genGroupHash(.S),
  _F: util.MonadFn = groupFloatsFn,
  _C: util.MonadFn = groupByteFn,
  _L: util.MonadFn = groupValuesFn,
};

fn genGroupHash(comptime k: K) util.MonadFn {
  return struct {
    fn f(vm: *VM, x: V) V {
      return groupHash(K.backing(k), vm.alloc, @field(x, @tagName(k)).slice());
    }
  }.f;
}

fn groupByteFn(vm: *VM, x: V) V { return groupByte(vm.alloc, x.C.slice()); }
fn groupFloatsFn(vm: *VM, x: V) V { return groupFloats(vm.alloc, x.F.slice()); }
fn groupValuesFn(vm: *VM, x: V) V { return groupValues(vm.alloc, x.L.slice()); }

// Build a key V from a permuted slice of raw keys (perm[i] = source index for sorted position i)
fn keyVec(comptime T: type, alloc: Alloc, keys: []const T, perm: []const usize) !V {
  const n = keys.len;
  if (T == i32) {
    const arr = try N(i32).init(alloc, n);
    for (perm, arr.slice()) |p, *k| k.* = keys[p];
    return .{ .I = arr };
  }
  if (T == u32) {
    const arr = try N(u32).init(alloc, n);
    for (perm, arr.slice()) |p, *k| k.* = keys[p];
    return .{ .S = arr };
  }
  if (T == bool) {
    const arr = try N(bool).init(alloc, n);
    for (perm, arr.slice()) |p, *k| k.* = keys[p];
    return .{ .B = arr };
  }
  unreachable;
}

// O(n log n) typed group: sorts unique keys, returns key!indices dict
fn groupHash(comptime T: type, alloc: Alloc, data: []const T) V {
  if (data.len == 0) return V.Values(alloc, &.{}) catch return V{ .err = .memory };

  var map: std.AutoArrayHashMapUnmanaged(T, void) = .{};
  defer map.deinit(alloc);
  map.ensureTotalCapacity(alloc, data.len) catch return V{ .err = .memory };

  for (data) |val| map.put(alloc, val, {}) catch return V{ .err = .memory };
  const n_groups = map.count();
  const raw_keys = map.keys();

  // Build a sort permutation over unique keys
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
  var inv_perm = alloc.alloc(usize, n_groups) catch return V{ .err = .memory };
  defer alloc.free(inv_perm);
  for (sort_perm, 0..) |orig, sorted| inv_perm[orig] = sorted;

  var counts = alloc.alloc(usize, n_groups) catch return V{ .err = .memory };
  defer alloc.free(counts);
  @memset(counts, 0);
  for (data) |val| counts[inv_perm[map.getIndex(val).?]] += 1;

  const result = N(V).init(alloc, n_groups) catch return V{ .err = .memory };
  for (result.slice()) |*s| s.* = .blank;
  for (result.slice(), counts) |*slot, cnt| {
    slot.* = .{ .I = N(i32).init(alloc, cnt) catch return V{ .err = .memory } };
  }

  @memset(counts, 0);
  for (data, 0..) |val, i| {
    const g = inv_perm[map.getIndex(val).?];
    result.slice()[g].I.slice()[counts[g]] = @intCast(i);
    counts[g] += 1;
  }

  const kv = keyVec(T, alloc, raw_keys, sort_perm) catch {
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  const d = Dict.init(alloc, kv, .{ .L = result }) catch {
    kv.deinit(alloc);
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

// O(n) byte group — 256-bucket direct lookup; keys sorted by byte value
fn groupByte(alloc: Alloc, data: []const u8) V {
  if (data.len == 0) return V.Values(alloc, &.{}) catch return V{ .err = .memory };

  var counts: [256]usize = .{0} ** 256;
  var seen:   [256]bool  = .{false} ** 256;
  var order:  [256]u8    = undefined;
  var n_groups: usize    = 0;

  for (data) |c| {
    if (!seen[c]) { seen[c] = true; order[n_groups] = c; n_groups += 1; }
    counts[c] += 1;
  }

  // Sort unique bytes so keys come out in ascending order
  std.mem.sort(u8, order[0..n_groups], {}, struct {
    fn lt(_: void, a: u8, b: u8) bool { return a < b; }
  }.lt);

  const result = N(V).init(alloc, n_groups) catch return V{ .err = .memory };
  for (result.slice()) |*s| s.* = .blank;

  var slot: [256]u32 = undefined;
  for (order[0..n_groups], 0..) |c, g| {
    result.slice()[g] = .{ .I = N(i32).init(alloc, counts[c]) catch return V{ .err = .memory } };
    slot[c] = @intCast(g);
    counts[c] = 0;
  }

  for (data, 0..) |c, i| {
    result.slice()[slot[c]].I.slice()[counts[c]] = @intCast(i);
    counts[c] += 1;
  }

  const key_n = N(u8).n1(alloc, order[0..n_groups]) catch {
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  const d = Dict.init(alloc, .{ .C = key_n }, .{ .L = result }) catch {
    key_n.deinit(alloc);
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

// Float group: compare by bit pattern so NaN with same bits → same group
fn groupFloats(alloc: Alloc, data: []const f32) V {
  if (data.len == 0) return V.Values(alloc, &.{}) catch return V{ .err = .memory };
  const bits = alloc.alloc(u32, data.len) catch return V{ .err = .memory };
  defer alloc.free(bits);
  for (data, bits) |f, *b| b.* = @bitCast(f);

  var map: std.AutoArrayHashMapUnmanaged(u32, void) = .{};
  defer map.deinit(alloc);
  map.ensureTotalCapacity(alloc, data.len) catch return V{ .err = .memory };
  for (bits) |b| map.put(alloc, b, {}) catch return V{ .err = .memory };
  const n_groups = map.count();

  var counts = alloc.alloc(usize, n_groups) catch return V{ .err = .memory };
  defer alloc.free(counts);
  @memset(counts, 0);
  for (bits) |b| counts[map.getIndex(b).?] += 1;

  const result = N(V).init(alloc, n_groups) catch return V{ .err = .memory };
  for (result.slice()) |*s| s.* = .blank;
  for (result.slice(), counts) |*slot, cnt| {
    slot.* = .{ .I = N(i32).init(alloc, cnt) catch return V{ .err = .memory } };
  }
  @memset(counts, 0);
  for (bits, 0..) |b, i| {
    const g = map.getIndex(b).?;
    result.slice()[g].I.slice()[counts[g]] = @intCast(i);
    counts[g] += 1;
  }

  const key_n = N(f32).init(alloc, n_groups) catch {
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  for (map.keys(), key_n.slice()) |b, *f| f.* = @bitCast(b);

  const d = Dict.init(alloc, .{ .F = key_n }, .{ .L = result }) catch {
    key_n.deinit(alloc);
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

// O(n²) fallback for heterogeneous lists (V has no cheap hash)
fn groupValues(alloc: Alloc, data: []const V) V {
  if (data.len == 0) return V.Values(alloc, &.{}) catch return V{ .err = .memory };

  var groups: std.ArrayList(std.ArrayList(i32)) = .empty;
  defer { for (groups.items) |*g| g.deinit(alloc); groups.deinit(alloc); }
  var keys: std.ArrayList(V) = .empty;
  defer { for (keys.items) |k| k.deinit(alloc); keys.deinit(alloc); }

  for (data, 0..) |val, i| {
    var found = false;
    for (keys.items, 0..) |key, j| {
      if (val.eq(key)) {
        groups.items[j].append(alloc, @intCast(i)) catch return V{ .err = .memory };
        found = true;
        break;
      }
    }
    if (!found) {
      keys.append(alloc, val.ref()) catch return V{ .err = .memory };
      var g: std.ArrayList(i32) = .empty;
      g.append(alloc, @intCast(i)) catch return V{ .err = .memory };
      groups.append(alloc, g) catch return V{ .err = .memory };
    }
  }

  const result = N(V).init(alloc, groups.items.len) catch return V{ .err = .memory };
  for (groups.items, 0..) |g, i| {
    const arr = N(i32).init(alloc, g.items.len) catch return V{ .err = .memory };
    @memcpy(arr.slice(), g.items);
    result.slice()[i] = .{ .I = arr };
  }

  const key_n = N(V).init(alloc, keys.items.len) catch {
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  for (keys.items, key_n.slice()) |k, *dst| dst.* = k.ref();

  const d = Dict.init(alloc, .{ .L = key_n }, .{ .L = result }) catch {
    key_n.deinit(alloc);
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

test "group integers" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.Ints(vm.alloc, &.{ 3, 1, 4, 1, 3 });
  defer v.deinit(vm.alloc);
  var res = genGroupHash(.I)(vm, v);
  defer res.deinit(vm.alloc);
  const vals = res.m.bv().L;
  try std.testing.expectEqual(@as(usize, 3), vals.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{ 1, 3, 4 }, res.m.av().I.slice()); // sorted keys
  try std.testing.expectEqualSlices(i32, &.{ 1, 3 }, vals.slice()[0].I.slice()); // key 1
  try std.testing.expectEqualSlices(i32, &.{ 0, 4 }, vals.slice()[1].I.slice()); // key 3
  try std.testing.expectEqualSlices(i32, &.{2},      vals.slice()[2].I.slice()); // key 4
}

test "group chars" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.Chars(vm.alloc, "abac");
  defer v.deinit(vm.alloc);
  var res = groupByteFn(vm, v);
  defer res.deinit(vm.alloc);
  const vals = res.m.bv().L;
  try std.testing.expectEqual(@as(usize, 3), vals.ptr.len);
  try std.testing.expectEqualSlices(u8, "abc", res.m.av().C.slice()); // sorted keys
  try std.testing.expectEqualSlices(i32, &.{ 0, 2 }, vals.slice()[0].I.slice()); // a
  try std.testing.expectEqualSlices(i32, &.{1},      vals.slice()[1].I.slice()); // b
  try std.testing.expectEqualSlices(i32, &.{3},      vals.slice()[2].I.slice()); // c
}

test "group single element" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.Ints(vm.alloc, &.{42});
  defer v.deinit(vm.alloc);
  var res = genGroupHash(.I)(vm, v);
  defer res.deinit(vm.alloc);
  const vals = res.m.bv().L;
  try std.testing.expectEqual(@as(usize, 1), vals.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{42}, res.m.av().I.slice());
  try std.testing.expectEqualSlices(i32, &.{0}, vals.slice()[0].I.slice());
}

test "group all same" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.Ints(vm.alloc, &.{ 7, 7, 7 });
  defer v.deinit(vm.alloc);
  var res = genGroupHash(.I)(vm, v);
  defer res.deinit(vm.alloc);
  const vals = res.m.bv().L;
  try std.testing.expectEqual(@as(usize, 1), vals.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{7}, res.m.av().I.slice());
  try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, vals.slice()[0].I.slice());
}

test "group all unique" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.Ints(vm.alloc, &.{ 1, 2, 3 });
  defer v.deinit(vm.alloc);
  var res = genGroupHash(.I)(vm, v);
  defer res.deinit(vm.alloc);
  const vals = res.m.bv().L;
  try std.testing.expectEqual(@as(usize, 3), vals.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, res.m.av().I.slice());
  try std.testing.expectEqualSlices(i32, &.{0}, vals.slice()[0].I.slice()); // key 1 at idx 0
  try std.testing.expectEqualSlices(i32, &.{1}, vals.slice()[1].I.slice()); // key 2 at idx 1
  try std.testing.expectEqualSlices(i32, &.{2}, vals.slice()[2].I.slice()); // key 3 at idx 2
}
