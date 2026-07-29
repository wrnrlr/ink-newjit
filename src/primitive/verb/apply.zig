const std = @import("std");
const value = @import("../../noun/value.zig");
const calc = @import("./calc.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const Dict = value.Dict;
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const opmod = @import("../../noun/operator.zig");
const Op2 = opmod.Op2;
const Call = @import("../../runtime/call.zig").Call;
const syms = @import("../../runtime/syms.zig");
const h = @import("helper.zig");
const pick = @import("pick.zig");

// Apply1  @ (dyad): func/partial/symbol applied to a single argument

const all_k_types = blk: {
  const fields = @typeInfo(K).@"enum".fields;
  var ts: [fields.len]K = undefined;
  for (fields, 0..) |f, i| ts[i] = @enumFromInt(f.value);
  break :blk ts;
};

fn makeApply1() type {
  @setEvalBranchQuota(100000);
  const op_default: Op2 = .@"@";
  var names: []const []const u8 = &.{"op"};
  var field_types: []const type = &.{Op2};
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  const apply_x_types = [_]K{ .o, .p, .s };
  for (apply_x_types) |xk| {
    for (all_k_types) |yk| {
      const handler: VM.Dyad = if (xk == .s) &applySymFn else &applyFnFn;
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{VM.Dyad};
      const attr: h.Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const Apply = makeApply1();

fn applyFnFn(vm: *VM, x: V, y: V) V {
  var fc = Call{ .vm = vm };
  return fc.apply(x, &.{y}, false);
}

fn applySymFn(vm: *VM, x: V, y: V) V {
  return syms.apply(vm, x.s, &.{y}) catch V{ .err = .memory };
}

// ApplyN  . (dyad): deep index `x . path`, and multi-argument application
// `f . args` — the items of y become the arguments, so a call whose argument
// count is only known at runtime is expressible. Matches ngn/k:
//   {x+y} . 1 2      → 3          args from a vector
//   {x+y} . (1;2)    → 3          args from a general list
//   {x+y} . 1        → {x+y}[1;]  an atom is a single argument
//   {x+y} . ()       → {x+y}      no arguments applies nothing
fn makeApplyFn() type {
  @setEvalBranchQuota(100000);
  const op_default: Op2 = .@".";
  var names: []const []const u8 = &.{"op"};
  var field_types: []const type = &.{Op2};
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  // Callable on the left; anything that can carry arguments on the right.
  // Dicts/tables/functions as the right operand stay a type error (no rows).
  const fn_x = [_]K{ .o, .p, .s, .x };
  const arg_y = [_]K{
    .b, .i, .f, .n, .s, .c, .d, .h,
    .B, .I, .F, .N, .S, .C, .D, .H, .L,
  };
  for (fn_x) |xk| {
    for (arg_y) |yk| {
      const handler: VM.Dyad = &applyArgsFn;
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{VM.Dyad};
      attrs = attrs ++ .{h.Attr{ .default_value_ptr = @ptrCast(&handler) }};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const ApplyFn = makeApplyFn();

fn applyArgsFn(vm: *VM, x: V, y: V) V {
  var fc = Call{ .vm = vm };
  if (y.tag().isAtom()) return fc.apply(x, &.{y}, false);
  const n = y.len();
  if (n == 0) return x.ref();                      // f . () → f, nothing applied
  if (n > opmod.MAX_ARGS) return .{ .err = .rank };
  var args: [opmod.MAX_ARGS]V = undefined;
  for (0..n) |i| args[i] = y.at(i);                // at() hands back owned refs
  defer for (args[0..n]) |*a| a.deinit(vm.alloc);
  return fc.apply(x, args[0..n], false);
}

// `x . path` for containers: one `@` per path item. Generated over every
// indexable left type so `.` and `@` agree on what indexing means — `@` stays
// the authority on each single step, `.` only supplies the depth.
fn makeApplyIdx() type {
  @setEvalBranchQuota(100000);
  const op_default: Op2 = .@".";
  var names: []const []const u8 = &.{"op"};
  var field_types: []const type = &.{Op2};
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  const idx_x = [_]K{ .B, .I, .F, .N, .S, .C, .D, .H, .L, .m, .M };
  const atom_y = [_]K{ .b, .i, .s };                  // a single index
  const path_y = [_]K{ .B, .I, .S, .L };              // a path of them
  for (idx_x) |xk| {
    for (atom_y ++ path_y) |yk| {
      const is_path = for (path_y) |p| { if (p == yk) break true; } else false;
      const handler: VM.Dyad = if (is_path) &dotPath else &applyAtom;
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{VM.Dyad};
      attrs = attrs ++ .{h.Attr{ .default_value_ptr = @ptrCast(&handler) }};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const ApplyN = makeApplyIdx();

fn applyAtom(vm: *VM, x: V, y: V) V {
  var fc = Call{ .vm = vm };
  return fc.apply(x, &.{y}, false);
}

/// `x . path` — index x at each item of the path in turn. Folded one step at a
/// time rather than marshalled into an argument buffer, so a path may be deeper
/// than MAX_ARGS (that cap is about call arguments, not index depth).
fn dotPath(vm: *VM, x: V, y: V) V {
  var fc = Call{ .vm = vm };
  var res = x.ref();
  for (0..y.len()) |i| {
    const idx = y.at(i);
    defer idx.deinit(vm.alloc);
    const next = fc.apply(res, &.{idx}, false);
    res.deinit(vm.alloc);
    if (next.tag() == .err) return next;
    res = next;
  }
  return res;
}
