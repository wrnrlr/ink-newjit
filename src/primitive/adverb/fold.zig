const std = @import("std");
const util = @import("../../util.zig");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const Op = @import("../../runtime/tape.zig").Op;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

// CPU fast path: builtin reduce on a typed CPU array.
// Avoids per-element boxing and function-pointer overhead.
// LLVM auto-vectorises these simple accumulation loops.
inline fn cpuReduce(op: Op, x: V) ?V {
  switch (x.tag()) {
    .I => {
      const s = x.I.slice();
      if (s.len == 0) return .blank;
      switch (op) {
        .@"+" => {
          var acc: i32 = s[0];
          for (s[1..]) |v| acc +%= v;
          return .{ .i = acc };
        },
        .@"*" => {
          var acc: i32 = s[0];
          for (s[1..]) |v| acc *%= v;
          return .{ .i = acc };
        },
        .@"&" => {
          var acc = s[0];
          for (s[1..]) |v| acc = @min(acc, v);
          return .{ .i = acc };
        },
        .@"|" => {
          var acc = s[0];
          for (s[1..]) |v| acc = @max(acc, v);
          return .{ .i = acc };
        },
        else => {},
      }
    },
    .F => {
      const s = x.F.slice();
      if (s.len == 0) return .blank;
      switch (op) {
        .@"+" => {
          var acc: f32 = s[0];
          for (s[1..]) |v| acc += v;
          return .{ .f = acc };
        },
        .@"*" => {
          var acc: f32 = s[0];
          for (s[1..]) |v| acc *= v;
          return .{ .f = acc };
        },
        .@"&" => {
          var acc = s[0];
          for (s[1..]) |v| acc = @min(acc, v);
          return .{ .f = acc };
        },
        .@"|" => {
          var acc = s[0];
          for (s[1..]) |v| acc = @max(acc, v);
          return .{ .f = acc };
        },
        else => {},
      }
    },
    .B => {
      const s = x.B.slice();
      if (s.len == 0) return .blank;
      switch (op) {
        .@"+" => {
          var acc: i32 = 0;
          for (s) |v| if (v) { acc += 1; };
          return .{ .i = acc };
        },
        .@"&" => {
          var acc = s[0];
          for (s[1..]) |v| acc = acc and v;
          return .{ .b = acc };
        },
        .@"|" => {
          var acc = s[0];
          for (s[1..]) |v| acc = acc or v;
          return .{ .b = acc };
        },
        else => {},
      }
    },
    else => {},
  }
  return null;
}

pub fn fold(vm: *VM, base: V, init: ?V, x: V, f: util.ApplyFn) V {
  // CPU fast path: no init, builtin op, typed array — bypass per-element dispatch.
  if (init == null and base.tag() == .func and base.func.getKind() == .builtin) {
    if (cpuReduce(base.func.getOp(), x)) |v| return v;
  }

  const n = x.len();

  var accum = if (init) |v| v.ref() else blk: {
    if (n == 0) return .blank;
    break :blk x.at(0);
  };

  const start: usize = if (init != null) 0 else 1;

  if (base.tag() == .func and base.func.getKind() == .lambda) {
    const ref = base.func;
    for (start..n) |i| {
      const item = x.at(i);
      const args = [_]V{ accum, item };
      const next = vm.callLambdaAndRun(ref, &args);
      item.deinit(vm.alloc);
      accum.deinit(vm.alloc);
      accum = next;
    }
    return accum;
  }

  for (start..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{ accum, item };
    const next = f(vm, base, &args);
    accum.deinit(vm.alloc);
    accum = next;
  }
  return accum;
}
