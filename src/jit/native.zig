const std = @import("std");
const exec = @import("exec.zig");
const emit = @import("emit.zig");

// ─── Native stencil compilation ───────────────────────────────────────────────
//
// Ties the A64 emitter to the executable-memory manager: emit a stencil, install
// it into a W^X page, hand back a callable C-ABI function plus the page so it can
// be freed. This is the copy-and-patch backend's entry point. Single-op stencils
// like these are NOT faster than the existing vectorized Zig kernels — the payoff
// comes from compiling *fused chains* (constants and op sequences baked in) into
// one native loop, which builds on exactly this machinery.

pub const ArrayBinFn = *const fn (out: [*]i32, x: [*]const i32, y: [*]const i32, n: usize) callconv(.c) void;

pub const Compiled = struct {
  buf: exec.ExecBuf,
  pub fn free(self: Compiled) void {
    self.buf.free();
  }
};

/// JIT-compile an elementwise i32 array stencil (`out[i] = x[i] OP y[i]`).
pub fn compileArrayBinOp(alloc: std.mem.Allocator, op: emit.BinOp) !struct { fn_ptr: ArrayBinFn, handle: Compiled } {
  var em = emit.Emitter.init(alloc);
  defer em.deinit();
  try emit.arrayBinOp(&em, op);
  const code = em.bytes();
  const buf = try exec.ExecBuf.alloc(code.len);
  buf.install(code);
  return .{ .fn_ptr = buf.entry(ArrayBinFn), .handle = .{ .buf = buf } };
}

pub const ChainFn = *const fn (out: [*]i32, leaves: [*]const [*]const i32, n: usize) callconv(.c) void;

/// JIT-compile an arbitrary elementwise i32 chain (postfix `tape` over leaf
/// arrays) into one native loop.
pub fn compileChain(alloc: std.mem.Allocator, tape: []const emit.Step) !struct { fn_ptr: ChainFn, handle: Compiled } {
  var em = emit.Emitter.init(alloc);
  defer em.deinit();
  try emit.arrayChain(&em, tape);
  const buf = try exec.ExecBuf.alloc(em.bytes().len);
  buf.install(em.bytes());
  return .{ .fn_ptr = buf.entry(ChainFn), .handle = .{ .buf = buf } };
}

// ─── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Reference evaluation of a postfix tape — the oracle the JIT must match.
fn refChain(tape: []const emit.Step, leaves: []const []const i32, i: usize) i32 {
  var stack: [16]i32 = undefined;
  var d: usize = 0;
  for (tape) |step| switch (step) {
    .load => |k| {
      stack[d] = leaves[k][i];
      d += 1;
    },
    .op => |o| {
      const b = stack[d - 1];
      const a = stack[d - 2];
      stack[d - 2] = switch (o) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
      };
      d -= 1;
    },
  };
  return stack[0];
}

test "jit: scalar add canary proves the exec pipeline" {
  if (!exec.supported) return error.SkipZigTest;
  var em = emit.Emitter.init(testing.allocator);
  defer em.deinit();
  try emit.scalarAdd(&em);
  const buf = try exec.ExecBuf.alloc(em.bytes().len);
  defer buf.free();
  buf.install(em.bytes());
  const f = buf.entry(*const fn (a: i32, b: i32) callconv(.c) i32);
  try testing.expectEqual(@as(i32, 7), f(3, 4));
  try testing.expectEqual(@as(i32, -1), f(5, -6));
}

test "jit: native array add/sub/mul match the interpreter semantics" {
  if (!exec.supported) return error.SkipZigTest;
  const cases = [_]struct { op: emit.BinOp, expect: [4]i32 }{
    .{ .op = .add, .expect = .{ 11, 22, 33, 44 } },
    .{ .op = .sub, .expect = .{ -9, -18, -27, -36 } },
    .{ .op = .mul, .expect = .{ 10, 40, 90, 160 } },
  };
  inline for (cases) |c| {
    const j = try compileArrayBinOp(testing.allocator, c.op);
    defer j.handle.free();
    var x = [_]i32{ 1, 2, 3, 4 };
    var y = [_]i32{ 10, 20, 30, 40 };
    var out = [_]i32{ 0, 0, 0, 0 };
    j.fn_ptr(&out, &x, &y, x.len);
    try testing.expectEqualSlices(i32, &c.expect, &out);
  }
}

test "jit: empty length is a no-op (cbz guard)" {
  if (!exec.supported) return error.SkipZigTest;
  const j = try compileArrayBinOp(testing.allocator, .add);
  defer j.handle.free();
  var out = [_]i32{42};
  var x = [_]i32{1};
  var y = [_]i32{1};
  j.fn_ptr(&out, &x, &y, 0);
  try testing.expectEqual(@as(i32, 42), out[0]); // untouched
}

test "jit: native fused chains of varying length/shape match the oracle" {
  if (!exec.supported) return error.SkipZigTest;
  const L = struct { fn p(a: []const i32) [*]const i32 {
    return a.ptr;
  } };
  const a = [_]i32{ 1, 2, 3, 4, 5 };
  const b = [_]i32{ 6, 7, 8, 9, 10 };
  const c = [_]i32{ 2, 2, 3, 3, 4 };
  const d = [_]i32{ 1, 1, 1, 1, 1 };
  const leaf_slices = [_][]const i32{ &a, &b, &c, &d };
  const leaf_ptrs = [_][*]const i32{ L.p(&a), L.p(&b), L.p(&c), L.p(&d) };

  const tapes = [_][]const emit.Step{
    &.{ .{ .load = 0 } }, // copy a
    &.{ .{ .load = 0 }, .{ .load = 0 }, .{ .op = .mul } }, // a*a (reused leaf)
    &.{ .{ .load = 0 }, .{ .load = 1 }, .{ .op = .add }, .{ .load = 2 }, .{ .op = .mul } }, // (a+b)*c
    &.{ .{ .load = 0 }, .{ .load = 1 }, .{ .op = .add }, .{ .load = 2 }, .{ .op = .mul }, .{ .load = 3 }, .{ .op = .sub } }, // ((a+b)*c)-d
    &.{ .{ .load = 0 }, .{ .load = 1 }, .{ .op = .add }, .{ .load = 2 }, .{ .op = .add }, .{ .load = 3 }, .{ .op = .add } }, // a+b+c+d
  };

  inline for (tapes) |tape| {
    const j = try compileChain(testing.allocator, tape);
    defer j.handle.free();
    var out = [_]i32{0} ** 5;
    j.fn_ptr(&out, &leaf_ptrs, out.len);
    for (out, 0..) |got, i| {
      try testing.expectEqual(refChain(tape, &leaf_slices, i), got);
    }
  }
}
