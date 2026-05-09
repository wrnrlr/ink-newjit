const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/value.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const pair = @import("pair.zig");
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

/// X_d: drop keys from a dict.
pub const DropKeys = struct {
  pub const op = .@"_";
  _s_m: util.DyadFn = dropKeys,
  _S_m: util.DyadFn = dropKeys,
  _i_m: util.DyadFn = dropKeys,
  _I_m: util.DyadFn = dropKeys,
  _f_m: util.DyadFn = dropKeys,
  _F_m: util.DyadFn = dropKeys,
  _c_m: util.DyadFn = dropKeys,
  _C_m: util.DyadFn = dropKeys,
};

// fn dropKeysFn(vm: *VM, x: V, y: V) V {
//   return dropKeys(vm.alloc, x, y.m);
// }

pub fn dropKeys(vm: *VM, x: V, y: V) V {
  const dav = y.m.av();
  const dbv = y.m.bv();
  const dict_len = dav.len();
  const xlen = x.len();
  var keep_keys: std.ArrayList(V) = .empty;
  var keep_vals: std.ArrayList(V) = .empty;
  defer { keep_keys.deinit(vm.alloc); keep_vals.deinit(vm.alloc); }
  keep_keys.ensureTotalCapacity(vm.alloc, dict_len) catch return V{ .err = .memory };
  keep_vals.ensureTotalCapacity(vm.alloc, dict_len) catch return V{ .err = .memory };
  for (0..dict_len) |i| {
    const k1 = dav.at(i);
    var found = false;
    for (0..xlen) |j| {
      const xv = x.at(j);
      defer xv.deinit(vm.alloc);
      if (k1.eq(xv)) { found = true; break; }
    }
    if (!found) {
      keep_keys.appendAssumeCapacity(k1);
      keep_vals.appendAssumeCapacity(dbv.at(i));
    } else k1.deinit(vm.alloc);
  }
  const n = keep_keys.items.len;
  // Symbol single-key: pass scalars so the [k:v] formatter shows the value directly (not enlisted)
  if (n == 1 and keep_keys.items[0].tag() == .s) {
    return pair.dict(vm, keep_keys.items[0], keep_vals.items[0]);
  }
  const rk = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  @memcpy(rk.slice(), keep_keys.items);
  const rv = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  @memcpy(rv.slice(), keep_vals.items);
  // n>1: promote vals so e.g. char atoms collapse to a typed vector ("ac" not "a" "c")
  // n==1 non-symbol: keep as L so key and val each display as enlisted scalars (,3!,"c")
  const vals_v: V = if (n > 1) promote(vm.alloc, rv) else .{ .L = rv };
  const res = pair.dict(vm, .{ .L = rk }, vals_v);
  (V{ .L = rk }).deinit(vm.alloc);
  vals_v.deinit(vm.alloc);
  return res;
}

const testing = std.testing;

// test "dropKeys symbol-keyed dict single remaining" {
//   // `a`b`c!0 1 2, drop `a`c → should leave {b:1}
//   const alloc = testing.allocator;
//   const ks = N(u32).init(alloc, 3) catch return V{ .err = .memory };
//   ks.slice()[0] = 1; ks.slice()[1] = 2; ks.slice()[2] = 3; // fake symbol ids a=1,b=2,c=3
//   const vs = N(i32).init(alloc, 3) catch return V{ .err = .memory };
//   @memcpy(vs.slice(), &[_]i32{0, 1, 2});
//   const d = try pair.dict(alloc, .{ .S = ks }, .{ .I = vs });
//   ks.deinit(alloc); vs.deinit(alloc); // dict retains its own copies
//   defer d.deinit(alloc);

//   const xk = N(u32).init(alloc, 2) catch return V{ .err = .memory };
//   xk.slice()[0] = 1; xk.slice()[1] = 3; // drop a=1 and c=3
//   const x = V{ .S = xk };
//   defer x.deinit(alloc);

//   const res = try dropKeys(alloc, x, d.m);
//   defer res.deinit(alloc);

//   const rk = res.m.av();
//   const rv = res.m.bv();
//   try testing.expectEqual(@as(usize, 1), rk.len());
//   try testing.expectEqual(@as(u32, 2), rk.at(0).s); // symbol id for b
//   try testing.expectEqual(@as(i32, 1), rv.at(0).i); // value 1
// }

// test "dropKeys int-keyed dict multiple drop" {
//   // 1 2 3!"abc", drop [2,1] → should leave {3:'c'}
//   const alloc = testing.allocator;
//   const ks = N(i32).init(alloc, 3) catch return V{ .err = .memory };
//   @memcpy(ks.slice(), &[_]i32{1, 2, 3});
//   const vs = N(u8).init(alloc, 3) catch return V{ .err = .memory };
//   @memcpy(vs.slice(), "abc");
//   const d = try pair.dict(alloc, .{ .I = ks }, .{ .C = vs });
//   ks.deinit(alloc); vs.deinit(alloc); // dict retains its own copies
//   defer d.deinit(alloc);

//   const xk = N(i32).init(alloc, 2) catch return V{ .err = .memory };
//   @memcpy(xk.slice(), &[_]i32{2, 1});
//   const x = V{ .I = xk };
//   defer x.deinit(alloc);

//   const res = try dropKeys(alloc, x, d.m);
//   defer res.deinit(alloc);

//   const rk = res.m.av();
//   const rv = res.m.bv();
//   try testing.expectEqual(@as(usize, 1), rk.len());
//   try testing.expectEqual(@as(i32, 3), rk.at(0).i);
//   try testing.expectEqual(@as(u32, 'c'), rv.at(0).c);
// }
