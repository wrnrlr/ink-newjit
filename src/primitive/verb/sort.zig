const std = @import("std");
const radix = @import("sort/radixsort.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const Alloc = std.mem.Allocator;

fn asc(vm: *VM, x: V) V { return sortIndices(vm.alloc, x, false); }
fn dsc(vm: *VM, x: V) V { return sortIndices(vm.alloc, x, true); }

/// Exported for use by other verbs that need to fall back to grade operations.
pub fn gradeDescend(vm: *VM, x: V) V { return dsc(vm, x); }
pub fn gradeAscend(vm: *VM, x: V) V { return asc(vm, x); }

pub const Ascend = struct {
  pub const op = .@"<";
  _b: VM.Monad = asc, _i: VM.Monad = asc, _f: VM.Monad = asc,
  _n: VM.Monad = asc, _d: VM.Monad = asc, _h: VM.Monad = asc,
  _c: VM.Monad = asc, _B: VM.Monad = asc, _I: VM.Monad = asc,
  _F: VM.Monad = asc, _N: VM.Monad = asc, _D: VM.Monad = asc, _H: VM.Monad = asc,
  _S: VM.Monad = asc, _C: VM.Monad = asc, _L: VM.Monad = asc,
};

pub const Descend = struct {
  pub const op = .@">";
  _b: VM.Monad = dsc, _i: VM.Monad = dsc, _f: VM.Monad = dsc,
  _n: VM.Monad = dsc, _d: VM.Monad = dsc, _h: VM.Monad = dsc,
  _s: VM.Monad = dsc, _c: VM.Monad = dsc, _B: VM.Monad = dsc,
  _I: VM.Monad = dsc, _F: VM.Monad = dsc, _N: VM.Monad = dsc,
  _D: VM.Monad = dsc, _H: VM.Monad = dsc, _S: VM.Monad = dsc,
  _C: VM.Monad = dsc, _L: VM.Monad = dsc,
};

fn compareV(a: V, b: V) std.math.Order {
  const at = a.tag();
  const bt = b.tag();
  if (at != bt) return std.math.order(@intFromEnum(at), @intFromEnum(bt));
  return switch (at) {
    .i => std.math.order(a.i, b.i),
    .f => blk: {
      const an = std.math.isNan(a.f);
      const bn = std.math.isNan(b.f);
      if (an and bn) break :blk .eq;
      if (an) break :blk .lt;
      if (bn) break :blk .gt;
      break :blk std.math.order(a.f, b.f);
    },
    .c => std.math.order(a.c, b.c),
    .n => std.math.order(a.n, b.n),
    .d => blk: {
      const an = std.math.isNan(a.d); const bn = std.math.isNan(b.d);
      if (an and bn) break :blk .eq;
      if (an) break :blk .lt;
      if (bn) break :blk .gt;
      break :blk std.math.order(a.d, b.d);
    },
    .h => blk: {
      const an = std.math.isNan(a.h); const bn = std.math.isNan(b.h);
      if (an and bn) break :blk .eq;
      if (an) break :blk .lt;
      if (bn) break :blk .gt;
      break :blk std.math.order(a.h, b.h);
    },
    .b => std.math.order(@intFromBool(a.b), @intFromBool(b.b)),
    .s => std.math.order(a.s, b.s),
    .I => blk: {
      const sa = a.I.slice(); const sb = b.I.slice();
      const n = @min(sa.len, sb.len);
      for (sa[0..n], sb[0..n]) |ai, bi| { const o = std.math.order(ai, bi); if (o != .eq) break :blk o; }
      break :blk std.math.order(sa.len, sb.len);
    },
    .F => blk: {
      const sa = a.F.slice(); const sb = b.F.slice();
      const n = @min(sa.len, sb.len);
      for (sa[0..n], sb[0..n]) |ai, bi| {
        const an2 = std.math.isNan(ai); const bn2 = std.math.isNan(bi);
        if (an2 and bn2) continue;
        if (an2) break :blk .lt;
        if (bn2) break :blk .gt;
        const o = std.math.order(ai, bi); if (o != .eq) break :blk o;
      }
      break :blk std.math.order(sa.len, sb.len);
    },
    .N => blk: {
      const sa = a.N.slice(); const sb = b.N.slice();
      const n = @min(sa.len, sb.len);
      for (sa[0..n], sb[0..n]) |ai, bi| { const o = std.math.order(ai, bi); if (o != .eq) break :blk o; }
      break :blk std.math.order(sa.len, sb.len);
    },
    .D => blk: {
      const sa = a.D.slice(); const sb = b.D.slice();
      const n = @min(sa.len, sb.len);
      for (sa[0..n], sb[0..n]) |ai, bi| {
        const an2 = std.math.isNan(ai); const bn2 = std.math.isNan(bi);
        if (an2 and bn2) continue;
        if (an2) break :blk .lt;
        if (bn2) break :blk .gt;
        const o = std.math.order(ai, bi); if (o != .eq) break :blk o;
      }
      break :blk std.math.order(sa.len, sb.len);
    },
    .H => blk: {
      const sa = a.H.slice(); const sb = b.H.slice();
      const n = @min(sa.len, sb.len);
      for (sa[0..n], sb[0..n]) |ai, bi| {
        const an2 = std.math.isNan(ai); const bn2 = std.math.isNan(bi);
        if (an2 and bn2) continue;
        if (an2) break :blk .lt;
        if (bn2) break :blk .gt;
        const o = std.math.order(ai, bi); if (o != .eq) break :blk o;
      }
      break :blk std.math.order(sa.len, sb.len);
    },
    .C => blk: {
      break :blk std.mem.order(u8, a.C.slice(), b.C.slice());
    },
    .B => blk: {
      const sa = a.B.slice(); const sb = b.B.slice();
      const n = @min(sa.len, sb.len);
      for (sa[0..n], sb[0..n]) |ai, bi| { const o = std.math.order(@intFromBool(ai), @intFromBool(bi)); if (o != .eq) break :blk o; }
      break :blk std.math.order(sa.len, sb.len);
    },
    .L => blk: {
      const la = a.L.slice(); const lb = b.L.slice();
      const n = @min(la.len, lb.len);
      for (la[0..n], lb[0..n]) |ai, bi| { const o = compareV(ai, bi); if (o != .eq) break :blk o; }
      break :blk std.math.order(la.len, lb.len);
    },
    else => .eq,
  };
}

fn Context(comptime T: type) type {
  return struct {
    data: T,
    desc: bool,
    fn cmp(self: @This(), lhs: usize, rhs: usize) bool {
      const a = self.data[lhs];
      const b = self.data[rhs];
      const VType = std.meta.Child(T);
      if (comptime @typeInfo(VType) == .float) {
        const a_nan = std.math.isNan(a);
        const b_nan = std.math.isNan(b);
        if (a_nan and !b_nan) return !self.desc;
        if (!a_nan and b_nan) return self.desc;
        if (a_nan and b_nan) return false;
      }
      if (a == b) return false;
      if (comptime VType == bool) return if (self.desc) a else b;
      return if (self.desc) a > b else a < b;
    }
  };
}

pub fn sortIndices(alloc: Alloc, v: V, desc: bool) V {
  if (v.isAtom()) {
    const res = N(i32).init(alloc, 1) catch return V{ .err = .memory };
    res.slice()[0] = 0;
    return .{ .I = res };
  }

  const length = v.len();
  var indices = N(i32).init(alloc, length) catch return V{ .err = .memory };
  var idx_buf = alloc.alloc(usize, length) catch {
    (V{ .I = indices }).deinit(alloc);
    return V{ .err = .memory };
  };
  defer alloc.free(idx_buf);
  for (0..length) |i| idx_buf[i] = i;

  switch (v) {
    .I => |n| radix.sortI32(alloc, idx_buf, n.slice(), desc) catch return V{ .err = .memory },
    .S => |n| radix.sortU32(alloc, idx_buf, n.slice(), desc) catch return V{ .err = .memory },
    .N => |n| radix.sortU32(alloc, idx_buf, n.slice(), desc) catch return V{ .err = .memory },
    .C => |n| radix.sortU8(alloc, idx_buf, n.slice(), desc) catch return V{ .err = .memory },
    inline .F, .B, .D, .H => |n| {
      const Ctx = Context(@TypeOf(n.slice()));
      std.sort.block(usize, idx_buf, Ctx{ .data = n.slice(), .desc = desc }, Ctx.cmp);
    },
    .L => |n| {
      const LCtx = struct {
        data: []const V, desc: bool,
        fn cmp(self: @This(), lhs: usize, rhs: usize) bool {
          const ord = compareV(self.data[lhs], self.data[rhs]);
          return if (self.desc) ord == .gt else ord == .lt;
        }
      };
      std.sort.block(usize, idx_buf, LCtx{ .data = n.slice(), .desc = desc }, LCtx.cmp);
    },
    else => return .{ .err = .@"type" },
  }

  const res_slice = indices.slice();
  for (idx_buf, 0..) |idx, i| res_slice[i] = @intCast(idx);
  return .{ .I = indices };
}
