const std = @import("std");
const Alloc = std.mem.Allocator;
const Chunk = @import("../runtime/tape.zig").Chunk;
const Op = @import("../runtime/tape.zig").Op;
const K = @import("class.zig").K;
const util = @import("../util.zig");
const activeTag = std.meta.activeTag;
pub const ExtObj = @import("plugin.zig").ExtObj;
pub const ExtVTable = @import("plugin.zig").ExtVTable;
pub const ExtRegistry = @import("plugin.zig").ExtRegistry;

pub const Adverb = enum(u8) {
  @"'", @"/", @"\\", @"':", @"/:", @"\\:",
  pub const COUNT = @typeInfo(Adverb).@"enum".fields.len;
  pub fn toString(self: Adverb) []const u8 { return @tagName(self); }
};

/// Adverb form when the derived verb is called with a single data argument
/// (e.g. `f/x`). `/:` and `\:` are NOT valid here — they are 2-arg-only.
pub const Adverb2 = enum(u8) {
  @"'", @"/", @"\\", @"':",

  pub const COUNT = @typeInfo(Adverb2).@"enum".fields.len;
  pub fn fromAdverb(adv: Adverb) ?Adverb2 {
    return std.meta.stringToEnum(Adverb2, @tagName(adv));
  }
  pub fn toAdverb(self: Adverb2) Adverb {
    return std.meta.stringToEnum(Adverb, @tagName(self)).?;
  }
};

/// Adverb form when the derived verb is called with two data arguments
/// (e.g. `x f/y`, the "digram" form, plus `f/:` eachright / `f\:` eachleft).
pub const Adverb3 = enum(u8) {
  @"'", @"/", @"\\", @"':", @"/:", @"\\:",

  pub const COUNT = @typeInfo(Adverb3).@"enum".fields.len;
  pub fn fromAdverb(adv: Adverb) Adverb3 {
    return std.meta.stringToEnum(Adverb3, @tagName(adv)).?;
  }
  pub fn toAdverb(self: Adverb3) Adverb {
    return std.meta.stringToEnum(Adverb, @tagName(self)).?;
  }
};

/// Monadic primitives. Apply1 bytecode + monad dispatch table.
pub const Op1 = enum(u8) {
  // symbol/glyph verbs
  @"%", @"!", @"&", @"+", @"*", @"|", @"<", @">", @"=", @"~",
  @",", @"^", @"#", @"_", @"$", @"?", @"@", @"-", @".",
  // math keywords
  sqrt, sqr, exp, log, sin, cos, abs,
  // selection keywords
  first, last, count, parse,
  // io verbs (monadic forms)
  @"0:", @"1:", @"2:", @"9:",
  exec,
  // fused monad-only derived verbs (sum, product, min, max)
  @"+/", @"*/", @"|/", @"&/",

  pub const COUNT = @typeInfo(Op1).@"enum".fields.len;

  pub fn fromString(s: []const u8) ?Op1 { return std.meta.stringToEnum(Op1, s); }
  pub fn toString(self: Op1) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op1) usize { return @intFromEnum(op); }
  pub fn fromOp(op: Op) ?Op1 { return std.meta.stringToEnum(Op1, @tagName(op)); }
};

/// Dyadic primitives. Apply2 bytecode + dyad dispatch table.
pub const Op2 = enum(u8) {
  @"%", @"!", @"&", @"+", @"*", @"|", @"<", @">", @"=", @"~",
  @",", @"^", @"#", @"_", @"$", @"?", @"@", @"-", @".",
  in, has,
  mod, div,
  @"0:", @"1:", @"2:", @"9:",
  @":",
  exec,

  pub const COUNT = @typeInfo(Op2).@"enum".fields.len;

  pub fn fromString(s: []const u8) ?Op2 { return std.meta.stringToEnum(Op2, s); }
  pub fn toString(self: Op2) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op2) usize { return @intFromEnum(op); }
  pub fn fromOp(op: Op) ?Op2 { return std.meta.stringToEnum(Op2, @tagName(op)); }
};

/// Triadic primitives. Apply3 bytecode (amend3/drill3).
pub const Op3 = enum(u8) {
  amend3, // @[x;i;f]
  drill3, // .[x;p;f]

  pub const COUNT = @typeInfo(Op3).@"enum".fields.len;
  pub fn fromString(s: []const u8) ?Op3 { return std.meta.stringToEnum(Op3, s); }
  pub fn toString(self: Op3) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op3) usize { return @intFromEnum(op); }
};

/// Tetradic primitives. Apply4 bytecode (amend4/drill4).
pub const Op4 = enum(u8) {
  amend4, // @[x;i;f;v]
  drill4, // .[x;p;f;v]

  pub const COUNT = @typeInfo(Op4).@"enum".fields.len;
  pub fn fromString(s: []const u8) ?Op4 { return std.meta.stringToEnum(Op4, s); }
  pub fn toString(self: Op4) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op4) usize { return @intFromEnum(op); }
};

// ─── Unified global builtin index space ───────────────────────────────────────
//
// Every builtin callable — verb (Op1..Op4) or adverb (Adverb2/Adverb3) — gets
// a single global index. The arity and category are determined purely from the
// idx range:
//
//   [0,            OP1_END)         monadic    (Op1)         arity = 1
//   [OP1_END,      OP2_END)         dyadic     (Op2)         arity = 2
//   [OP2_END,      ADVERB2_END)     dyadic     (Adverb2)     arity = 2
//   [ADVERB2_END,  OP3_END)         triadic    (Op3)         arity = 3
//   [OP3_END,      ADVERB3_END)     triadic    (Adverb3)     arity = 3
//   [ADVERB3_END,  OP4_END)         tetradic   (Op4)         arity = 4
//   [BUILTIN_COUNT, ...)            user-defined lambda — idx - BUILTIN_COUNT
//                                   is the lambda_table index.

pub const OP1_END:        u32 = Op1.COUNT;
pub const OP2_END:        u32 = OP1_END + Op2.COUNT;
pub const ADVERB2_END:    u32 = OP2_END + Adverb2.COUNT;
pub const OP3_END:        u32 = ADVERB2_END + Op3.COUNT;
pub const ADVERB3_END:    u32 = OP3_END + Adverb3.COUNT;
pub const OP4_END:        u32 = ADVERB3_END + Op4.COUNT;
pub const BUILTIN_COUNT:  u32 = OP4_END;

pub inline fn isBuiltinIdx(idx: u32) bool { return idx < BUILTIN_COUNT; }
pub inline fn isLambdaIdx(idx: u32)  bool { return idx >= BUILTIN_COUNT; }

pub inline fn isOp1Idx(idx: u32)     bool { return idx < OP1_END; }
pub inline fn isOp2Idx(idx: u32)     bool { return idx >= OP1_END    and idx < OP2_END; }
pub inline fn isAdverb2Idx(idx: u32) bool { return idx >= OP2_END    and idx < ADVERB2_END; }
pub inline fn isOp3Idx(idx: u32)     bool { return idx >= ADVERB2_END and idx < OP3_END; }
pub inline fn isAdverb3Idx(idx: u32) bool { return idx >= OP3_END    and idx < ADVERB3_END; }
pub inline fn isOp4Idx(idx: u32)     bool { return idx >= ADVERB3_END and idx < OP4_END; }
pub inline fn isAdverbIdx(idx: u32)  bool { return isAdverb2Idx(idx) or isAdverb3Idx(idx); }

pub fn arityOfBuiltin(idx: u32) u8 {
  if (idx < OP1_END)     return 1;
  if (idx < ADVERB2_END) return 2;
  if (idx < ADVERB3_END) return 3;
  if (idx < OP4_END)     return 4;
  unreachable;
}

pub inline fn idxForOp1(op: Op1) u32          { return @intFromEnum(op); }
pub inline fn idxForOp2(op: Op2) u32          { return OP1_END    + @intFromEnum(op); }
pub inline fn idxForAdverb2(a: Adverb2) u32   { return OP2_END    + @intFromEnum(a); }
pub inline fn idxForOp3(op: Op3) u32          { return ADVERB2_END + @intFromEnum(op); }
pub inline fn idxForAdverb3(a: Adverb3) u32   { return OP3_END    + @intFromEnum(a); }
pub inline fn idxForOp4(op: Op4) u32          { return ADVERB3_END + @intFromEnum(op); }
pub inline fn idxForLambda(lambda_idx: u24) u32 { return BUILTIN_COUNT + lambda_idx; }

pub inline fn op1OfIdx(idx: u32) Op1         { return @enumFromInt(@as(u8, @intCast(idx))); }
pub inline fn op2OfIdx(idx: u32) Op2         { return @enumFromInt(@as(u8, @intCast(idx - OP1_END))); }
pub inline fn adverb2OfIdx(idx: u32) Adverb2 { return @enumFromInt(@as(u8, @intCast(idx - OP2_END))); }
pub inline fn op3OfIdx(idx: u32) Op3         { return @enumFromInt(@as(u8, @intCast(idx - ADVERB2_END))); }
pub inline fn adverb3OfIdx(idx: u32) Adverb3 { return @enumFromInt(@as(u8, @intCast(idx - OP3_END))); }
pub inline fn op4OfIdx(idx: u32) Op4         { return @enumFromInt(@as(u8, @intCast(idx - ADVERB3_END))); }
pub inline fn lambdaIdxOf(idx: u32) u24      { return @intCast(idx - BUILTIN_COUNT); }

/// Lookup tables for the polymorphic-call case: a `Fn.dyad(Op2)` invoked with
/// a single argument needs to dispatch monadically via the Op1 equivalent.
pub const op2ToOp1: [Op2.COUNT]?Op1 = blk: {
  @setEvalBranchQuota(100000);
  var t: [Op2.COUNT]?Op1 = .{null} ** Op2.COUNT;
  for (std.meta.fields(Op2), 0..) |f, i| t[i] = std.meta.stringToEnum(Op1, f.name);
  break :blk t;
};

pub const op1ToOp2: [Op1.COUNT]?Op2 = blk: {
  @setEvalBranchQuota(100000);
  var t: [Op1.COUNT]?Op2 = .{null} ** Op1.COUNT;
  for (std.meta.fields(Op1), 0..) |f, i| t[i] = std.meta.stringToEnum(Op2, f.name);
  break :blk t;
};

// ─── Fn ──────────────────────────────────────────────────────────────────────
//
// A 64-bit callable reference. Four kinds:
//   .callable      idx is a *global* index (see ranges above).
//                  - idx < BUILTIN_COUNT → builtin verb or adverb
//                  - idx ≥ BUILTIN_COUNT → user-defined lambda
//   .derived       idx = base global idx (callable); extra = adverb (Adverb tag)
//   .derived_data  idx = derived_table index; extra = adverb (Adverb tag)
//                  Used when the adverb's base is data (e.g. radix vec) rather
//                  than a callable, so it can't be expressed as a global idx.
//   .train         arity = len (1-7); ops packed into idx (3 bytes) + extra (4 bytes)

pub const FnKind = enum(u4) {
  callable,
  derived,
  derived_data,
  train,
};

pub const Fn = packed struct(u64) {
  kind:  u4,
  arity: u4,    // cached. For callable: arityOfBuiltin(idx) when builtin, lambda's arity when lambda.
  idx:   u24,   // see FnKind comments
  extra: u32,   // see FnKind comments

  pub fn getKind(self: Fn) FnKind { return @enumFromInt(self.kind); }
  pub fn isCallable(self: Fn) bool { return self.getKind() == .callable; }
  pub fn isLambda(self: Fn) bool { return self.getKind() == .callable and isLambdaIdx(self.idx); }
  pub fn isBuiltinFn(self: Fn) bool { return self.getKind() == .callable and isBuiltinIdx(self.idx); }

  pub fn getOp1(self: Fn) Op1 { return op1OfIdx(self.idx); }
  pub fn getOp2(self: Fn) Op2 { return op2OfIdx(self.idx); }
  pub fn getOp3(self: Fn) Op3 { return op3OfIdx(self.idx); }
  pub fn getOp4(self: Fn) Op4 { return op4OfIdx(self.idx); }
  pub fn getAdverb2(self: Fn) Adverb2 { return adverb2OfIdx(self.idx); }
  pub fn getAdverb3(self: Fn) Adverb3 { return adverb3OfIdx(self.idx); }
  pub fn getLambdaIdx(self: Fn) u24 { return lambdaIdxOf(self.idx); }
  /// For .derived: returns the adverb stored in `extra`.
  pub fn getAdverb(self: Fn) Adverb { return @enumFromInt(@as(u8, @truncate(self.extra))); }

  // ── Constructors ────────────────────────────────────────────────────────────

  pub fn monad(op: Op1) Fn {
    return .{ .kind = @intFromEnum(FnKind.callable), .arity = 1, .idx = @intCast(idxForOp1(op)), .extra = 0 };
  }
  pub fn dyad(op: Op2) Fn {
    return .{ .kind = @intFromEnum(FnKind.callable), .arity = 2, .idx = @intCast(idxForOp2(op)), .extra = 0 };
  }
  pub fn triad(op: Op3) Fn {
    return .{ .kind = @intFromEnum(FnKind.callable), .arity = 3, .idx = @intCast(idxForOp3(op)), .extra = 0 };
  }
  pub fn tetrad(op: Op4) Fn {
    return .{ .kind = @intFromEnum(FnKind.callable), .arity = 4, .idx = @intCast(idxForOp4(op)), .extra = 0 };
  }
  pub fn adverb2(a: Adverb2) Fn {
    return .{ .kind = @intFromEnum(FnKind.callable), .arity = 2, .idx = @intCast(idxForAdverb2(a)), .extra = 0 };
  }
  pub fn adverb3(a: Adverb3) Fn {
    return .{ .kind = @intFromEnum(FnKind.callable), .arity = 3, .idx = @intCast(idxForAdverb3(a)), .extra = 0 };
  }
  /// Standalone adverb as a callable value.
  ///
  /// Polymorphic adverbs (`'`, `/`, `\`, `':`) default to Adverb2 storage
  /// (arity 2). The runtime dispatch upgrades to Adverb3 form when invoked
  /// with 3 arguments. `/:` and `\:` are 2-arg-only at the AST level (they
  /// always need a seed/lhs) so they must go in Adverb3.
  pub fn adverb(adv: Adverb) Fn {
    if (Adverb2.fromAdverb(adv)) |a2| {
      return .{ .kind = @intFromEnum(FnKind.callable), .arity = 2, .idx = @intCast(idxForAdverb2(a2)), .extra = 0 };
    }
    const a3 = Adverb3.fromAdverb(adv);
    return .{ .kind = @intFromEnum(FnKind.callable), .arity = 3, .idx = @intCast(idxForAdverb3(a3)), .extra = 0 };
  }

  pub fn lambda(lambda_idx: u24, fn_arity: u8) Fn {
    return .{ .kind = @intFromEnum(FnKind.callable), .arity = @intCast(fn_arity), .idx = @intCast(idxForLambda(lambda_idx)), .extra = 0 };
  }

  pub fn makeDerived(base_global_idx: u32, base_arity: u8, adv: Adverb) Fn {
    return .{
      .kind = @intFromEnum(FnKind.derived),
      .arity = @intCast(base_arity),
      .idx = @intCast(base_global_idx),
      .extra = @intFromEnum(adv),
    };
  }

  pub fn makeDerivedTable(tbl_idx: u24, adv: Adverb) Fn {
    return .{
      .kind = @intFromEnum(FnKind.derived_data),
      .arity = 1,
      .idx = tbl_idx,
      .extra = @intFromEnum(adv),
    };
  }

  pub fn makeTrain(ops: []const u8) Fn {
    var r = Fn{ .kind = @intFromEnum(FnKind.train), .arity = @intCast(ops.len), .idx = 0, .extra = 0 };
    for (ops, 0..) |op, i| {
      if (i < 3) r.idx |= @as(u24, op) << @intCast(i * 8)
      else r.extra |= @as(u32, op) << @intCast((i - 3) * 8);
    }
    return r;
  }
  pub fn trainOps(self: Fn, buf: *[7]u8) []u8 {
    const len = self.arity;
    for (0..len) |i| {
      if (i < 3) buf[i] = @truncate(self.idx >> @intCast(i * 8))
      else buf[i] = @truncate(self.extra >> @intCast((i - 3) * 8));
    }
    return buf[0..len];
  }

  pub fn getRealArity(self: Fn) u8 {
    return if (self.getKind() == .train) 1 else self.arity;
  }
};

test "FnRef size" { try std.testing.expect(@sizeOf(Fn) == 8); }

test "Fn unified callable kinds" {
  const r1 = Fn.dyad(.@"+");
  try std.testing.expect(r1.getKind() == .callable);
  try std.testing.expect(r1.getOp2() == .@"+");
  try std.testing.expect(r1.arity == 2);
  try std.testing.expect(isOp2Idx(r1.idx));

  const r2 = Fn.monad(.@"*");
  try std.testing.expect(r2.getKind() == .callable);
  try std.testing.expect(r2.arity == 1);
  try std.testing.expect(isOp1Idx(r2.idx));
  try std.testing.expect(r2.getOp1() == .@"*");

  const r3 = Fn.adverb2(.@"/");
  try std.testing.expect(r3.getKind() == .callable);
  try std.testing.expect(isAdverb2Idx(r3.idx));
  try std.testing.expect(r3.getAdverb2() == .@"/");

  const r4 = Fn.triad(.amend3);
  try std.testing.expect(isOp3Idx(r4.idx));
  try std.testing.expect(r4.getOp3() == .amend3);

  const r5 = Fn.makeDerived(idxForOp2(.@"+"), 2, .@"/");
  try std.testing.expect(r5.getKind() == .derived);
  try std.testing.expect(r5.idx == idxForOp2(.@"+"));
  try std.testing.expect(r5.getAdverb() == .@"/");
}

test "global builtin index arities" {
  try std.testing.expect(arityOfBuiltin(idxForOp1(.sqrt)) == 1);
  try std.testing.expect(arityOfBuiltin(idxForOp2(.in)) == 2);
  try std.testing.expect(arityOfBuiltin(idxForAdverb2(.@"/")) == 2);
  try std.testing.expect(arityOfBuiltin(idxForOp3(.amend3)) == 3);
  try std.testing.expect(arityOfBuiltin(idxForAdverb3(.@"/:")) == 3);
  try std.testing.expect(arityOfBuiltin(idxForOp4(.amend4)) == 4);
}

test "op2ToOp1 polymorphic lookup" {
  try std.testing.expect(op2ToOp1[@intFromEnum(Op2.@"+")] == .@"+");
  try std.testing.expect(op2ToOp1[@intFromEnum(Op2.in)] == null);
  try std.testing.expect(op1ToOp2[@intFromEnum(Op1.sqrt)] == null);
  try std.testing.expect(op1ToOp2[@intFromEnum(Op1.@"+")] == .@"+");
}
