const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const pick = @import("pick.zig");
const h = @import("helper.zig");

pub const Reverse = h._G(.@"|", &.{ .B, .I, .F, .N, .D, .H, .S, .C, .L }, reverse);

// `|d` reverses the entry order, keys and values together, so it stays the same
// mapping — only the order the entries are listed in flips. A keyed table (both
// halves tables) reverses its rows.
pub const ReverseDict = struct {
  pub const op = .@"|";
  _m: VM.Monad = reverseDict,
};

fn reverseDict(vm: *VM, x: V) V {
  const keys = x.m.av();
  const n = keys.len();
  if (n < 2) return x.ref();
  const idx = N(i32).init(vm.alloc, n) catch return V{ .err = .memory };
  for (idx.slice(), 0..) |*r, i| r.* = @intCast(n - 1 - i);
  const g = V{ .I = idx };
  defer g.deinit(vm.alloc);
  const nk = pick.permute(vm, keys, g);
  if (nk.tag() == .err) return nk;
  const nv = pick.permute(vm, x.m.bv(), g);
  if (nv.tag() == .err) { nk.deinit(vm.alloc); return nv; }
  const d = Dict.init(vm.alloc, nk, nv) catch {
    nk.deinit(vm.alloc); nv.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

fn reverse(comptime yk: K) VM.Monad {
  const T = comptime if (yk == .L) V else K.backing(yk);
  return struct {
    fn f(vm: *VM, x: V) V {
      const b = @field(x, @tagName(yk));
      const res = N(T).init(vm.alloc, b.ptr.len) catch return V{ .err = .memory };
      const src = b.slice();
      const dst = res.slice();
      for (src, 0..) |v, i| dst[src.len - 1 - i] = if (yk == .L) v.ref() else v;
      return @unionInit(V, @tagName(yk), res);
    }
  }.f;
}
