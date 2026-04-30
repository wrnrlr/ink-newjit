const std = @import("std");
const Alloc = std.mem.Allocator;
const N = @import("../../noun/value.zig").N;
const V = @import("../../noun/value.zig").V;
const K = @import("../../noun/class.zig").K;
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
    fn f(vm: *VM, x: V) !V {
      return groupHash(K.backing(k), vm.alloc, @field(x, @tagName(k)).slice());
    }
  }.f;
}

fn groupByteFn(vm: *VM, x: V) !V { return groupByte(vm.alloc, x.C.slice()); }
fn groupFloatsFn(vm: *VM, x: V) !V { return groupFloats(vm.alloc, x.F.slice()); }
fn groupValuesFn(vm: *VM, x: V) !V { return groupValues(vm.alloc, x.L.slice()); }

// O(n) typed group using AutoArrayHashMap (preserves order of first occurrence)
fn groupHash(comptime T: type, alloc: Alloc, data: []const T) !V {
  if (data.len == 0) return V.valuesFromSlice(alloc, &.{});

  var map: std.AutoArrayHashMapUnmanaged(T, void) = .{};
  defer map.deinit(alloc);
  try map.ensureTotalCapacity(alloc, data.len);

  // Pass 1: collect unique values in insertion order
  for (data) |val| try map.put(alloc, val, {});
  const n_groups = map.count();

  // Pass 2: count elements per group
  var counts = try alloc.alloc(usize, n_groups);
  defer alloc.free(counts);
  @memset(counts, 0);
  for (data) |val| counts[map.getIndex(val).?] += 1;

  // Allocate result; pre-fill .blank so errdefer deinit is always safe
  const result = try N(V).init(alloc, n_groups);
  errdefer result.deinit(alloc);
  for (result.slice()) |*s| s.* = .blank;
  for (result.slice(), counts) |*slot, cnt| {
    slot.* = .{ .I = try N(i32).init(alloc, cnt) };
  }

  // Pass 3: scatter indices (reuse counts as write cursors)
  @memset(counts, 0);
  for (data, 0..) |val, i| {
    const g = map.getIndex(val).?;
    result.slice()[g].I.slice()[counts[g]] = @intCast(i);
    counts[g] += 1;
  }

  return .{ .L = result };
}

// O(n) byte group — 256-bucket direct lookup, no hashing overhead
fn groupByte(alloc: Alloc, data: []const u8) !V {
  if (data.len == 0) return V.valuesFromSlice(alloc, &.{});

  var counts: [256]usize = .{0} ** 256;
  var seen:   [256]bool  = .{false} ** 256;
  var order:  [256]u8    = undefined;
  var n_groups: usize    = 0;

  for (data) |c| {
    if (!seen[c]) { seen[c] = true; order[n_groups] = c; n_groups += 1; }
    counts[c] += 1;
  }

  const result = try N(V).init(alloc, n_groups);
  errdefer result.deinit(alloc);
  for (result.slice()) |*s| s.* = .blank;

  var slot: [256]u32 = undefined;
  for (order[0..n_groups], 0..) |c, g| {
    result.slice()[g] = .{ .I = try N(i32).init(alloc, counts[c]) };
    slot[c] = @intCast(g);
    counts[c] = 0; // reuse as write cursor
  }

  for (data, 0..) |c, i| {
    result.slice()[slot[c]].I.slice()[counts[c]] = @intCast(i);
    counts[c] += 1;
  }

  return .{ .L = result };
}

// Float group: compare by bit pattern so NaN with same bits → same group
fn groupFloats(alloc: Alloc, data: []const f32) !V {
  if (data.len == 0) return V.valuesFromSlice(alloc, &.{});
  const bits = try alloc.alloc(u32, data.len);
  defer alloc.free(bits);
  for (data, bits) |f, *b| b.* = @bitCast(f);
  return groupHash(u32, alloc, bits);
}

// O(n²) fallback for heterogeneous lists (V has no cheap hash)
fn groupValues(alloc: Alloc, data: []const V) !V {
  if (data.len == 0) return V.valuesFromSlice(alloc, &.{});

  var groups: std.ArrayList(std.ArrayList(i32)) = .empty;
  defer { for (groups.items) |*g| g.deinit(alloc); groups.deinit(alloc); }
  var keys: std.ArrayList(V) = .empty;
  defer { for (keys.items) |k| k.deinit(alloc); keys.deinit(alloc); }

  for (data, 0..) |val, i| {
    var found = false;
    for (keys.items, 0..) |key, j| {
      if (val.eq(key)) {
        try groups.items[j].append(alloc, @intCast(i));
        found = true;
        break;
      }
    }
    if (!found) {
      try keys.append(alloc, val.ref());
      var g: std.ArrayList(i32) = .empty;
      try g.append(alloc, @intCast(i));
      try groups.append(alloc, g);
    }
  }

  const result = try N(V).init(alloc, groups.items.len);
  for (groups.items, 0..) |g, i| {
    const arr = try N(i32).init(alloc, g.items.len);
    @memcpy(arr.slice(), g.items);
    result.slice()[i] = .{ .I = arr };
  }
  return .{ .L = result };
}

test "group integers" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.intsFromSlice(vm.alloc, &.{ 3, 1, 4, 1, 3 });
  defer v.deinit(vm.alloc);
  var res = try genGroupHash(.I)(vm, v);
  defer res.deinit(vm.alloc);
  try std.testing.expectEqual(@as(usize, 3), res.L.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{ 0, 4 }, res.L.slice()[0].I.slice()); // 3
  try std.testing.expectEqualSlices(i32, &.{ 1, 3 }, res.L.slice()[1].I.slice()); // 1
  try std.testing.expectEqualSlices(i32, &.{2},      res.L.slice()[2].I.slice()); // 4
}

test "group chars" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.charsFromSlice(vm.alloc, "abac");
  defer v.deinit(vm.alloc);
  var res = try groupByteFn(vm, v);
  defer res.deinit(vm.alloc);
  try std.testing.expectEqual(@as(usize, 3), res.L.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{ 0, 2 }, res.L.slice()[0].I.slice()); // a
  try std.testing.expectEqualSlices(i32, &.{1},      res.L.slice()[1].I.slice()); // b
  try std.testing.expectEqualSlices(i32, &.{3},      res.L.slice()[2].I.slice()); // c
}

test "group single element" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.intsFromSlice(vm.alloc, &.{42});
  defer v.deinit(vm.alloc);
  var res = try genGroupHash(.I)(vm, v);
  defer res.deinit(vm.alloc);
  try std.testing.expectEqual(@as(usize, 1), res.L.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{0}, res.L.slice()[0].I.slice());
}

test "group all same" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.intsFromSlice(vm.alloc, &.{ 7, 7, 7 });
  defer v.deinit(vm.alloc);
  var res = try genGroupHash(.I)(vm, v);
  defer res.deinit(vm.alloc);
  try std.testing.expectEqual(@as(usize, 1), res.L.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, res.L.slice()[0].I.slice());
}

test "group all unique" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  var v = try V.intsFromSlice(vm.alloc, &.{ 1, 2, 3 });
  defer v.deinit(vm.alloc);
  var res = try genGroupHash(.I)(vm, v);
  defer res.deinit(vm.alloc);
  try std.testing.expectEqual(@as(usize, 3), res.L.ptr.len);
  try std.testing.expectEqualSlices(i32, &.{0}, res.L.slice()[0].I.slice());
  try std.testing.expectEqualSlices(i32, &.{1}, res.L.slice()[1].I.slice());
  try std.testing.expectEqualSlices(i32, &.{2}, res.L.slice()[2].I.slice());
}
