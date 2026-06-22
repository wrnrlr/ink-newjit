const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const VM = @import("../../runtime/vm.zig").VM;
const selection = @import("first.zig");
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

// ── Inlined from tiny single-file verbs ──────────────────────────────────────

const LessOp  = struct { pub fn f(x: anytype, y: @TypeOf(x)) bool { return x < y; } };
const MoreOp  = struct { pub fn f(x: anytype, y: @TypeOf(x)) bool { return x > y; } };
const EqualOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) bool { return x == y; } };
const NotOp   = struct {
  pub fn f(x: anytype) bool {
    const T = @TypeOf(x);
    if (T == i32) return x == 0;
    if (T == f32) return x == 0.0 or std.math.isNan(x);
    unreachable;
  }
};

const FloorOp = struct {
  pub fn f(x: anytype) i32 { return @intFromFloat(std.math.floor(x)); }
};

const LowercaseOp = struct {
  pub fn f(x: anytype) u8 { return std.ascii.toLower(@intCast(x)); }
};
const Lowercase = h.makeMonad(.@"_", h.Char1, h.Char1, LowercaseOp, &.{.c, .C});

const Keys = struct {
  pub const op = .@"!";
  _m: VM.Monad = keysDict,
  _M: VM.Monad = keysTable,
};
fn keysDict(_: *VM, x: V) V { return x.m.av().ref(); }
fn keysTable(_: *VM, x: V) V { return x.M.av().ref(); }

const Values = struct {
  pub const op = .@".";
  _m: VM.Monad = valuesDict,
};
fn valuesDict(_: *VM, x: V) V { return x.m.bv().ref(); }

const Open = struct {
  pub const op = .@"<";
  _s: VM.Monad = openFile,
};
fn openFile(vm: *VM, x: V) V {
  const path = vm.getSymbol(x.s);
  const id = vm.mapFile(path) catch return .{ .err = .io };
  return .{ .i = @intCast(id) };
}

const Close = struct {
  pub const op = .@"<";
  _i: VM.Monad = io.closeHandle,
};

const UniformOp = struct { _i: VM.Monad = uniform };
fn uniform(vm: *VM, x: V) V {
  if (x.i < 0) return .{ .err = .domain };
  const size: usize = @intCast(x.i);
  const F = N(f32).init(vm.alloc, size) catch return .{ .err = .memory };
  const random = vm.prng.random();
  for (F.slice()) |*v| v.* = random.float(f32);
  return .{ .F = F };
}

const Unitary = struct {
  pub const op = .@"=";
  _i: VM.Monad = unitary,
};
fn unitary(vm: *VM, x: V) V {
  if (x.i < 0) return .{ .err = .domain };
  const size: usize = @intCast(x.i);
  const res = N(V).init(vm.alloc, size) catch return V{ .err = .memory };
  for (0..size) |i| {
    const row = N(i32).init(vm.alloc, size) catch return V{ .err = .memory };
    @memset(row.slice(), 0);
    row.slice()[i] = 1;
    res.slice()[i] = .{ .I = row };
  }
  return .{ .L = res };
}

const r = @import("../derived/reduce.zig");

const Monads = struct {
  // Monadic Primitives
  pub const @"+x" = @import("flip.zig").Flip;
  pub const @"-N" = _N(.@"-", calc.NegOp);
  pub const @"*x" = selection.First;
  pub const @"*|x"  = selection.Last_Name;
  pub const @"⍳i" = @import("iota.zig").Iota;
  pub const @"↕I" = @import("odometer.zig").Odometer;
  pub const @"!d" = Keys;
  pub const @"&x" = @import("where.zig").Where;
  pub const @"|x" = @import("reverse.zig").Reverse;
  pub const @"⍋x" = sort.Ascend;
  pub const @"⍒x" = sort.Descend;
  pub const @"<s" = Open;    // file open by symbol (overrides degenerate sort._s)
  pub const @"<h" = Close;   // close handle by integer (overrides degenerate sort._i)
  pub const @"=X" = @import("group.zig").Group;
  pub const @"=i" = _X1(.@"?", UniformOp);
  pub const @"~x" = _B(.@"~", NotOp);
  pub const @",x" = @import("enlist.zig").Enlist;
  pub const @"^x" = @import("nulls.zig").Nulls;
  pub const @"#x" = @import("tally.zig").Tally;
  pub const @"_c" = Lowercase;
  pub const @"_n" = h.makeMonad(.@"_", h.Float1, h.Int1, FloorOp, &.{.f, .F});
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
  pub const @"=u"    = Unitary;
  pub const @"?X"    = @import("distinct.zig").Distinct;
  pub const @"0:x" = io.ReadLines;
  pub const @"1:x" = io.ReadBytes;
  pub const @"2:x" = io.ReadData;
  pub const @">x"  = io.NetOpen;
  pub const @".m"  = Values;
  pub const @".s"  = @import("get.zig").GetSymbol;
  pub const exec   = @import("exec.zig").Exec;
  // Fused derived verbs — direct monadic reductions over typed arrays.
  pub const @"sum x"     = r.Sum;
  pub const @"product x" = r.Product;
  pub const @"min x"     = r.Min;
  pub const @"max x"     = r.Max;
};

const Dyads = struct {
  pub const @"N+N" = _N_N(.@"+", calc.AddOp);
  pub const @"N-N" = _N_N(.@"-", calc.SubOp);
  pub const @"N*N" = _N_N(.@"*", calc.MulOp);
  pub const @"N%N" = _F_F(.@"%", calc.DivOp);
  pub const @"N&N" = _N_N(.@"&", calc.MinOp);
  pub const @"N|N" = _N_N(.@"|", calc.MaxOp);
  pub const @"B&B" = _B_B(.@"&", calc.AndOp);
  pub const @"B|B" = _B_B(.@"|", calc.OrOp);
  
  pub const @"X=X" = _Cmp(.@"=", EqualOp);
  pub const @"X<X" = _Cmp(.@"<", LessOp);
  pub const @"X>X" = _Cmp(.@">", MoreOp);
  pub const @"X~X" = @import("match.zig").Match;
  pub const @"x!y" = pair.Pair;
  pub const @"I⌊I"  = _I_I(.mod, calc.ModOp);
  pub const @"I÷I"  = _I_I(.div, calc.DiviOp);
  pub const @"x,y"  = concat.Concat;
  
  pub const @"i_X"  = @import("drop.zig").Drop;
  pub const @"I_X"  = _X2(.@"_", @import("cut.zig").Cut);
  pub const @"B_X"  = @import("weedout.zig").WeedOut;
  pub const @"X_i"  = @import("delete.zig").Delete;
  pub const @"x_m"  = @import("drop_keys.zig").DropKeys;
  
  pub const @"m,m"  = @import("merge.zig").DictMerge;
  pub const @"x#m"  = @import("select.zig").SelectKeys;
  pub const @"M,m"  = @import("insert.zig").Insert;
  pub const @"i#X"  = @import("take.zig").Take;
  pub const @"I#X"  = @import("reshape.zig").Reshape;
  pub const @"x^X"  = @import("fill.zig").Fill;
  pub const @"X^X"  = @import("without.zig").Without;
  pub const @"i$C"  = @import("pad.zig").Pad;
  pub const @"s$x"  = @import("cast.zig").Cast;
  pub const @"X?x"  = @import("find.zig").Find;
  pub const @"i?X"  = @import("random.zig").Random;
  pub const @"f@y"  = @import("apply.zig").Apply;
  pub const @"m@X"  = @import("select.zig").SelectDict;
  pub const @"M@X"  = @import("select.zig").SelectTable;
  pub const @"x@y"  = @import("apply.zig").Apply;
  pub const @"X@X"  = @import("pick.zig").Pick;
  pub const @"s?x"  = @import("marshal.zig").Marshal;
  pub const @"s@x"  = @import("marshal.zig").Unmarshal;
  pub const @"x has y"  = member.Has;
  pub const @"x in y"   = member.In;
  pub const @"x 0: x" = io.WriteLines;
  pub const @"x 1: x" = io.WriteBytes;
  pub const @"x 2: x" = io.WriteData;
  pub const @"x: y"    = @import("right.zig").Right;
  pub const @"x exec" = @import("exec.zig").ExecDyad;
};

fn typeError1(_: *VM, _:V) V { return .{ .err = .@"type" }; }
fn typeError2(_: *VM, _:V, _:V) V { return .{ .err = .@"type" }; }

fn opOf(comptime Verb: type, comptime EnumT: type) ?EnumT {
  if (@hasDecl(Verb, "op")) return @as(EnumT, @field(Verb, "op"));
  for (std.meta.fields(Verb)) |f|
    if (comptime std.mem.eql(u8, f.name, "op"))
      return @as(EnumT, f.defaultValue() orelse return null);
  return null;
}

fn makeMonadArray(comptime Defs: type) [Op1.COUNT * K.COUNT]VM.Monad {
  @setEvalBranchQuota(10000000);
  var table: [Op1.COUNT * K.COUNT]VM.Monad = .{typeError1} ** (Op1.COUNT * K.COUNT);
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

fn makeDyadArray(comptime Defs: type) [Op2.COUNT * K.COUNT * K.COUNT]VM.Dyad {
  @setEvalBranchQuota(10000000);
  var table: [Op2.COUNT * K.COUNT * K.COUNT]VM.Dyad = .{typeError2} ** (Op2.COUNT * K.COUNT * K.COUNT);
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
