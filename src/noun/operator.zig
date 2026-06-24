const std = @import("std");
const Alloc = std.mem.Allocator;
const Chunk = @import("../runtime/tape.zig").Chunk;
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

/// Monadic primitives. Apply1 bytecode + monad dispatch table.
pub const Op1 = enum(u8) {
  // symbol/glyph verbs
  @"%", @"!", @"&", @"+", @"*", @"|", @"<", @">", @"=", @"~",
  @",", @"^", @"#", @"_", @"$", @"?", @"@", @"-", @".", @":",
  // math keywords
  sqrt, sqr, exp, log, sin, cos, abs,
  // selection keywords
  first, last, count, parse,
  // io verbs (monadic forms)
  @"0:", @"1:", @"2:", @"9:",
  exec,
  // fused monad-only derived verbs (sum, product, min, max)
  @"+/", @"*/", @"|/", @"&/",
  // internal verb emitted by the peephole for the idiom `#'=` (tally-each group)
  freq,

  pub const COUNT = @typeInfo(Op1).@"enum".fields.len;

  pub fn fromString(s: []const u8) ?Op1 { return std.meta.stringToEnum(Op1, s); }
  pub fn toString(self: Op1) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op1) usize { return @intFromEnum(op); }
  pub inline fn load(a: u8) usize { return @enumFromInt(a); }
};

/// Dyadic primitives. Apply2 bytecode + dyad dispatch table.
pub const Op2 = enum(u8) {
  @"+", @"-", @"*", @"%", // arith
  @"=", @"|", @"&", // logic
  @"<", @">", // grade
  @"~",
  @"!",
  @",", @"^", @"#", @"_", @"$", @"?", @"@", @".",
  in, has,
  mod, div,
  @"0:", @"1:", @"2:", @"9:",
  @":",
  exec,

  pub const COUNT = @typeInfo(Op2).@"enum".fields.len;
  pub const arith = [_]Op2{.@"+", .@"-", .@"*", .@"%"};
  pub const logic = [_]Op2{.@"=", .@"|", .@"&"};
  pub fn fromString(s: []const u8) ?Op2 { return std.meta.stringToEnum(Op2, s); }
  pub fn toString(self: Op2) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op2) usize { return @intFromEnum(op); }
  pub inline fn isQuick(comptime op: Op2) bool { return @intFromEnum(op) < @intFromEnum(Op2.@"&"); }
};

/// Triadic primitives. Apply3 bytecode (amend3/drill3).
pub const Op3 = enum(u8) {
  amend3, drill3, splice3,
  pub const COUNT = @typeInfo(Op3).@"enum".fields.len;
  pub fn toString(self: Op3) []const u8 { return @tagName(self); }
};

/// Tetradic primitives. Apply4 bytecode (amend4/drill4).
pub const Op4 = enum(u8) {
  amend4, drill4,
  pub const COUNT = @typeInfo(Op4).@"enum".fields.len;
  pub fn toString(self: Op4) []const u8 { return @tagName(self); }
};

// ─── Unified global builtin index space ───────────────────────────────────────
//
// Every builtin callable — verb (Op1..Op4) or adverb — gets a single global
// index. The category is determined purely from the idx range:
//
//   [0,            OP1_END)      Op1     monadic verb
//   [OP1_END,      OP2_END)      Op2     dyadic verb
//   [OP2_END,      ADVERB_END)   Adverb  adverb (polymorphic 2-or-3-arity)
//   [ADVERB_END,   OP3_END)      Op3     triadic verb (amend3/drill3)
//   [OP3_END,      OP4_END)      Op4     tetradic verb (amend4/drill4)
//   [BUILTIN_COUNT, ...)         lambda (idx - BUILTIN_COUNT = lambda_table idx)

pub const OP1_END:       u32 = Op1.COUNT;
pub const OP2_END:       u32 = OP1_END + Op2.COUNT;
pub const ADVERB_END:    u32 = OP2_END + Adverb.COUNT;
pub const OP3_END:       u32 = ADVERB_END + Op3.COUNT;
pub const OP4_END:       u32 = OP3_END + Op4.COUNT;
pub const BUILTIN_COUNT: u32 = OP4_END;

pub inline fn isBuiltinIdx(idx: u32) bool { return idx < BUILTIN_COUNT; }
pub inline fn isLambdaIdx(idx: u32)  bool { return idx >= BUILTIN_COUNT; }
pub inline fn isOp1Idx(idx: u32)     bool { return idx < OP1_END; }
pub inline fn isOp2Idx(idx: u32)     bool { return idx >= OP1_END    and idx < OP2_END; }
pub inline fn isAdverbIdx(idx: u32)  bool { return idx >= OP2_END    and idx < ADVERB_END; }
pub inline fn isOp3Idx(idx: u32)     bool { return idx >= ADVERB_END and idx < OP3_END; }
pub inline fn isOp4Idx(idx: u32)     bool { return idx >= OP3_END    and idx < OP4_END; }

pub inline fn idxForOp1(op: Op1) u32     { return @intFromEnum(op); }
pub inline fn idxForOp2(op: Op2) u32     { return OP1_END + @intFromEnum(op); }
pub inline fn idxForAdverb(a: Adverb) u32 { return OP2_END + @intFromEnum(a); }
pub inline fn idxForOp3(op: Op3) u32     { return ADVERB_END + @intFromEnum(op); }
pub inline fn idxForOp4(op: Op4) u32     { return OP3_END + @intFromEnum(op); }
pub inline fn idxForLambda(li: u24) u32  { return BUILTIN_COUNT + li; }

pub fn arityOfBuiltin(idx: u32) u8 {
  if (idx < OP1_END)    return 1;
  if (idx < ADVERB_END) return 2;
  if (idx < OP3_END)    return 3;
  return 4;
}

pub inline fn op1OfIdx(idx: u32) Op1      { return @enumFromInt(@as(u8, @intCast(idx))); }
pub inline fn op2OfIdx(idx: u32) Op2      { return @enumFromInt(@as(u8, @intCast(idx - OP1_END))); }
pub inline fn adverbOfIdx(idx: u32) Adverb { return @enumFromInt(@as(u8, @intCast(idx - OP2_END))); }
pub inline fn op3OfIdx(idx: u32) Op3      { return @enumFromInt(@as(u8, @intCast(idx - ADVERB_END))); }
pub inline fn op4OfIdx(idx: u32) Op4      { return @enumFromInt(@as(u8, @intCast(idx - OP3_END))); }
pub inline fn lambdaIdxOf(idx: u32) u24   { return @intCast(idx - BUILTIN_COUNT); }

/// Polymorphic-call lookup: a `Fn.dyad(Op2)` invoked with one argument needs
/// to dispatch monadically via the Op1 equivalent if one exists.
pub const op2ToOp1: [Op2.COUNT]?Op1 = blk: {
  @setEvalBranchQuota(100000);
  var t: [Op2.COUNT]?Op1 = .{null} ** Op2.COUNT;
  for (std.meta.fields(Op2), 0..) |f, i| t[i] = std.meta.stringToEnum(Op1, f.name);
  break :blk t;
};

// ─── Fn ──────────────────────────────────────────────────────────────────────
//
// A 64-bit callable reference.
//
//   .callable      idx is a global index (range tells you what):
//                   - < BUILTIN_COUNT → builtin verb/adverb
//                   - ≥ BUILTIN_COUNT → user-defined lambda
//   .derived       idx = base global idx; extra low byte = Adverb tag
//   .derived_data  idx = derived_table index; extra low byte = Adverb tag
//                  Used when the base is data (e.g. radix vec for I/) and
//                  can't be expressed as a global function idx.
//   .train         arity = number of ops; ops packed into idx + extra

pub const FnKind = enum(u4) { callable, derived, derived_data, train };

pub const Fn = packed struct(u64) {
  kind:  FnKind,
  arity: u4,    // cached; for builtins also derivable from arityOfIdx(idx)
  idx:   u24,
  extra: u32,

  pub fn isCallable(self: Fn) bool { return self.kind == .callable; }
  pub fn isLambda(self: Fn) bool { return self.kind == .callable and isLambdaIdx(self.idx); }
  pub fn isBuiltinFn(self: Fn) bool { return self.kind == .callable and isBuiltinIdx(self.idx); }
  pub fn isOp1(self: Fn) bool { return self.kind == .callable and isOp1Idx(self.idx); }
  pub fn isOp2(self: Fn) bool { return self.kind == .callable and isOp2Idx(self.idx); }

  pub fn getOp1(self: Fn) Op1       { return op1OfIdx(self.idx); }
  pub fn getOp2(self: Fn) Op2       { return op2OfIdx(self.idx); }
  pub fn getOp3(self: Fn) Op3       { return op3OfIdx(self.idx); }
  pub fn getOp4(self: Fn) Op4       { return op4OfIdx(self.idx); }
  pub fn getAdverbOfIdx(self: Fn) Adverb { return adverbOfIdx(self.idx); }
  /// For .derived: the adverb stored in `extra`.
  pub fn getAdverb(self: Fn) Adverb { return @enumFromInt(@as(u8, @truncate(self.extra))); }
  pub fn getLambdaIdx(self: Fn) u24 { return lambdaIdxOf(self.idx); }

  // ── Constructors ────────────────────────────────────────────────────────────

  fn callable(idx: u32, fn_arity: u8) Fn {
    return .{ .kind = .callable, .arity = @intCast(fn_arity), .idx = @intCast(idx), .extra = 0 };
  }
  pub fn monad(op: Op1)  Fn { return callable(idxForOp1(op), 1); }
  pub fn dyad(op: Op2)   Fn { return callable(idxForOp2(op), 2); }
  pub fn triad(op: Op3)  Fn { return callable(idxForOp3(op), 3); }
  pub fn tetrad(op: Op4) Fn { return callable(idxForOp4(op), 4); }
  /// Standalone adverb. Arity is 3 for digram-only adverbs (`/:`, `\:`),
  /// otherwise 2. The dispatch handles polymorphism (calling a 2-arity adverb
  /// with 3 args upgrades to digram form).
  pub fn adverb(adv: Adverb) Fn {
    const ar: u8 = if (adv == .@"/:" or adv == .@"\\:") 3 else 2;
    return callable(idxForAdverb(adv), ar);
  }
  pub fn lambda(lambda_idx: u24, fn_arity: u8) Fn {
    return callable(idxForLambda(lambda_idx), fn_arity);
  }

  pub fn makeDerived(base_global_idx: u32, base_arity: u8, adv: Adverb) Fn {
    return .{
      .kind = .derived,
      .arity = @intCast(base_arity),
      .idx = @intCast(base_global_idx),
      .extra = @intFromEnum(adv),
    };
  }
  pub fn makeDerivedTable(tbl_idx: u24, adv: Adverb) Fn {
    return .{
      .kind = .derived_data,
      .arity = 1,
      .idx = tbl_idx,
      .extra = @intFromEnum(adv),
    };
  }

  pub fn makeTrain(ops: []const u8) Fn {
    var r = Fn{ .kind = .train, .arity = @intCast(ops.len), .idx = 0, .extra = 0 };
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
    return if (self.kind == .train) 1 else self.arity;
  }
};

test "Fn size and shapes" {
  try std.testing.expect(@sizeOf(Fn) == 8);
  const r1 = Fn.dyad(.@"+");
  try std.testing.expect(r1.kind == .callable and isOp2Idx(r1.idx));
  try std.testing.expect(r1.getOp2() == .@"+");
  const r2 = Fn.monad(.@"*");
  try std.testing.expect(isOp1Idx(r2.idx) and r2.getOp1() == .@"*");
  const r3 = Fn.adverb(.@"/");
  try std.testing.expect(isAdverbIdx(r3.idx) and r3.getAdverbOfIdx() == .@"/" and r3.arity == 2);
  const r3b = Fn.adverb(.@"/:");
  try std.testing.expect(isAdverbIdx(r3b.idx) and r3b.arity == 3);
  const r4 = Fn.triad(.amend3);
  try std.testing.expect(isOp3Idx(r4.idx) and r4.getOp3() == .amend3);
  const r5 = Fn.makeDerived(idxForOp2(.@"+"), 2, .@"/");
  try std.testing.expect(r5.kind == .derived);
  try std.testing.expect(r5.getAdverb() == .@"/");
  try std.testing.expect(op2ToOp1[@intFromEnum(Op2.@"+")] == .@"+");
  try std.testing.expect(op2ToOp1[@intFromEnum(Op2.in)] == null);
}
