const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

/// I_Y: cut y into segments at the given indices.
pub const Cut = struct {
  _I_I: util.DyadFn = cutVec(.I),
  _I_F: util.DyadFn = cutVec(.F),
  _I_S: util.DyadFn = cutVec(.S),
  _I_C: util.DyadFn = cutVec(.C),
  _I_B: util.DyadFn = cutVec(.B),
  _I_L: util.DyadFn = cutList,
};

fn cutVec(comptime yk: K) util.DyadFn {
  return struct {
    fn f(vm: *VM, x: V, y: V) V {
      const idxs = x.I.slice();
      const ylen = y.len();
      const n = @field(y, @tagName(yk));
      const res = N(V).init(vm.alloc, idxs.len) catch return V{ .err = .memory };
      const yend: i32 = @intCast(ylen);
      for (idxs, 0..) |start_i64, j| {
        const start: usize = @intCast(util.clamp(start_i64, 0, yend));
        const end_i64: i32 = if (j + 1 < idxs.len) idxs[j + 1] else yend;
        const end: usize = @intCast(util.clamp(end_i64, 0, yend));
        const seg_len = if (end > start) end - start else 0;
        if (seg_len == 0) { res.slice()[j] = V.valuesFromSlice(vm.alloc, &.{}) catch return V{ .err = .memory }; continue; }
        const out = N(K.backing(yk)).init(vm.alloc, seg_len) catch return V{ .err = .memory };
        @memcpy(out.slice(), n.slice()[start .. start + seg_len]);
        res.slice()[j] = @unionInit(V, @tagName(yk), out);
      }
      return .{ .L = res };
    }
  }.f;
}

fn cutList(vm: *VM, x: V, y: V) V {
  const idxs = x.I.slice();
  const ylen = y.len();
  const res = N(V).init(vm.alloc, idxs.len) catch return V{ .err = .memory };
  const yend: i32 = @intCast(ylen);
  for (idxs, 0..) |start_i64, j| {
    const start: usize = @intCast(util.clamp(start_i64, 0, yend));
    const end_i64: i32 = if (j + 1 < idxs.len) idxs[j + 1] else yend;
    const end: usize = @intCast(util.clamp(end_i64, 0, yend));
    const seg_len = if (end > start) end - start else 0;
    if (seg_len == 0) { res.slice()[j] = V.valuesFromSlice(vm.alloc, &.{}) catch return V{ .err = .memory }; continue; }
    const sub = N(V).init(vm.alloc, seg_len) catch return V{ .err = .memory };
    for (0..seg_len) |k| sub.slice()[k] = y.at(start + k);
    res.slice()[j] = promote(vm.alloc, sub);
  }
  return .{ .L = res };
}

const testing = std.testing;

test "cut chars basic" {
  // 2 4 4 _ "abcde" -> ("cd"; ""; "e")
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  var x = try V.intsFromSlice(vm.alloc, &.{ 2, 4, 4 });
  defer x.deinit(vm.alloc);
  var y = try V.charsFromSlice(vm.alloc, "abcde");
  defer y.deinit(vm.alloc);
  const res = cutVec(.C)(vm, x, y);
  defer res.deinit(vm.alloc);
  const segs = res.L.slice();
  try testing.expectEqual(@as(usize, 3), segs.len);
  try testing.expectEqualSlices(u8, "cd", segs[0].C.slice());
  try testing.expectEqual(@as(usize, 0), segs[1].L.slice().len);
  try testing.expectEqualSlices(u8, "e", segs[2].C.slice());
}

test "cut integers" {
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  var x = try V.intsFromSlice(vm.alloc, &.{ 0, 3 });
  defer x.deinit(vm.alloc);
  var y = try V.intsFromSlice(vm.alloc, &.{ 10, 20, 30, 40, 50 });
  defer y.deinit(vm.alloc);
  const res = cutVec(.I)(vm, x, y);
  defer res.deinit(vm.alloc);
  const segs = res.L.slice();
  try testing.expectEqual(@as(usize, 2), segs.len);
  try testing.expectEqualSlices(i32, &.{ 10, 20, 30 }, segs[0].I.slice());
  try testing.expectEqualSlices(i32, &.{ 40, 50 }, segs[1].I.slice());
}

test "cut start past end" {
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  var x = try V.intsFromSlice(vm.alloc, &.{ 5, 10 });
  defer x.deinit(vm.alloc);
  var y = try V.intsFromSlice(vm.alloc, &.{ 1, 2, 3 });
  defer y.deinit(vm.alloc);
  const res = cutVec(.I)(vm, x, y);
  defer res.deinit(vm.alloc);
  const segs = res.L.slice();
  try testing.expectEqual(@as(usize, 2), segs.len);
  try testing.expectEqual(@as(usize, 0), segs[0].L.slice().len);
  try testing.expectEqual(@as(usize, 0), segs[1].L.slice().len);
}
