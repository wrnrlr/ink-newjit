const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const h = @import("helper.zig");

fn identityFn(_: *VM, x: V) V { return x.ref(); }
fn rightFn(_: *VM, _: V, y: V) V { return y.ref(); }

const all_k_types = blk: {
  const fields = @typeInfo(K).@"enum".fields;
  var ts: [fields.len]K = undefined;
  for (fields, 0..) |f, i| ts[i] = @enumFromInt(f.value);
  break :blk ts;
};

fn makeIdentity() type {
  @setEvalBranchQuota(1000000);
  const op_default: Op1 = .@":";
  const handler: VM.Monad = &identityFn;
  var names: []const []const u8 = &.{"op"};
  var field_types: []const type = &.{Op1};
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (all_k_types) |xk| {
    names = names ++ .{"_" ++ @tagName(xk)};
    field_types = field_types ++ .{VM.Monad};
    const attr: h.Attr = .{ .default_value_ptr = @ptrCast(&handler) };
    attrs = attrs ++ .{attr};
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

fn makeRight() type {
  @setEvalBranchQuota(1000000);
  const op_default: Op2 = .@":";
  const handler: VM.Dyad = &rightFn;
  var names: []const []const u8 = &.{"op"};
  var field_types: []const type = &.{Op2};
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (all_k_types) |xk| {
    for (all_k_types) |yk| {
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{VM.Dyad};
      const attr: h.Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const Identity = makeIdentity();
pub const Right = makeRight();

test "identity monad" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  const x = V{ .i = 42 };
  const r = identityFn(vm, x);
  try std.testing.expectEqual(@as(i32, 42), r.i);
}

test "right dyad" {
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  const x = V{ .i = 1 };
  const y = V{ .i = 99 };
  const r = rightFn(vm, x, y);
  try std.testing.expectEqual(@as(i32, 99), r.i);
}
