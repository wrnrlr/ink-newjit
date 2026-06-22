const std = @import("std");
const ir = @import("../ir.zig");
const infer = @import("infer.zig");
const tymod = @import("type.zig");
const Ty = tymod.Ty;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const verbs = @import("../../primitive/verb/verbs.zig");
const xfer = @import("../../primitive/verb/transfer.zig");
const stencil = @import("../../jit/stencil.zig");
const VM = @import("../vm.zig").VM;

const testing = std.testing;

fn scalarV(k: K) V {
  return switch (k) {
    .b => .{ .b = true },
    .i => .{ .i = 3 },
    .f => .{ .f = 1.5 },
    else => unreachable,
  };
}

// The transfer table is only trustworthy if it agrees with the actual dispatch
// kernels. For every scalar numeric slot the static `rty_dyad`/`rty_monad` claims
// to know, run the real kernel and assert the result class matches. This locks
// the per-verb strategy map in transfer.zig to the runtime forever — any drift
// becomes a test failure rather than a silent mis-typing.
test "dyad transfer table matches kernels (scalar slots)" {
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  const scalars = [_]K{ .b, .i, .f };
  inline for (std.meta.fields(Op2)) |opf| {
    const op: Op2 = @enumFromInt(opf.value);
    for (scalars) |xk| {
      for (scalars) |yk| {
        const expected = xfer.dyadResult(op, xk, yk) orelse continue;
        const key = op.code() * K.COUNT * K.COUNT + xk.code() * K.COUNT + yk.code();
        var res = verbs.dyad_table[key](vm, scalarV(xk), scalarV(yk));
        defer res.deinit(vm.alloc);
        if (res.tag() == .err) continue; // domain errors are not transfer disagreements
        testing.expectEqual(expected, res.tag()) catch |e| {
          std.debug.print("dyad {s} {s} {s} => expected {s}, got {s}\n", .{
            @tagName(op), @tagName(xk), @tagName(yk), @tagName(expected), @tagName(res.tag()),
          });
          return e;
        };
      }
    }
  }
}

test "monad transfer table matches kernels (scalar slots)" {
  const vm = try VM.create(testing.allocator);
  defer vm.deinit();
  const scalars = [_]K{ .b, .i, .f };
  inline for (std.meta.fields(Op1)) |opf| {
    const op: Op1 = @enumFromInt(opf.value);
    for (scalars) |xk| {
      const expected = xfer.monadResult(op, xk) orelse continue;
      const key = op.code() * K.COUNT + xk.code();
      var res = verbs.monad_table[key](vm, scalarV(xk));
      defer res.deinit(vm.alloc);
      if (res.tag() == .err) continue;
      testing.expectEqual(expected, res.tag()) catch |e| {
        std.debug.print("monad {s} {s} => expected {s}, got {s}\n", .{
          @tagName(op), @tagName(xk), @tagName(expected), @tagName(res.tag()),
        });
        return e;
      };
    }
  }
}

// ─── golden inference over hand-built IR ──────────────────────────────────────

fn ivec(alloc: std.mem.Allocator, vals: []const i32) V {
  const arr = N(i32).init(alloc, vals.len) catch unreachable;
  for (arr.slice(), vals) |*d, s| d.* = s;
  return .{ .I = arr };
}

fn inferK(graph: *ir.IR, id: ir.ValueId) ?K {
  infer.inferTypes(graph);
  return graph.get(id).ty.toK();
}

test "infer: scalar + scalar = scalar, with numeric promotion" {
  const alloc = testing.allocator;
  var g = ir.IR.init(alloc);
  defer g.deinit();
  const a = try g.emitConstant(.{ .i = 2 });
  const b = try g.emitConstant(.{ .f = 3.0 });
  const c = try g.emitWithArg(.Apply2, @intFromEnum(Op2.@"+"), &.{ a, b });
  try testing.expectEqual(@as(?K, .f), inferK(&g, c));
}

test "infer: comparison yields bool" {
  const alloc = testing.allocator;
  var g = ir.IR.init(alloc);
  defer g.deinit();
  const a = try g.emitConstant(.{ .i = 2 });
  const b = try g.emitConstant(.{ .i = 3 });
  const c = try g.emitWithArg(.Apply2, @intFromEnum(Op2.@"<"), &.{ a, b });
  try testing.expectEqual(@as(?K, .b), inferK(&g, c));
}

test "infer: vector + vector preserves vector class and length" {
  const alloc = testing.allocator;
  var g = ir.IR.init(alloc);
  defer g.deinit();
  var va = ivec(alloc, &.{ 1, 2, 3 });
  defer va.deinit(alloc);
  var vb = ivec(alloc, &.{ 4, 5, 6 });
  defer vb.deinit(alloc);
  const a = try g.emitConstant(va);
  const b = try g.emitConstant(vb);
  const c = try g.emitWithArg(.Apply2, @intFromEnum(Op2.@"+"), &.{ a, b });
  infer.inferTypes(&g);
  const t = g.get(c).ty;
  try testing.expectEqual(@as(?K, .I), t.toK());
  try testing.expect(t.shape[0].eql(.{ .known = 3 }));
}

test "infer: reduction collapses rank to a scalar" {
  const alloc = testing.allocator;
  var g = ir.IR.init(alloc);
  defer g.deinit();
  var va = ivec(alloc, &.{ 1, 2, 3 });
  defer va.deinit(alloc);
  const a = try g.emitConstant(va);
  const c = try g.emitWithArg(.Apply1, @intFromEnum(Op1.@"+/"), &.{a});
  try testing.expectEqual(@as(?K, .i), inferK(&g, c));
}

test "infer: branch merge joins arms up the lattice" {
  const alloc = testing.allocator;
  var g = ir.IR.init(alloc);
  defer g.deinit();
  var vi = ivec(alloc, &.{ 1, 2, 3 });
  defer vi.deinit(alloc);
  const a = try g.emitConstant(vi); // I
  const b = try g.emitConstant(.{ .f = 1.0 }); // f (scalar)
  // Merge of an int-vector arm and a float-scalar arm: elements join to f, but
  // the ranks disagree, so there is no precise runtime class.
  const m = try g.emit(.Nop, &.{ a, b });
  try testing.expectEqual(@as(?K, null), inferK(&g, m));
}

test "stencil: typed vector add selects the (+,I,I) stencil" {
  const alloc = testing.allocator;
  var g = ir.IR.init(alloc);
  defer g.deinit();
  var va = ivec(alloc, &.{ 1, 2, 3 });
  defer va.deinit(alloc);
  var vb = ivec(alloc, &.{ 4, 5, 6 });
  defer vb.deinit(alloc);
  const a = try g.emitConstant(va);
  const b = try g.emitConstant(vb);
  const c = try g.emitWithArg(.Apply2, @intFromEnum(Op2.@"+"), &.{ a, b });
  infer.inferTypes(&g);
  infer.selectStencils(&g);
  const id = g.get(c).stencil;
  try testing.expect(id != stencil.NONE);
  const s = stencil.dyad(id);
  try testing.expectEqual(@as(K, .I), s.x);
  try testing.expectEqual(@as(K, .I), s.y);
  try testing.expectEqual(@as(K, .I), s.out);
  try testing.expectEqual(Op2.@"+", s.op);
}

test "stencil: type threads through a local binding (a:vec; a+a)" {
  const alloc = testing.allocator;
  var g = ir.IR.init(alloc);
  defer g.deinit();
  var va = ivec(alloc, &.{ 1, 2, 3 });
  defer va.deinit(alloc);
  const c0 = try g.emitConstant(va);
  _ = try g.emitWithArg(.AssignLocal, 0, &.{c0}); // a: 1 2 3
  const l1 = try g.emitWithArg(.Local, 0, &.{});
  const l2 = try g.emitWithArg(.Local, 0, &.{});
  const add = try g.emitWithArg(.Apply2, @intFromEnum(Op2.@"+"), &.{ l1, l2 });
  infer.inferTypes(&g);
  infer.selectStencils(&g);
  // The local reads recover I, so a+a specializes to the (+,I,I) stencil.
  try testing.expectEqual(@as(?K, .I), g.get(l1).ty.toK());
  const id = g.get(add).stencil;
  try testing.expect(id != stencil.NONE);
  try testing.expectEqual(@as(K, .I), stencil.dyad(id).out);
}

test "stencil: dynamic operand leaves the instruction unspecialized" {
  const alloc = testing.allocator;
  var g = ir.IR.init(alloc);
  defer g.deinit();
  const a = try g.emitConstant(.{ .i = 2 });
  const local = try g.emit(.Local, &.{});
  const c = try g.emitWithArg(.Apply2, @intFromEnum(Op2.@"+"), &.{ a, local });
  infer.inferTypes(&g);
  infer.selectStencils(&g);
  try testing.expectEqual(stencil.NONE, g.get(c).stencil);
}

test "infer: unknown operand degrades to dynamic (no precise K)" {
  const alloc = testing.allocator;
  var g = ir.IR.init(alloc);
  defer g.deinit();
  const a = try g.emitConstant(.{ .i = 2 });
  const local = try g.emit(.Local, &.{}); // unknown provenance → TOP
  const c = try g.emitWithArg(.Apply2, @intFromEnum(Op2.@"+"), &.{ a, local });
  try testing.expectEqual(@as(?K, null), inferK(&g, c));
}
