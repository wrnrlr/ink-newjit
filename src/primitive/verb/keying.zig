const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("../../noun/value.zig").V;

// Shared key-bucketing machinery for the group/freq family.
//
// Two strategies, both O(n):
//   * denseRange + bucket index — for int-like keys whose value range is small
//     enough to address directly. No hashing at all, and the buckets come out in
//     ascending key order for free, which is the order group promises.
//   * Distinct — a content-hashed distinct-value indexer for general lists,
//     replacing the linear eq-scan that made `=L` quadratic.

pub const Dense = struct { min: i64, span: usize };

// Direct bucketing needs one slot per possible value, so it only pays when the
// range is both absolutely small (bounded memory) and dense relative to the data
// (a 1M-wide range over 10 elements is all empty buckets). Outside that, the hash
// path wins.
const MAX_SPAN: u64 = 1 << 20;
const MIN_SPAN: u64 = 4096; // below this the array is trivially cheap either way

pub inline fn asI64(v: anytype) i64 {
  return switch (@TypeOf(v)) {
    bool => @intFromBool(v),
    else => @intCast(v),
  };
}

/// The value range of an int-like slice, or null when direct bucketing would
/// cost more than it saves. Costs one pass; the hash path it guards is far more
/// expensive than that per element.
pub fn denseRange(comptime T: type, data: []const T) ?Dense {
  if (data.len == 0) return null;
  var lo: i64 = asI64(data[0]);
  var hi: i64 = lo;
  var i: usize = 0;
  // Explicit lanes: the scalar loop stays scalar in ReleaseFast, and this pass
  // runs even when the range turns out to be too wide to bucket, so it is pure
  // overhead on the fallback path.
  if (comptime T == i32 or T == u32) {
    const LANES = 8;
    if (data.len >= LANES) {
      var vlo: @Vector(LANES, T) = data[0..LANES].*;
      var vhi = vlo;
      i = LANES;
      while (i + LANES <= data.len) : (i += LANES) {
        const v: @Vector(LANES, T) = data[i..][0..LANES].*;
        vlo = @min(vlo, v);
        vhi = @max(vhi, v);
      }
      lo = asI64(@reduce(.Min, vlo));
      hi = asI64(@reduce(.Max, vhi));
    }
  }
  while (i < data.len) : (i += 1) {
    const x = asI64(data[i]);
    if (x < lo) lo = x;
    if (x > hi) hi = x;
  }
  const span: u64 = @intCast(hi - lo + 1);
  if (span > MAX_SPAN) return null;
  if (span > MIN_SPAN and span > 4 * data.len) return null;
  return .{ .min = lo, .span = @intCast(span) };
}

pub inline fn bucketOf(v: anytype, min: i64) usize {
  return @intCast(asI64(v) - min);
}

pub inline fn fromBucket(comptime T: type, b: usize, min: i64) T {
  const raw = min + @as(i64, @intCast(b));
  return switch (T) {
    bool => raw != 0,
    else => @intCast(raw),
  };
}

// ── content hashing ───────────────────────────────────────────────────────────

/// Hash a value so that `V.eq`-equal values hash equal. Collisions stay correct:
/// every candidate is still confirmed with `.eq`.
pub fn hashV(v: V) u64 {
  var h = std.hash.Wyhash.init(0);
  hashInto(&h, v);
  return h.final();
}

fn hashInto(h: *std.hash.Wyhash, v: V) void {
  const tag: u8 = @intFromEnum(v.tag());
  h.update(&[_]u8{tag});
  switch (v) {
    .b => |x| h.update(&[_]u8{@intFromBool(x)}),
    inline .i, .n, .s, .c => |x| h.update(std.mem.asBytes(&x)),
    // ±0.0 compare equal but differ in bits — normalize before hashing.
    inline .f, .d, .h => |x| {
      const norm = if (x == 0) @as(@TypeOf(x), 0) else x;
      h.update(std.mem.asBytes(&norm));
    },
    inline .B, .I, .N, .S, .C => |n| h.update(std.mem.sliceAsBytes(n.slice())),
    inline .F, .D, .H => |n| for (n.slice()) |x| {
      const norm = if (x == 0) @as(@TypeOf(x), 0) else x;
      h.update(std.mem.asBytes(&norm));
    },
    .L => |n| for (n.slice()) |e| hashInto(h, e),
    inline .m, .M => |d| { hashInto(h, d.av()); hashInto(h, d.bv()); },
    // Everything else (lambdas, projections, errors) hashes by tag alone and is
    // separated by the .eq check.
    else => {},
  }
}

/// Distinct-value indexer: hands out group ids in first-occurrence order, O(1)
/// expected per lookup. Hash buckets chain through `next`, so exactness comes
/// from `.eq`, not from the hash.
pub const Distinct = struct {
  alloc: Alloc,
  heads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
  next: std.ArrayListUnmanaged(u32) = .empty,
  keys: std.ArrayListUnmanaged(V) = .empty, // borrowed — the caller owns the data

  pub const NONE: u32 = std.math.maxInt(u32);

  pub fn init(alloc: Alloc) Distinct { return .{ .alloc = alloc }; }

  pub fn deinit(self: *Distinct) void {
    self.heads.deinit(self.alloc);
    self.next.deinit(self.alloc);
    self.keys.deinit(self.alloc);
  }

  pub fn count(self: *const Distinct) usize { return self.keys.items.len; }
  pub fn key(self: *const Distinct, g: usize) V { return self.keys.items[g]; }

  pub fn id(self: *Distinct, v: V) !u32 {
    const h = hashV(v);
    const head = self.heads.get(h) orelse NONE;
    var g = head;
    while (g != NONE) : (g = self.next.items[g]) {
      if (self.keys.items[g].eq(v)) return g;
    }
    const ng: u32 = @intCast(self.keys.items.len);
    try self.keys.append(self.alloc, v);
    try self.next.append(self.alloc, head);
    try self.heads.put(self.alloc, h, ng);
    return ng;
  }
};
