const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

const selection = @import("first.zig");
const logic = @import("logic.zig");
const pair = @import("pair.zig");
const io = @import("io.zig");
const concat = @import("concat.zig");
const calc = @import("calc.zig");
const sort = @import("sort.zig");
const member = @import("member.zig");

// Dispatch tables: monad keyed by Op1, dyad keyed by Op2.
pub const monad_table = makeMonadArray(Monads);
pub const dyad_table  = makeDyadArray(Dyads);

const h = @import("helper.zig");
const at = h.arithmetic_types;

// Monad helpers (op: Op1)
pub fn _B(comptime op: Op1, comptime F: type) type { return h.makeMonad(op, h.Upcast1, h.Bool1,   F, &at); }
pub fn _N(comptime op: Op1, comptime F: type) type { return h.makeMonad(op, h.Upcast1, h.Upcast1, F, &at); }
pub fn _F(comptime op: Op1, comptime F: type) type { return h.makeMonad(op, h.Float1,  h.Float1,  F, &at); }
pub fn _Yf(comptime op: Op1, comptime F: type) type { return h.makeMonad(op, h.Float1, h.Int1,   F, &at); }
pub fn _X1(comptime op: Op1, comptime Impl: type) type { return h._X(Op1, op, Impl); }

// Dyad helpers (op: Op2)
pub fn _B_B(comptime op: Op2, comptime f: type) type { return h.makeDyad(op, h.Bool2, h.Bool2, f, &.{.b, .B}); }
pub fn _N_N(comptime op: Op2, comptime f: type) type { return h.makeDyad(op, h.Upcast2, h.Upcast2, f, &at); }
pub fn _I_I(comptime op: Op2, comptime f: type) type { return h.makeDyad(op, h.Int2, h.Int2, f, &h.integer_types); }
pub fn _F_F(comptime op: Op2, comptime f: type) type { return h.makeDyad(op, h.Float2,  h.Float2,  f, &at); }
pub fn _X2(comptime op: Op2, comptime f: type) type { return h._X(Op2, op, f); }

pub fn _Cmp(comptime op: Op2, comptime f: type) type { return h.makeDyad(op, h.Upcast2, h.Bool2, f, &at); }



const Monads = struct {
  // Monadic Primitives
  pub const @"+x" = @import("flip.zig").Flip;
  pub const @"-N" = _N(.@"-", calc.NegOp);
  pub const @"*x" = selection.First;
  pub const @"first_x" = selection.First_Name;
  pub const @"last_x"  = selection.Last_Name;
  pub const @"!i" = @import("iota.zig").Iota;
  pub const @"!I" = @import("odometer.zig").Odometer;
  pub const @"!d" = @import("keys.zig").Keys;
  pub const @"&x" = @import("where.zig").Where;
  pub const @"|x" = @import("reverse.zig").Reverse;
  pub const @"<s" =  @import("open.zig").Open;
  pub const @"<X" = sort.Ascend;
  pub const @">X" = sort.Descend;
  pub const @"=X" = @import("group.zig").Group;
  pub const @"=i" = _X1(.@"?", @import("uniform.zig").UniformOp);
  pub const @"~x" = _B(.@"~", logic.NotOp);
  pub const @",x" = @import("enlist.zig").Enlist;
  pub const @"^x" = @import("nulls.zig").Nulls;
  pub const @"#x" = @import("tally.zig").Tally;
  pub const @"_c" = @import("lowercase.zig").Lowercase;
  pub const @"_n" = h.makeMonad(.@"_", h.Float1, h.Int1, @import("floor.zig").FloorOp, &.{.f, .F});
  // pub const @"9:x"   = @import("graphics.zig").Draw;
  pub const @"sqrt"  = _F(.sqrt, calc.SqrtOp);
  pub const @"sqr"   = _N(.sqr,  calc.SqrOp);
  pub const @"exp"   = _F(.exp,  calc.ExpOp);
  pub const @"log"   = _F(.log,  calc.LogOp);
  pub const @"sin"   = _F(.sin,  calc.SinOp);
  pub const @"cos"   = _F(.cos,  calc.CosOp);
  pub const @"abs"   = _N(.abs,  calc.AbsOp);
  pub const @"$x"    = @import("format.zig").Format;
  pub const @"parse" = @import("parse.zig").Parse;
  pub const @"@x"    = @import("type.zig").Type;
  pub const @":x"    = @import("right.zig").Identity;

  pub const @"=u"  = @import("unitary.zig").Unitary;
  pub const @"?X"  = @import("distinct.zig").Distinct;
  pub const @"0:x" = io.ReadLines;
  pub const @"1:x" = io.ReadBytes;
  pub const @"2:x" = io.ReadData;
  pub const @".m"  = @import("values.zig").Values;
  pub const @".s"  = @import("get.zig").GetSymbol;
  pub const exec   = @import("exec.zig").Exec;

  // Fused derived verbs — direct monadic reductions over typed arrays.
  // The optimizer rewrites `+/x` (Call+Derive) into `Apply1 +/` to hit these.
  pub const @"sum x"     = @import("../derived/sum.zig").Sum;
  pub const @"product x" = @import("../derived/product.zig").Product;
  pub const @"min x"     = @import("../derived/min.zig").Min;
  pub const @"max x"     = @import("../derived/max.zig").Max;
};

const Dyads = struct {
  // Dyadic Primitives
  // pub const @"i+i" = _i_i(.@"+", fn f(x: anytype, y: anytype) i32 { return x +% y; });
  pub const @"N+N" = _N_N(.@"+", calc.AddOp);
  pub const @"N-N" = _N_N(.@"-", calc.SubOp);
  pub const @"N*N" = _N_N(.@"*", calc.MulOp);
  pub const @"N%N" = _F_F(.@"%", calc.DivOp);
  pub const @"N&N" = _N_N(.@"&", calc.MinOp);
  pub const @"N|N" = _N_N(.@"|", calc.MaxOp);
  pub const @"B&B" = _B_B(.@"&", calc.AndOp);
  pub const @"B|B" = _B_B(.@"|", calc.OrOp);
  pub const @"x!y" = pair.Pair;
  pub const @"X=X" = _Cmp(.@"=", logic.EqualOp);
  pub const @"X<X" = _Cmp(.@"<", logic.LessOp);
  pub const @"X>X" = _Cmp(.@">", logic.MoreOp);
  pub const @"X~X" = @import("match.zig").Match;
  pub const @"I⌊I"  = _I_I(.mod, calc.ModOp);
  pub const @"I÷I"  = _I_I(.div, calc.DiviOp);
  pub const @"x,y"  = concat.Concat;
  pub const @"i_X"  = @import("drop.zig").Drop;
  pub const @"I_X"  = _X2(.@"_", @import("cut.zig").Cut);
  pub const @"B_X"  = @import("weedout.zig").WeedOut;
  pub const @"X_i"  = @import("delete.zig").Delete;
  // pub const @"i_m"  = @import("drop_keys.zig").DropKeys;
  // pub const @"I_m"  = @import("drop_keys.zig").DropKeys;
  pub const @"x_m"  = @import("drop_keys.zig").DropKeys;
  pub const @"m,m"  = @import("merge.zig").DictMerge;
  pub const @"x#m"  = @import("select.zig").SelectKeys;
  pub const @"M,m"  = @import("insert.zig").Insert;
  // pub const @"M,m" = @import("insert.zig").Upsert;
  // pub const @"m|m"  = @import("join.zig").UnionJoin;
  // pub const @"m,m" = @import("join.zig").LeftJoin;
  // pub const @"m^m"  = dict.OuterJoin;
  pub const @"i#X"  = @import("take.zig").Take;
  pub const @"I#X"  = @import("reshape.zig").Reshape;
  pub const @"x^X"  = @import("fill.zig").Fill;
  pub const @"X^X"  = @import("without.zig").Without;
  pub const @"i$C"  = @import("pad.zig").Pad;
  pub const @"s$x"  = @import("cast.zig").Cast;
  pub const @"X?x"  = @import("find.zig").Find;
  pub const @"i?X"  = @import("random.zig").Random;
  pub const @"f@y"  = @import("apply1.zig").Apply;
  pub const @"m@X"  = @import("select.zig").SelectDict;
  pub const @"M@X"  = @import("select.zig").SelectTable;
  pub const @"x@y"  = @import("apply.zig").Apply;
  pub const @"X@X"  = @import("pick.zig").Pick;
  pub const @"s?x"  = @import("marshal.zig").Marshal;
  pub const @"s@x"  = @import("marshal.zig").Unmarshal;
  // pub const @"x.y" = @import("apply.zig").ApplyN; // TODO: pick.pick reference broken
  pub const @"x has y"  = member.Has;
  pub const @"x in y"   = member.In;
  pub const @"x 0: x" = io.WriteLines;
  pub const @"x 1: x" = io.WriteBytes;
  pub const @"x 2: x" = io.WriteData;
  pub const @"x: y"    = @import("right.zig").Right;
  pub const @"9: x"    = @import("graphics.zig").Draw;
  pub const @"x 9: x"  = @import("graphics.zig").DrawDyad;
  pub const @"x exec" = @import("exec.zig").ExecDyad;
};

fn typeError1(_: *VM, _:V) V { return .{ .err = .@"type" }; }
fn typeError2(_: *VM, _:V, _:V) V { return .{ .err = .@"type" }; }

// Read the verb's `op` field — coerces the (possibly anonymous) enum literal
// to EnumT. Compile error if the verb's op isn't a valid EnumT member.
fn opOf(comptime Verb: type, comptime EnumT: type) ?EnumT {
  if (@hasDecl(Verb, "op")) return @as(EnumT, @field(Verb, "op"));
  for (std.meta.fields(Verb)) |f|
    if (comptime std.mem.eql(u8, f.name, "op"))
      return @as(EnumT, f.defaultValue() orelse return null);
  return null;
}

fn makeMonadArray(comptime Defs: type) [Op1.COUNT * K.COUNT]util.MonadFn {
  @setEvalBranchQuota(10000000);
  var table: [Op1.COUNT * K.COUNT]util.MonadFn = .{typeError1} ** (Op1.COUNT * K.COUNT);
  for (std.meta.declarations(Defs)) |decl| {
    const Verb = @field(Defs, decl.name);
    const op1 = opOf(Verb, Op1) orelse continue;
    for (std.meta.fields(Verb)) |f| {
      const sig = parseSig(f.name);
      if (sig.len == 1) {
        const key = @intFromEnum(op1) * K.COUNT + sig[0].code();
        table[key] = f.defaultValue().?;
      }
    }
  }
  return table;
}

fn makeDyadArray(comptime Defs: type) [Op2.COUNT * K.COUNT * K.COUNT]util.DyadFn {
  @setEvalBranchQuota(10000000);
  var table: [Op2.COUNT * K.COUNT * K.COUNT]util.DyadFn = .{typeError2} ** (Op2.COUNT * K.COUNT * K.COUNT);
  for (std.meta.declarations(Defs)) |decl| {
    const Verb = @field(Defs, decl.name);
    const op2 = opOf(Verb, Op2) orelse continue;
    for (std.meta.fields(Verb)) |f| {
      const sig = parseSig(f.name);
      if (sig.len == 2) {
        const key = op2.code() * K.COUNT * K.COUNT + sig[0].code() * K.COUNT + sig[1].code();
        table[key] = f.defaultValue().?;
      }
    }
  }
  return table;
}

// Parse "_i" → [.i], "_i_f" → [.i, .f], "_blank" → [.blank].
// Splits on '_' into segments; each segment must be a K enum tag name or single K char.
// Returns [] if any segment doesn't map to a K tag.
fn parseSig(comptime name: []const u8) []const K {
  if (name.len < 2 or name[0] != '_') return &.{};
  comptime var tags: []const K = &.{};
  comptime var start: usize = 1;
  comptime var i: usize = 1;
  while (i <= name.len) : (i += 1) {
    const at_boundary = (i == name.len or name[i] == '_');
    if (at_boundary and i > start) {
      const seg = name[start..i];
      const k = std.meta.stringToEnum(K, seg) orelse return &.{};
      tags = tags ++ .{k};
      start = i + 1;
    } else if (at_boundary) {
      start = i + 1;
    }
  }
  return tags;
}
