const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const keying = @import("keying.zig");
const sort = @import("sort.zig");

// freq x — frequency of each distinct value, as a plain count vector.
//
// This is the internal verb the compiler peephole emits for the idiom `#'=x`
// (tally-each over group). It returns EXACTLY what `#'=x` returns: the per-group
// counts, in the same order group lists its keys (ascending, every type). It
// does the histogram directly — no index-list
// materialization — which is the whole point of recognizing the idiom.
pub const Freq = struct {
  pub const op = .freq;
  _B: VM.Monad = genFreqHash(.B),
  _I: VM.Monad = genFreqHash(.I),
  _S: VM.Monad = genFreqHash(.S),
  _F: VM.Monad = freqFloatsFn,
  _C: VM.Monad = freqByteFn,
  _L: VM.Monad = freqValuesFn,
  _m: VM.Monad = freqDictFn,
};

fn genFreqHash(comptime k: K) VM.Monad {
  return struct {
    fn f(vm: *VM, x: V) V {
      const T = K.backing(k);
      const data = @field(x, @tagName(k)).slice();
      // Small value range → a plain histogram: one pass, no hashing, and the
      // buckets are already in the ascending key order group reports.
      if (keying.denseRange(T, data)) |r| return freqDense(T, vm.alloc, data, r);
      return freqHash(T, vm.alloc, data);
    }
  }.f;
}

fn freqDense(comptime T: type, alloc: Alloc, data: []const T, r: keying.Dense) V {
  const counts = alloc.alloc(u32, r.span) catch return V{ .err = .memory };
  defer alloc.free(counts);
  @memset(counts, 0);
  for (data) |v| counts[keying.bucketOf(v, r.min)] += 1;

  var n_groups: usize = 0;
  for (counts) |c| { if (c != 0) n_groups += 1; }
  const res = N(i32).init(alloc, n_groups) catch return V{ .err = .memory };
  var g: usize = 0;
  for (counts) |c| {
    if (c == 0) continue;
    res.slice()[g] = @intCast(c);
    g += 1;
  }
  return .{ .I = res };
}

// `#'=d` over a dict: the group sizes are the frequencies of the dict's VALUES,
// so freq just runs on the value half. (Without this slot the `#'=` peephole
// would turn a working `#'=d` into a type error.)
fn freqDictFn(vm: *VM, x: V) V {
  const keys = x.m.av();
  const vals = x.m.bv();
  // Scalar-key dict: one entry, so one group of size 1.
  if (keys.isAtom()) {
    const res = N(i32).init(vm.alloc, 1) catch return V{ .err = .memory };
    res.slice()[0] = 1;
    return .{ .I = res };
  }
  return switch (vals) {
    .B => |n| genFreqOf(bool, vm.alloc, n.slice()),
    .I => |n| genFreqOf(i32, vm.alloc, n.slice()),
    .S => |n| genFreqOf(u32, vm.alloc, n.slice()),
    .F => |n| freqFloats(vm.alloc, n.slice()),
    .C => |n| freqByte(vm.alloc, n.slice()),
    .L => |n| freqValues(vm.alloc, n.slice()),
    else => V{ .err = .@"type" },
  };
}

fn genFreqOf(comptime T: type, alloc: Alloc, data: []const T) V {
  if (keying.denseRange(T, data)) |r| return freqDense(T, alloc, data, r);
  return freqHash(T, alloc, data);
}

fn freqByteFn(vm: *VM, x: V) V { return freqByte(vm.alloc, x.C.slice()); }
fn freqFloatsFn(vm: *VM, x: V) V { return freqFloats(vm.alloc, x.F.slice()); }
fn freqValuesFn(vm: *VM, x: V) V { return freqValues(vm.alloc, x.L.slice()); }

fn intsFrom(alloc: Alloc, counts: []const usize) V {
  const arr = N(i32).init(alloc, counts.len) catch return V{ .err = .memory };
  for (counts, arr.slice()) |c, *d| d.* = @intCast(c);
  return .{ .I = arr };
}

// I/S/B: counts in ascending-key order (mirrors group.zig groupHash) — one hash
// lookup per element, then a sort over the distinct keys alone.
fn freqHash(comptime T: type, alloc: Alloc, data: []const T) V {
  if (data.len == 0) return intsFrom(alloc, &.{});

  var map: std.AutoHashMapUnmanaged(T, u32) = .empty;
  defer map.deinit(alloc);
  map.ensureTotalCapacity(alloc, @intCast(data.len)) catch return V{ .err = .memory };
  var keys: std.ArrayListUnmanaged(T) = .empty;
  defer keys.deinit(alloc);
  var counts: std.ArrayListUnmanaged(usize) = .empty;
  defer counts.deinit(alloc);

  for (data) |val| {
    const gop = map.getOrPutAssumeCapacity(val);
    if (!gop.found_existing) {
      gop.value_ptr.* = @intCast(keys.items.len);
      keys.append(alloc, val) catch return V{ .err = .memory };
      counts.append(alloc, 0) catch return V{ .err = .memory };
    }
    counts.items[gop.value_ptr.*] += 1;
  }

  const n_groups = keys.items.len;
  const perm = alloc.alloc(usize, n_groups) catch return V{ .err = .memory };
  defer alloc.free(perm);
  for (perm, 0..) |*p, i| p.* = i;
  std.mem.sort(usize, perm, keys.items, struct {
    fn lt(ks: []const T, a: usize, b: usize) bool {
      return if (comptime T == bool)
        (@intFromBool(ks[a]) < @intFromBool(ks[b]))
      else
        (ks[a] < ks[b]);
    }
  }.lt);

  const res = N(i32).init(alloc, n_groups) catch return V{ .err = .memory };
  for (perm, res.slice()) |g, *d| d.* = @intCast(counts.items[g]);
  return .{ .I = res };
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

// F: counts in ascending-key order (mirrors groupFloats).
fn freqFloats(alloc: Alloc, data: []const f32) V {
  if (data.len == 0) return intsFrom(alloc, &.{});
  const bits = alloc.alloc(u32, data.len) catch return V{ .err = .memory };
  defer alloc.free(bits);
  for (data, bits) |f, *b| b.* = @bitCast(f);

  var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
  defer map.deinit(alloc);
  map.ensureTotalCapacity(alloc, @intCast(data.len)) catch return V{ .err = .memory };
  var counts: std.ArrayListUnmanaged(usize) = .empty;
  defer counts.deinit(alloc);
  var uniq: std.ArrayListUnmanaged(u32) = .empty;
  defer uniq.deinit(alloc);

  for (bits) |b| {
    const gop = map.getOrPutAssumeCapacity(b);
    if (!gop.found_existing) {
      gop.value_ptr.* = @intCast(counts.items.len);
      counts.append(alloc, 0) catch return V{ .err = .memory };
      uniq.append(alloc, b) catch return V{ .err = .memory };
    }
    counts.items[gop.value_ptr.*] += 1;
  }
  return countsInKeyOrder(alloc, counts.items, uniq.items, struct {
    fn lt(us: []const u32, a: usize, b: usize) bool {
      return sort.orderFloat(@as(f32, @bitCast(us[a])), @as(f32, @bitCast(us[b]))) == .lt;
    }
  }.lt);
}

// Reorder per-group counts into the key order `ctx`/`lt` define, so `freq` keeps
// agreeing with `#'=x` element for element.
fn countsInKeyOrder(alloc: Alloc, counts: []const usize, ctx: anytype, comptime lt: fn (@TypeOf(ctx), usize, usize) bool) V {
  const perm = alloc.alloc(usize, counts.len) catch return V{ .err = .memory };
  defer alloc.free(perm);
  for (perm, 0..) |*p, i| p.* = i;
  std.mem.sort(usize, perm, ctx, lt);
  const res = N(i32).init(alloc, counts.len) catch return V{ .err = .memory };
  for (perm, res.slice()) |g, *d| d.* = @intCast(counts[g]);
  return .{ .I = res };
}

// L: counts in ascending-key order (mirrors groupValues — content-hashed).
fn freqValues(alloc: Alloc, data: []const V) V {
  if (data.len == 0) return intsFrom(alloc, &.{});

  var dis = keying.Distinct.init(alloc);
  defer dis.deinit();
  var counts: std.ArrayList(usize) = .empty;
  defer counts.deinit(alloc);

  for (data) |val| {
    const g = dis.id(val) catch return V{ .err = .memory };
    if (g == counts.items.len) counts.append(alloc, 1) catch return V{ .err = .memory }
    else counts.items[g] += 1;
  }
  return countsInKeyOrder(alloc, counts.items, @as(*const keying.Distinct, &dis), struct {
    fn lt(d: *const keying.Distinct, a: usize, b: usize) bool {
      return sort.compareV(d.key(a), d.key(b)) == .lt;
    }
  }.lt);
}
