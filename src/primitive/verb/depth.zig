const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

// depth p — apter-tree node depths from a parent-index vector.
//
// `p[i]` is node i's parent. A node is a root (depth 0) when `p[i] == i`,
// `p[i] < 0`, or `p[i]` is out of range. `depth[i]` is the number of steps from
// node i up to its root. O(n) with path memoization (each node resolved once).
// A cycle (no reachable root) is a domain error rather than an infinite loop.
//
// This is the foundational apter-tree op: a level-batched scene-graph / UI
// transform propagation processes nodes in `<depth p` order (parents first).
pub const Depth = struct {
  pub const op = .depth;
  _I: VM.Monad = depthI,
};

fn depthI(vm: *VM, x: V) V {
  const p = x.I.slice();
  const n = p.len;
  const d = N(i32).init(vm.alloc, n) catch return V{ .err = .memory };
  const ds = d.slice();
  for (ds) |*v| v.* = -1;

  var path: std.ArrayList(usize) = .empty;
  defer path.deinit(vm.alloc);

  for (0..n) |i| {
    if (ds[i] != -1) continue;
    path.clearRetainingCapacity();
    var j = i;
    var base: i32 = undefined;
    while (true) {
      if (ds[j] != -1) { base = ds[j]; break; }
      const par = p[j];
      const is_root = par < 0 or par >= @as(i32, @intCast(n)) or par == @as(i32, @intCast(j));
      if (is_root) { ds[j] = 0; base = 0; break; }
      path.append(vm.alloc, j) catch { d.deinit(vm.alloc); return V{ .err = .memory }; };
      if (path.items.len > n) { d.deinit(vm.alloc); return V{ .err = .domain }; } // cycle
      j = @intCast(par);
    }
    // Backfill the path: nearest-to-root first. The last node pushed is the one
    // whose parent is `j`, so it gets base+1, its child base+2, … up to node i.
    var k = path.items.len;
    while (k > 0) {
      k -= 1;
      base += 1;
      ds[path.items[k]] = base;
    }
  }
  return .{ .I = d };
}
