const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const Op = @import("../../runtime/tape.zig").Op;
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const dispatch_mod = @import("../dispatch.zig");

const selection = @import("first.zig");
const logic = @import("logic.zig");
const pair = @import("pair.zig");
const io = @import("io.zig");
const concat = @import("concat.zig");
const calc = @import("calc.zig");
const sort = @import("sort.zig");
const member = @import("member.zig");

const V = value.V;
const N = value.N;

// TODO: tables can be smaller if we split monads and dyads into their own Op enum
pub const monad_table = makeMonadArray(Monads);
pub const dyad_table  = makeDyadArray(Dyads);

const h = @import("helper.zig");
const at = h.arithmetic_types;

pub fn _B(comptime op: Op, comptime F: type) type { return h.makeMonad(op, h.Upcast1, h.Bool1,   F, &at); }
pub fn _N(comptime op: Op, comptime F: type) type { return h.makeMonad(op, h.Upcast1, h.Upcast1, F, &at); }
pub fn _F(comptime op: Op, comptime F: type) type { return h.makeMonad(op, h.Float1,  h.Float1,  F, &at); }
pub fn _B_B(comptime op: Op, comptime f: type) type { return h.makeDyad(op, h.Bool2,   h.Bool2,   f, &at); }
pub fn _N_N(comptime op: Op, comptime f: type) type { return h.makeDyad(op, h.Upcast2, h.Upcast2, f, &at); }
pub fn _I_I(comptime op: Op, comptime f: type) type { return h.makeDyad(op, h.Int2, h.Int2, f, &h.integer_types); }
pub fn _F_F(comptime op: Op, comptime f: type) type { return h.makeDyad(op, h.Float2,  h.Float2,  f, &at); }
pub fn _X(comptime op: Op, comptime Impl: type) type { return h._X(op, Impl); }
pub fn _I_A(comptime op: Op, comptime Impl: type) type { return h._X(op, Impl); }

const Monads = struct {
  // Monadic Primitives
  pub const @"+x" = @import("flip.zig").Flip;
  pub const @"-N" = _N(.@"-", calc.NegOp);
  pub const @"*x" = selection.First;
  pub const @"!i" = @import("iota.zig").Iota;
  pub const @"!I" = @import("odometer.zig").Odometer;
  pub const @"!d" = @import("keys.zig").Keys;
  pub const @"&x" = @import("where.zig").Where;
  pub const @"|x" = @import("reverse.zig").Reverse;
  pub const @"<s" =  @import("open.zig").Open;
  pub const @"<X" = sort.Ascend;
  pub const @">X" = sort.Descend;
  pub const @"=X" = @import("group.zig").Group;
  pub const @"=i" = _X(.@"?", @import("uniform.zig").UniformOp);
  pub const @"~x" = _B(.@"~", logic.NotOp);
  pub const @",x" = @import("enlist.zig").Enlist;
  pub const @"^x" = @import("nulls.zig").Nulls;
  pub const @"#x" = @import("tally.zig").Tally;
  pub const @"_c" = @import("lowercase.zig").Lowercase;
  pub const @"_n" = @import("floor.zig").Floor;
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

  pub const @"=u"  = @import("unitary.zig").Unitary;
  pub const @"?X"  = @import("distinct.zig").Distinct;
  pub const @"0:x" = io.ReadLines;
  pub const @"1:x" = io.ReadBytes;
  pub const @"2:x" = io.ReadData;
  pub const @".m"  = @import("values.zig").Values;
  pub const @".s"  = @import("get.zig").GetSymbol;
  pub const exec   = @import("exec.zig").Exec;
};

const Dyads = struct {
  // Dyadic Primitives
  pub const @"N+N" = _N_N(.@"+", calc.AddOp);
  pub const @"N-N" = _N_N(.@"-", calc.SubOp);
  pub const @"N*N" = _N_N(.@"*", calc.MulOp);
  pub const @"N%N" = _F_F(.@"%", calc.DivOp);
  pub const @"N&N" = _N_N(.@"&", calc.MinOp);
  pub const @"N|N" = _N_N(.@"|", calc.MaxOp);
  pub const @"x!y" = pair.Pair;
  pub const @"X=X" = logic.Equal;
  pub const @"X<X" = logic.Less;
  pub const @"X>X" = logic.More;
  pub const @"X~X" = @import("match.zig").Match;
  pub const @"I mod I"  = _I_I(.mod, calc.ModOp);
  pub const @"I div I"  = _I_I(.div, calc.DiviOp);
  
  pub const @"x,y"  = concat.Concat;
  pub const @"i_X"  = @import("drop.zig").Drop;
  pub const @"I_X"  = _I_A(.@"_", @import("cut.zig").Cut);
  pub const @"B_X"  = @import("weedout.zig").WeedOut;
  pub const @"X_i"  = @import("delete.zig").Delete;

  pub const @"x_m"  = @import("drop_keys.zig").DropKeys;
  pub const @"m,m"  = @import("merge.zig").DictMerge;
  pub const @"x#m"  = @import("select.zig").TakeKeys;
  pub const @"M,m"  = @import("insert.zig").Insert;
  // pub const @"M,m2" = @import("insert.zig").Upsert;
  // pub const @"m|m"  = @import("join.zig").UnionJoin;
  // pub const @"m,m2" = @import("join.zig").LeftJoin;
  // pub const @"m^m"  = dict.OuterJoin;

  pub const @"i#X"  = @import("take.zig").Take;
  pub const @"I#X"  = @import("reshape.zig").Reshape;
  pub const @"x^X"  = @import("fill.zig").Fill;
  pub const @"X^X"  = @import("without.zig").Without;
  pub const @"i$C"  = @import("pad.zig").Pad;
  pub const @"s$x"  = @import("cast.zig").Cast;
  pub const @"X?x"  = @import("find.zig").Find;
  pub const @"i?X"  = @import("random.zig").Random;
  pub const @"X@X"  = @import("pick.zig").Pick;
  pub const @"s?x"  = @import("marshal.zig").Marshal;
  pub const @"s@x"  = @import("marshal.zig").Unmarshal;
  // pub const @"x@y" = @import("apply.zig").ApplyN; // TODO re-enable
  // pub const @"x.y" = @import("apply.zig").ApplyN; // TODO: pick.pick reference broken
  pub const @"has"  = member.Has;
  pub const @"in"   = member.In;
  pub const @"x0:x" = io.WriteLines;
  pub const @"x1:x" = io.WriteBytes;
  pub const @"x2:x" = io.WriteData;

  pub const @"9:x"    = @import("graphics.zig").Draw;
  pub const @"x9:x"  = @import("graphics.zig").DrawDyad;
  pub const @"x exec" = @import("exec.zig").ExecDyad;
};

fn typeError1(_: *VM, _:V) V { return .{ .err = .@"type" }; }
fn typeError2(_: *VM, _:V, _:V) V { return .{ .err = .@"type" }; }

fn makeMonadArray(comptime Defs: type) [Op.COUNT * K.COUNT]util.MonadFn {
  @setEvalBranchQuota(10000000);
  var table: [Op.COUNT * K.COUNT]util.MonadFn = .{typeError1} ** (Op.COUNT * K.COUNT);
  for (std.meta.declarations(Defs)) |decl| {
    const Verb = @field(Defs, decl.name);
    const op = verbOp(Verb) orelse continue;
    for (std.meta.fields(Verb)) |f| {
      const sig = parseSig(f.name);
      if (sig.len == 1) {
        const key = @intFromEnum(op) * K.COUNT + sig[0].code();
        table[key] = f.defaultValue().?;
      }
    }
  }
  return table;
}

fn makeDyadArray(comptime Defs: type) [Op.COUNT * K.COUNT * K.COUNT]?util.DyadFn {
  @setEvalBranchQuota(10000000);
  var table: [Op.COUNT * K.COUNT * K.COUNT]?util.DyadFn = .{null} ** (Op.COUNT * K.COUNT * K.COUNT);
  for (std.meta.declarations(Defs)) |decl| {
    const Verb = @field(Defs, decl.name);
    const op = verbOp(Verb) orelse continue;
    for (std.meta.fields(Verb)) |f| {
      const sig = parseSig(f.name);
      if (sig.len == 2) {
        const key = op.code() * K.COUNT * K.COUNT + sig[0].code() * K.COUNT + sig[1].code();
        table[key] = f.defaultValue().?;
      }
    }
  }
  return table;
}

fn verbOp(comptime Verb: type) ?Op {
  if (@hasDecl(Verb, "op")) return @as(Op, @field(Verb, "op"));
  for (std.meta.fields(Verb)) |f|
    if (comptime std.mem.eql(u8, f.name, "op"))
      return @as(Op, f.defaultValue() orelse return null);
  return null;
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
