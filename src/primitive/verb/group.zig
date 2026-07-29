const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const pick = @import("pick.zig");
const keying = @import("keying.zig");
const promote = @import("../promote.zig").promote;

pub const Group = struct {
  pub const op = .@"=";
  _B: VM.Monad = genGroupHash(.B),
  _I: VM.Monad = genGroupHash(.I),
  _S: VM.Monad = genGroupHash(.S),
  _F: VM.Monad = groupFloatsFn,
  _C: VM.Monad = groupByteFn,
  _L: VM.Monad = groupValuesFn,
  _m: VM.Monad = groupDictFn,
};

fn genGroupHash(comptime k: K) VM.Monad {
  return struct {
    fn f(vm: *VM, x: V) V {
      const T = K.backing(k);
      const data = @field(x, @tagName(k)).slice();
      // Small value range → address buckets directly: no hashing, and ascending
      // buckets already give the ascending key order group promises.
      if (keying.denseRange(T, data)) |r| return groupDense(T, vm.alloc, data, r);
      return groupHash(T, vm.alloc, data);
    }
  }.f;
}

// Direct-bucket group: count, lay out one index array per non-empty bucket, fill.
// Two passes over the data, none of them hashing.
fn groupDense(comptime T: type, alloc: Alloc, data: []const T, r: keying.Dense) V {
  const counts = alloc.alloc(u32, r.span) catch return V{ .err = .memory };
  defer alloc.free(counts);
  @memset(counts, 0);
  for (data) |v| counts[keying.bucketOf(v, r.min)] += 1;

  var n_groups: usize = 0;
  for (counts) |c| { if (c != 0) n_groups += 1; }

  const gid = alloc.alloc(u32, r.span) catch return V{ .err = .memory };
  defer alloc.free(gid);
  const result = N(V).init(alloc, n_groups) catch return V{ .err = .memory };
  @memset(result.slice(), .blank);
  const key_n = N(T).init(alloc, n_groups) catch {
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  var g: u32 = 0;
  for (counts, 0..) |c, b| {
    if (c == 0) continue;
    gid[b] = g;
    key_n.slice()[g] = keying.fromBucket(T, b, r.min);
    result.slice()[g] = .{ .I = N(i32).init(alloc, c) catch {
      (V{ .L = result }).deinit(alloc);
      key_n.deinit(alloc);
      return V{ .err = .memory };
    } };
    g += 1;
  }

  @memset(counts, 0); // reused as the per-bucket write cursor
  for (data, 0..) |v, i| {
    const b = keying.bucketOf(v, r.min);
    result.slice()[gid[b]].I.slice()[counts[b]] = @intCast(i);
    counts[b] += 1;
  }

  const keys = keyOf(T, key_n);
  const d = Dict.init(alloc, keys, .{ .L = result }) catch {
    keys.deinit(alloc);
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

// Backing type → key vector class, matching keyVec's mapping.
fn keyOf(comptime T: type, n: @import("../../noun/array.zig").N(T)) V {
  return switch (T) {
    i32 => .{ .I = n },
    u32 => .{ .S = n },
    bool => .{ .B = n },
    else => @compileError("keyOf: unsupported key type"),
  };
}

fn groupByteFn(vm: *VM, x: V) V { return groupByte(vm.alloc, x.C.slice()); }
fn groupFloatsFn(vm: *VM, x: V) V { return groupFloats(vm.alloc, x.F.slice()); }
fn groupValuesFn(vm: *VM, x: V) V { return groupValues(vm.alloc, x.L.slice()); }

// =d — group a dict by its VALUES: every distinct value maps to the LIST of keys
// carrying it. The same verb as `=X`, with a dict's keys standing in where a
// vector's indices would be (`=X` reports indices precisely because a vector's
// keys ARE its indices). Runs the positional group over the value half, then
// maps each index list back through the keys.
fn groupDictFn(vm: *VM, x: V) V {
  const keys = x.m.av();
  const vals = x.m.bv();
  // A scalar-key dict is a single entry stored unwrapped: its lone value groups
  // to a one-element list holding its lone key.
  if (keys.isAtom()) return groupSingleton(vm, keys, vals);
  const g = groupPositions(vm, vals);
  // An empty group is an empty list, not a dict (same as `=()`) — hand it back.
  if (g.tag() != .m) return g;
  defer g.deinit(vm.alloc);
  const idx = g.m.bv();
  const out = N(V).init(vm.alloc, idx.len()) catch return V{ .err = .memory };
  @memset(out.slice(), .blank);
  for (out.slice(), 0..) |*slot, i| {
    const iv = idx.at(i);
    defer iv.deinit(vm.alloc);
    const picked = pick.pickVecFn(vm, keys, iv);
    if (picked.tag() == .err) {
      (V{ .L = out }).deinit(vm.alloc);
      return picked;
    }
    slot.* = picked;
  }
  const d = Dict.init(vm.alloc, g.m.av().ref(), .{ .L = out }) catch {
    (V{ .L = out }).deinit(vm.alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

// The positional group of a dict's value half — the same kernels `=X` uses.
fn groupPositions(vm: *VM, v: V) V {
  return switch (v) {
    .B => |n| groupHash(bool, vm.alloc, n.slice()),
    .I => |n| groupHash(i32,  vm.alloc, n.slice()),
    .S => |n| groupHash(u32,  vm.alloc, n.slice()),
    .F => |n| groupFloats(vm.alloc, n.slice()),
    .C => |n| groupByte(vm.alloc, n.slice()),
    .L => |n| groupValues(vm.alloc, n.slice()),
    else => V{ .err = .@"type" },
  };
}

fn groupSingleton(vm: *VM, key: V, val: V) V {
  const kl = N(V).init(vm.alloc, 1) catch return V{ .err = .memory };
  kl.slice()[0] = key.ref();
  const vl = N(V).init(vm.alloc, 1) catch {
    (V{ .L = kl }).deinit(vm.alloc);
    return V{ .err = .memory };
  };
  vl.slice()[0] = val.ref();
  const group = N(V).init(vm.alloc, 1) catch {
    (V{ .L = kl }).deinit(vm.alloc);
    (V{ .L = vl }).deinit(vm.alloc);
    return V{ .err = .memory };
  };
  group.slice()[0] = promote(vm.alloc, kl);
  const d = Dict.init(vm.alloc, promote(vm.alloc, vl), .{ .L = group }) catch {
    (V{ .L = group }).deinit(vm.alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

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

// Wide-range typed group: ONE hash lookup per element (the id is remembered in
// `ids`), then a sort over the distinct keys only. The earlier version hashed
// every element three times — once to build the key set and twice more to look
// its group up again — which dominated everything else at high cardinality.
fn groupHash(comptime T: type, alloc: Alloc, data: []const T) V {
  if (data.len == 0) return V.Values(alloc, &.{}) catch return V{ .err = .memory };

  var map: std.AutoHashMapUnmanaged(T, u32) = .empty;
  defer map.deinit(alloc);
  map.ensureTotalCapacity(alloc, @intCast(data.len)) catch return V{ .err = .memory };

  const ids = alloc.alloc(u32, data.len) catch return V{ .err = .memory };
  defer alloc.free(ids);
  var keys: std.ArrayListUnmanaged(T) = .empty;
  defer keys.deinit(alloc);
  var counts: std.ArrayListUnmanaged(u32) = .empty;
  defer counts.deinit(alloc);

  for (data, ids) |val, *slot| {
    const gop = map.getOrPutAssumeCapacity(val);
    if (!gop.found_existing) {
      gop.value_ptr.* = @intCast(keys.items.len);
      keys.append(alloc, val) catch return V{ .err = .memory };
      counts.append(alloc, 0) catch return V{ .err = .memory };
    }
    const g = gop.value_ptr.*;
    slot.* = g;
    counts.items[g] += 1;
  }

  const n_groups = keys.items.len;
  // perm[sorted position] = group id, rank[group id] = sorted position
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
  const rank = alloc.alloc(u32, n_groups) catch return V{ .err = .memory };
  defer alloc.free(rank);
  for (perm, 0..) |g, s| rank[g] = @intCast(s);

  const result = N(V).init(alloc, n_groups) catch return V{ .err = .memory };
  @memset(result.slice(), .blank);
  const cursor = alloc.alloc(u32, n_groups) catch {
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  defer alloc.free(cursor);
  @memset(cursor, 0);
  for (perm, 0..) |g, s| {
    result.slice()[s] = .{ .I = N(i32).init(alloc, counts.items[g]) catch {
      (V{ .L = result }).deinit(alloc);
      return V{ .err = .memory };
    } };
  }
  for (ids, 0..) |g, i| {
    const s = rank[g];
    result.slice()[s].I.slice()[cursor[s]] = @intCast(i);
    cursor[s] += 1;
  }

  const kv = keyVec(T, alloc, keys.items, perm) catch {
    (V{ .L = result }).deinit(alloc);
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

  // One lookup per element; groups stay in first-occurrence order (no sort).
  var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
  defer map.deinit(alloc);
  map.ensureTotalCapacity(alloc, @intCast(data.len)) catch return V{ .err = .memory };
  const ids = alloc.alloc(u32, data.len) catch return V{ .err = .memory };
  defer alloc.free(ids);
  var uniq: std.ArrayListUnmanaged(u32) = .empty;
  defer uniq.deinit(alloc);
  var counts_l: std.ArrayListUnmanaged(u32) = .empty;
  defer counts_l.deinit(alloc);

  for (bits, ids) |b, *slot| {
    const gop = map.getOrPutAssumeCapacity(b);
    if (!gop.found_existing) {
      gop.value_ptr.* = @intCast(uniq.items.len);
      uniq.append(alloc, b) catch return V{ .err = .memory };
      counts_l.append(alloc, 0) catch return V{ .err = .memory };
    }
    slot.* = gop.value_ptr.*;
    counts_l.items[gop.value_ptr.*] += 1;
  }
  const n_groups = uniq.items.len;

  const result = N(V).init(alloc, n_groups) catch return V{ .err = .memory };
  @memset(result.slice(), .blank);
  for (result.slice(), counts_l.items) |*slot, cnt| {
    slot.* = .{ .I = N(i32).init(alloc, cnt) catch {
      (V{ .L = result }).deinit(alloc);
      return V{ .err = .memory };
    } };
  }
  const cursor = alloc.alloc(u32, n_groups) catch {
    (V{ .L = result }).deinit(alloc);
    return V{ .err = .memory };
  };
  defer alloc.free(cursor);
  @memset(cursor, 0);
  for (ids, 0..) |g, i| {
    result.slice()[g].I.slice()[cursor[g]] = @intCast(i);
    cursor[g] += 1;
  }

  const key_n = N(f32).init(alloc, n_groups) catch {
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  for (uniq.items, key_n.slice()) |b, *f| f.* = @bitCast(b);

  const d = Dict.init(alloc, .{ .F = key_n }, .{ .L = result }) catch {
    key_n.deinit(alloc);
    result.deinit(alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

// General lists: content-hash each element to its group (keying.Distinct), then
// the same count/lay-out/fill shape as the dense path. Keys stay in
// first-occurrence order. Was an eq-scan over every distinct key seen so far,
// i.e. O(n · distinct).
fn groupValues(alloc: Alloc, data: []const V) V {
  if (data.len == 0) return V.Values(alloc, &.{}) catch return V{ .err = .memory };

  var dis = keying.Distinct.init(alloc);
  defer dis.deinit();
  const ids = alloc.alloc(u32, data.len) catch return V{ .err = .memory };
  defer alloc.free(ids);
  for (data, ids) |val, *slot| slot.* = dis.id(val) catch return V{ .err = .memory };

  const n_groups = dis.count();
  const counts = alloc.alloc(u32, n_groups) catch return V{ .err = .memory };
  defer alloc.free(counts);
  @memset(counts, 0);
  for (ids) |g| counts[g] += 1;

  const result = N(V).init(alloc, n_groups) catch return V{ .err = .memory };
  @memset(result.slice(), .blank);
  for (result.slice(), counts) |*slot, c| {
    slot.* = .{ .I = N(i32).init(alloc, c) catch {
      (V{ .L = result }).deinit(alloc);
      return V{ .err = .memory };
    } };
  }
  @memset(counts, 0); // reused as the per-group write cursor
  for (ids, 0..) |g, i| {
    result.slice()[g].I.slice()[counts[g]] = @intCast(i);
    counts[g] += 1;
  }

  const key_n = N(V).init(alloc, n_groups) catch {
    (V{ .L = result }).deinit(alloc);
    return V{ .err = .memory };
  };
  for (key_n.slice(), 0..) |*dst, g| dst.* = dis.key(g).ref();

  const d = Dict.init(alloc, .{ .L = key_n }, .{ .L = result }) catch {
    (V{ .L = key_n }).deinit(alloc);
    (V{ .L = result }).deinit(alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}
