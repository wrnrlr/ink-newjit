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
/// (e.g. `f/x`). `/:` and `\:` (eachright/eachleft) are NOT valid here —
/// they are 2-arg-only.
pub const Adverb2 = enum(u8) {
  @"'", @"/", @"\\", @"':",

  pub const COUNT = @typeInfo(Adverb2).@"enum".fields.len;
  pub fn fromAdverb(adv: Adverb) ?Adverb2 {
    return std.meta.stringToEnum(Adverb2, @tagName(adv));
  }
};

/// Adverb form when the derived verb is called with two data arguments
/// (e.g. `x f/y`, the "digram" form, plus `f/:` eachright / `f\:` eachleft).
/// All six adverbs are valid here.
pub const Adverb3 = enum(u8) {
  @"'", @"/", @"\\", @"':", @"/:", @"\\:",

  pub const COUNT = @typeInfo(Adverb3).@"enum".fields.len;
  pub fn fromAdverb(adv: Adverb) Adverb3 {
    return std.meta.stringToEnum(Adverb3, @tagName(adv)).?;
  }
};

/// Monadic primitives. Each member is the operator name; values are tightly
/// packed (no holes). Used for Apply1 bytecode and the monad dispatch table.
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
  // fused monad-only derived verbs (sum, product, min, max).
  // The optimizer rewrites `+/x` from Call+Derive into `Apply1 +/` and
  // dispatch routes to the dedicated handler in src/primitive/derived/*.zig.
  @"+/", @"*/", @"|/", @"&/",

  pub const COUNT = @typeInfo(Op1).@"enum".fields.len;

  pub fn fromString(s: []const u8) ?Op1 { return std.meta.stringToEnum(Op1, s); }
  pub fn toString(self: Op1) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op1) usize { return @intFromEnum(op); }
  pub fn fromOp(op: Op) ?Op1 { return std.meta.stringToEnum(Op1, @tagName(op)); }
};

/// Triadic primitives. Used for Apply3 bytecode (amend/drill 3-arg forms).
pub const Op3 = enum(u8) {
  amend3, // @[x;i;f] — apply f to x at i (or set if f is `:`)
  drill3, // .[x;p;f] — apply f to x at path p

  pub const COUNT = @typeInfo(Op3).@"enum".fields.len;

  pub fn fromString(s: []const u8) ?Op3 { return std.meta.stringToEnum(Op3, s); }
  pub fn toString(self: Op3) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op3) usize { return @intFromEnum(op); }
};

/// Tetradic primitives. Used for Apply4 bytecode (amend/drill 4-arg forms).
pub const Op4 = enum(u8) {
  amend4, // @[x;i;f;v] — apply f(x at i, v) and store back
  drill4, // .[x;p;f;v] — apply f at path p with extra arg v

  pub const COUNT = @typeInfo(Op4).@"enum".fields.len;

  pub fn fromString(s: []const u8) ?Op4 { return std.meta.stringToEnum(Op4, s); }
  pub fn toString(self: Op4) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op4) usize { return @intFromEnum(op); }
};

/// Dyadic primitives. Used for Apply2 bytecode and the dyad dispatch table.
pub const Op2 = enum(u8) {
  // symbol/glyph verbs
  @"%", @"!", @"&", @"+", @"*", @"|", @"<", @">", @"=", @"~",
  @",", @"^", @"#", @"_", @"$", @"?", @"@", @"-", @".",
  // set keywords
  in, has,
  // arithmetic keywords
  mod, div,
  // io verbs (dyadic forms)
  @"0:", @"1:", @"2:", @"9:",
  // identity assignment marker (sentinel used by amend/drill)
  @":",
  exec,

  pub const COUNT = @typeInfo(Op2).@"enum".fields.len;

  pub fn fromString(s: []const u8) ?Op2 { return std.meta.stringToEnum(Op2, s); }
  pub fn toString(self: Op2) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op2) usize { return @intFromEnum(op); }
  pub fn fromOp(op: Op) ?Op2 { return std.meta.stringToEnum(Op2, @tagName(op)); }
};

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

pub const FnKind = enum(u4) {
  builtin,         // arity field discriminates: 1 → idx is Op1, 2 → idx is Op2
  lambda,          // idx = FnTables.lambdas index, arity = lambda's arity
  adverb,          // idx = @intFromEnum(Adverb)
  derived_builtin, // arity field discriminates base: 1 → Op1, 2 → Op2; extra low u8 = Adverb
  derived_lambda,  // idx = lambda_table index; extra low u8 = Adverb
  derived_table,   // idx = FnTables.derived index (complex/recursive base)
  train,           // arity = len (1-7); ops packed into idx (3 bytes) + extra (4 bytes)
};

pub const Fn = packed struct(u64) {
  kind:  u4,   // FnKind backing int
  arity: u4,   // 0-15 (0-7 used in practice); for builtin/derived_builtin: 1 = Op1, 2 = Op2
  idx:   u24,  // per-kind index or inline data
  extra: u32,  // per-kind inline data

  pub fn getKind(self: Fn) FnKind { return @enumFromInt(self.kind); }
  pub fn getOp1(self: Fn) Op1 { return @enumFromInt(@as(u8, @truncate(self.idx))); }
  pub fn getOp2(self: Fn) Op2 { return @enumFromInt(@as(u8, @truncate(self.idx))); }
  pub fn getAdverb(self: Fn) Adverb { return @enumFromInt(@as(u8, @truncate(self.extra))); }

  pub fn dyad(op: Op2) Fn {
    return .{ .kind = @intFromEnum(FnKind.builtin), .arity = 2, .idx = @intFromEnum(op), .extra = 0 };
  }
  pub fn monad(op: Op1) Fn {
    return .{ .kind = @intFromEnum(FnKind.builtin), .arity = 1, .idx = @intFromEnum(op), .extra = 0 };
  }
  pub fn adverb(adv: Adverb) Fn {
    return .{ .kind = @intFromEnum(FnKind.adverb), .arity = 1, .idx = @intFromEnum(adv), .extra = 0 };
  }
  pub fn makeDerivedMonad(op: Op1, adv: Adverb) Fn {
    return .{ .kind = @intFromEnum(FnKind.derived_builtin), .arity = 1, .idx = @intFromEnum(op), .extra = @intFromEnum(adv) };
  }
  pub fn makeDerivedDyad(op: Op2, adv: Adverb) Fn {
    return .{ .kind = @intFromEnum(FnKind.derived_builtin), .arity = 2, .idx = @intFromEnum(op), .extra = @intFromEnum(adv) };
  }
  pub fn makeDerivedLambda(lambda_idx: u24, adv: Adverb) Fn {
    return .{ .kind = @intFromEnum(FnKind.derived_lambda), .arity = 1, .idx = lambda_idx, .extra = @intFromEnum(adv) };
  }
  pub fn makeDerivedTable(tbl_idx: u24) Fn {
    return .{ .kind = @intFromEnum(FnKind.derived_table), .arity = 1, .idx = tbl_idx, .extra = 0 };
  }
  pub fn lambda(lambda_idx: u24, fn_arity: u8) Fn {
    return .{ .kind = @intFromEnum(FnKind.lambda), .arity = @intCast(fn_arity), .idx = lambda_idx, .extra = 0 };
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

test "FnRef inline kinds" {
  const r1 = Fn.dyad(.@"+");
  try std.testing.expect(r1.getKind() == .builtin);
  try std.testing.expect(r1.getOp2() == .@"+");
  try std.testing.expect(r1.arity == 2);

  const r2 = Fn.monad(.@"*");
  try std.testing.expect(r2.getKind() == .builtin);
  try std.testing.expect(r2.arity == 1);
  try std.testing.expect(r2.getRealArity() == 1);

  const r3 = Fn.makeDerivedDyad(.@"+", .@"/");
  try std.testing.expect(r3.getKind() == .derived_builtin);
  try std.testing.expect(r3.arity == 2);
  try std.testing.expect(r3.getOp2() == .@"+");
  try std.testing.expect(r3.getAdverb() == .@"/");
}

test "op2ToOp1 polymorphic lookup" {
  try std.testing.expect(op2ToOp1[@intFromEnum(Op2.@"+")] == .@"+");
  try std.testing.expect(op2ToOp1[@intFromEnum(Op2.in)] == null);
  try std.testing.expect(op1ToOp2[@intFromEnum(Op1.sqrt)] == null);
  try std.testing.expect(op1ToOp2[@intFromEnum(Op1.@"+")] == .@"+");
}
