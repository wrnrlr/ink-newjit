//! Canonical registry of math "intrinsics" — the single source of truth that
//! ties together the many places a math function is currently spelled out:
//!
//!   CPU today (3 unrelated mechanisms):
//!     - grammar keyword verbs: lexer KEYWORD_OPS + Op1 enum + calc.zig kernel
//!       (`sqrt sqr exp log sin cos abs`)
//!     - "magic symbols": syms.zig string-match over std.math (`asin acos atan atan2`)
//!     - the FusedMap KOp micro-ISA (tape.zig): `sqr sqrt exp log sin cos` fuse
//!   GPU today (lib/dye.k): the `mathFns1`/`mathFns` name lists + lib/spirv.k op*.
//!
//! Every intrinsic is addressed by its *symbol name* (`sin, `atan2, …). The plan
//! (doc/design/dye.md, Phase 1) is to remove the grammar keywords and instead bind
//! ink names to these symbols in a prelude (lib/prelude.k for the CPU, the GPU
//! builtins in lib/dye.k), then have the peephole/optimizer recognise the intrinsic
//! symbol and lower it to the matching Op1/Op2/KOp (CPU) or SPIR-V op* (GPU). That
//! is a monomorphic call-site optimization: a call to a *known* intrinsic symbol is
//! inlined to an opcode.
//!
//! For now this table is DATA ONLY — nothing consumes it yet. A parity test in
//! src/test.zig asserts it stays faithful to the existing Op1/Op2 enums, so Phase 1
//! can flip the lexer/syms/fuse machinery over to it without drift.

const std = @import("std");
const Op1 = @import("../noun/operator.zig").Op1;
const Op2 = @import("../noun/operator.zig").Op2;

pub const Arity = enum(u8) { one = 1, two = 2, three = 3 };

pub const Intrinsic = struct {
  /// symbol name, e.g. "sin" — the `` `sin `` a program writes / a prelude binds.
  name: []const u8,
  arity: Arity,
  /// CPU monadic opcode it lowers to today (null ⇒ not yet an Op1; reached via
  /// syms.zig or only defined on the GPU).
  op1: ?Op1 = null,
  /// CPU dyadic opcode it lowers to today.
  op2: ?Op2 = null,
  /// Does it currently fuse into a FusedMap KOp kernel (compiler.zig fusableMapMon)?
  fuses: bool = false,
  /// Is it bound as a name in lib/prelude.k with a working CPU form? (Phase 1
  /// removed the 7 ex-keyword math verbs from the grammar and re-exposed them,
  /// plus the inverse-trig symbols, as prelude projections routed through
  /// syms.zig.) prelude=false ⇒ GPU-only today (lib/dye.k), no CPU kernel.
  prelude: bool = false,
  /// GLSL.std.450 extended-instruction number for the dye GPU lowering
  /// (0 ⇒ not a plain ext-inst: it maps to a core SPIR-V op like OpDot/OpFMod/OpFMul,
  /// or has no GPU form).
  glsl: u16 = 0,
};

pub const table = [_]Intrinsic{
  // ── 1-arg, ex-keyword verbs (Op1 + calc.zig kernel + KOp fuse); now prelude names ──
  .{ .name = "sqrt", .arity = .one, .op1 = .sqrt, .fuses = true, .prelude = true, .glsl = 31 },
  .{ .name = "sqr",  .arity = .one, .op1 = .sqr,  .fuses = true, .prelude = true, .glsl = 0 }, // OpFMul x,x
  .{ .name = "exp",  .arity = .one, .op1 = .exp,  .fuses = true, .prelude = true, .glsl = 27 },
  .{ .name = "log",  .arity = .one, .op1 = .log,  .fuses = true, .prelude = true, .glsl = 28 },
  .{ .name = "sin",  .arity = .one, .op1 = .sin,  .fuses = true, .prelude = true, .glsl = 13 },
  .{ .name = "cos",  .arity = .one, .op1 = .cos,  .fuses = true, .prelude = true, .glsl = 14 },
  .{ .name = "abs",  .arity = .one, .op1 = .abs,  .fuses = false, .prelude = true, .glsl = 4 }, // NOT fused today
  // ── 1-arg, inverse-trig symbols (syms.zig std.math); prelude names, no Op1 ──
  .{ .name = "asin", .arity = .one, .prelude = true, .glsl = 16 },
  .{ .name = "acos", .arity = .one, .prelude = true, .glsl = 17 },
  .{ .name = "atan", .arity = .one, .prelude = true, .glsl = 18 },
  // ── 1-arg, GPU-only today (lib/dye.k mathFns; no CPU kernel yet) ──
  .{ .name = "floor",     .arity = .one, .glsl = 8 },
  .{ .name = "fract",     .arity = .one, .glsl = 10 },
  .{ .name = "sign",      .arity = .one, .glsl = 6 },
  .{ .name = "tanh",      .arity = .one, .glsl = 21 },
  .{ .name = "length",    .arity = .one, .glsl = 66 },
  .{ .name = "normalize", .arity = .one, .glsl = 69 },
  // ── 2-arg ──
  .{ .name = "atan2", .arity = .two, .prelude = true, .glsl = 25 },
  .{ .name = "pow",   .arity = .two, .glsl = 26 },
  .{ .name = "min",   .arity = .two, .glsl = 37 },
  .{ .name = "max",   .arity = .two, .glsl = 40 },
  .{ .name = "step",  .arity = .two, .glsl = 48 },
  .{ .name = "cross", .arity = .two, .glsl = 68 },
  .{ .name = "dot",   .arity = .two, .glsl = 0 }, // OpDot (core), not ext-inst
  .{ .name = "mod",   .arity = .two, .op2 = .mod, .glsl = 0 }, // GPU OpFMod (core)
  // ── 3-arg ──
  .{ .name = "clamp",      .arity = .three, .glsl = 43 },
  .{ .name = "mix",        .arity = .three, .glsl = 46 },
  .{ .name = "smoothstep", .arity = .three, .glsl = 49 },
};

pub fn find(name: []const u8) ?Intrinsic {
  for (table) |it| if (std.mem.eql(u8, it.name, name)) return it;
  return null;
}

/// The names lib/prelude.k binds (the CPU math surface), derived from the table.
/// A test asserts prelude.k stays in sync with this list.
pub const prelude_names: []const []const u8 = blk: {
  var names: []const []const u8 = &.{};
  for (table) |it| if (it.prelude) {
    names = names ++ &[_][]const u8{it.name};
  };
  break :blk names;
};
