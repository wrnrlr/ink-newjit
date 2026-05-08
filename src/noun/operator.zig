const std = @import("std");
const Alloc = std.mem.Allocator;
const Chunk = @import("../runtime/tape.zig").Chunk;
const Op = @import("../runtime/tape.zig").Op;
const K = @import("class.zig").K;
const util = @import("../util.zig");
const activeTag = std.meta.activeTag;
pub const ExtObj = @import("../runtime/plugin.zig").ExtObj;
pub const ExtVTable = @import("../runtime/plugin.zig").ExtVTable;
pub const ExtRegistry = @import("../runtime/plugin.zig").ExtRegistry;

pub const Adverb = enum(u8) {
  @"'", @"/", @"\\", @"':", @"/:", @"\\:"
};

pub const FnKind = enum(u4) {
  builtin,         // idx = @intFromEnum(Op); monad=1 → forced monadic
  lambda,          // idx = FnTables.lambdas index
  adverb,          // idx = @intFromEnum(Adverb)
  derived_builtin, // idx = @intFromEnum(base Op); extra low u8 = @intFromEnum(Adverb)
  derived_lambda,  // idx = lambda_table index for base; extra low u8 = @intFromEnum(Adverb)
  derived_table,   // idx = FnTables.derived index (complex/recursive base)
  train,           // arity = len (1-7); ops packed into idx (3 bytes) + extra (4 bytes)
};

pub const Fn = packed struct(u64) {
  kind:  u4,   // FnKind backing int
  monad: u1,   // for builtin: 1 = forced monadic
  arity: u3,   // 0-7; for train: number of ops (= 1 arg but stored here)
  idx:   u24,  // per-kind index or inline data
  extra: u32,  // per-kind inline data

  pub fn getKind(self: Fn) FnKind { return @enumFromInt(self.kind); }
  pub fn getOp(self: Fn) Op { return @enumFromInt(@as(u8, @truncate(self.idx))); }
  pub fn getAdverb(self: Fn) Adverb { return @enumFromInt(@as(u8, @truncate(self.extra))); }

  pub fn makeBuiltin(op: Op) Fn {
    return .{ .kind = @intFromEnum(FnKind.builtin), .monad = 0, .arity = 2, .idx = @intFromEnum(op), .extra = 0 };
  }
  pub fn makeBuiltinMonad(op: Op) Fn {
    return .{ .kind = @intFromEnum(FnKind.builtin), .monad = 1, .arity = 1, .idx = @intFromEnum(op), .extra = 0 };
  }
  pub fn makeAdverb(adv: Adverb) Fn {
    return .{ .kind = @intFromEnum(FnKind.adverb), .monad = 0, .arity = 1, .idx = @intFromEnum(adv), .extra = 0 };
  }
  pub fn makeDerivedBuiltin(op: Op, adv: Adverb) Fn {
    return .{ .kind = @intFromEnum(FnKind.derived_builtin), .monad = 0, .arity = 1, .idx = @intFromEnum(op), .extra = @intFromEnum(adv) };
  }
  pub fn makeDerivedLambda(lambda_idx: u24, adv: Adverb) Fn {
    return .{ .kind = @intFromEnum(FnKind.derived_lambda), .monad = 0, .arity = 1, .idx = lambda_idx, .extra = @intFromEnum(adv) };
  }
  pub fn makeDerivedTable(tbl_idx: u24) Fn {
    return .{ .kind = @intFromEnum(FnKind.derived_table), .monad = 0, .arity = 1, .idx = tbl_idx, .extra = 0 };
  }
  pub fn makeLambda(lambda_idx: u24, fn_arity: u8) Fn {
    return .{ .kind = @intFromEnum(FnKind.lambda), .monad = 0, .arity = @intCast(fn_arity), .idx = lambda_idx, .extra = 0 };
  }
  pub fn makeTrain(ops: []const u8) Fn {
    var r = Fn{ .kind = @intFromEnum(FnKind.train), .monad = 0, .arity = @intCast(ops.len), .idx = 0, .extra = 0 };
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

// TODO Experimantal op redesign
pub const Op2 = enum(u8) {
  // Monadic veresion of op
  @"%:", @"!:", @"&:", @"+:", @"*:", @"|:", @"<:", @">:", @"=:", @"~:",
  @",:", @"^:", @"#:", @"_:", @"$:", @"?:", @"@:", @"-:", @".:",
  @"0::", @"1::", @"2::", @"9::", // read ops
  sqrt, sqr, exp, log, sin, cos, abs, first, last, count,

  // Dyadic veresion of op
  @"%", @"!", @"&", @"+", @"*", @"|", @"<", @">", @"=", @"~",
  @",", @"^", @"#", @"_", @"$", @"?", @"@", @"-", @".",
  @"0:", @"1:", @"2:", @"9:", // write ops
  in, has,
  @":", // Needed here?
  
  amend3, amend4,
  drill3, drill4,
  splice,
  
  // adverbs
  @"'", @"/", @"\\", @"':", @"/:", @"\\:",
  
  pub const COUNT = @typeInfo(Op2).@"enum".fields.len;
  pub inline fn code(op: Op2) usize { return @intFromEnum(op); }
};


test "FnRef size" { try std.testing.expect(@sizeOf(Fn) == 8); }
