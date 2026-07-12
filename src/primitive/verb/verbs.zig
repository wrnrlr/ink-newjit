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

// Dispatch tables: monad keyed by Op1, dyad split in two stages.
//
// Stage 1 (quick_table): the arithmetic dyads (+ - * %, Op2 codes below
// QUICK_COUNT) over the numeric scalar/vector types {b i f n B I F N},
// shift-indexed as op<<8 | xcode<<4 | ycode. Default slots hold the per-op
// structural fallback (h.containerDyad: dict recursion, list broadcast, else
// type error), so the hot table never grows when a new type is added — a new
// type dispatches through stage 2 until it earns a dense code here.
//
// Stage 2 (stage2slots/stage2off): every other op as a sparse sorted row of
// (typepair key → kernel) slots, binary-searched by dispatch2. A miss hits
// the op's row fallback (stage2fb): containerDyad for the broadcasting ops
// (= | & < > mod div), type error otherwise. Memory grows with implemented
// slots, not with ops × K.COUNT².
pub const monad_table = makeMonadArray(Monads);
pub const quick_table = makeQuickArray(Dyads);

pub const S1_STRIDE = 16; // power of two: the stage-1 key is pure shifts/ors
const stage1_types = [_]K{ .b, .i, .f, .n, .d, .h, .B, .I, .F, .N, .D, .H };
const S1_OTHER: u8 = stage1_types.len; // sentinel code: hits the fallback slots

/// K.code() → dense stage-1 type code (S1_OTHER for container/exotic types).
pub const stage1code: [K.COUNT]u8 = blk: {
  var t: [K.COUNT]u8 = .{S1_OTHER} ** K.COUNT;
  for (stage1_types, 0..) |k, i| t[k.code()] = i;
  break :blk t;
};

pub const DYAD2_COUNT = Op2.COUNT - Op2.QUICK_COUNT;
const ROW = K.COUNT * K.COUNT;
/// Non-quick ops whose type-pair misses broadcast over containers instead of
/// erroring (they are the makeDyad-built element-wise ops).
const broadcast_ops = [_]Op2{ .@"=", .@"|", .@"&", .@"<", .@">", .mod, .div };

const scratch = makeStage2Scratch(Dyads);

// All registered stage-2 slots, sorted by (op row, typepair key). Keys and
// kernels live in parallel arrays so the binary search scans a dense u16
// array and touches the pointer array exactly once, on the hit.
pub const stage2keys: [countSlots(&scratch)]u16 = blk: {
  @setEvalBranchQuota(1000000);
  var out: [countSlots(&scratch)]u16 = undefined;
  var idx: usize = 0;
  for (scratch, 0..) |mf, j| {
    if (mf != null) {
      out[idx] = @intCast(j % ROW);
      idx += 1;
    }
  }
  break :blk out;
};

pub const stage2fns: [countSlots(&scratch)]VM.Dyad = blk: {
  @setEvalBranchQuota(1000000);
  var out: [countSlots(&scratch)]VM.Dyad = undefined;
  var idx: usize = 0;
  for (scratch) |mf| {
    if (mf) |fun| {
      out[idx] = fun;
      idx += 1;
    }
  }
  break :blk out;
};

/// Per-op row bounds into stage2slots (row = op.code() - QUICK_COUNT).
pub const stage2off: [DYAD2_COUNT + 1]u16 = blk: {
  @setEvalBranchQuota(1000000);
  var off: [DYAD2_COUNT + 1]u16 = undefined;
  var idx: u16 = 0;
  off[0] = 0;
  for (0..DYAD2_COUNT) |row| {
    for (scratch[row * ROW .. (row + 1) * ROW]) |mf| {
      if (mf != null) idx += 1;
    }
    off[row + 1] = idx;
  }
  break :blk off;
};

/// Per-op miss handler for stage-2 rows.
pub const stage2fb: [DYAD2_COUNT]VM.Dyad = blk: {
  var t: [DYAD2_COUNT]VM.Dyad = .{typeError2} ** DYAD2_COUNT;
  for (broadcast_ops) |o| t[o.code() - Op2.QUICK_COUNT] = h.containerFallback(o);
  // ~ registers only same-tag slots; every mismatched pair is simply false.
  t[Op2.@"~".code() - Op2.QUICK_COUNT] = &@import("match.zig").matchFalse;
  break :blk t;
};

comptime {
  std.debug.assert(S1_STRIDE == 16); // dispatch2 hardcodes op<<8 | x<<4 | y
  std.debug.assert(S1_OTHER < S1_STRIDE);
  // The quick range must be exactly the arithmetic ops.
  for (Op2.arith) |o| std.debug.assert(o.code() < Op2.QUICK_COUNT);
  std.debug.assert(Op2.QUICK_COUNT == 4);
  for (broadcast_ops) |o| std.debug.assert(o.code() >= Op2.QUICK_COUNT);
}

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

// Natural (n, u32-backed) arithmetic. Naturals never mix with the other
// numerics implicitly — only n⊕n slots exist; mixed pairs hit the fallback.
const nat_types = [_]K{ .n, .N };
fn Nat2(comptime _: type, comptime _: type) type { return u32; }
pub fn _U_U(comptime op: Op2, comptime f: type) type { return h.makeDyad(op, Nat2, Nat2, f, &nat_types); }

// Tier-2 explicit-precision floats — f64 (d) and f16 (h). Each is an isolated
// closed set like naturals: only d⊕d / h⊕h slots exist, so there is no
// cross-precision mixing and no O(types²) blowup. Cross-precision needs a cast.
const dbl_types = [_]K{ .d, .D };
const hlf_types = [_]K{ .h, .H };
fn Dbl1(comptime _: type) type { return f64; }
fn Hlf1(comptime _: type) type { return f16; }
fn Dbl2(comptime _: type, comptime _: type) type { return f64; }
fn Hlf2(comptime _: type, comptime _: type) type { return f16; }
pub fn _D_D(comptime op: Op2, comptime f: type) type { return h.makeDyad(op, Dbl2, Dbl2, f, &dbl_types); }
pub fn _H_H(comptime op: Op2, comptime f: type) type { return h.makeDyad(op, Hlf2, Hlf2, f, &hlf_types); }
pub fn _Dm(comptime op: Op1, comptime f: type) type { return h.makeMonad(op, Dbl1, Dbl1, f, &dbl_types); }
pub fn _Hm(comptime op: Op1, comptime f: type) type { return h.makeMonad(op, Hlf1, Hlf1, f, &hlf_types); }

// Comparison over like-typed operands with no numeric upcast: the result stays
// in the operand's backing type (u8 for chars, u32 for interned symbols), so the
// generic Caster never has to convert a u8/u32 it can't. Used for char/symbol =
// (and char order), which the numeric _Cmp over {b,i,f,B,I,F} can't express.
fn Same2(comptime T1: type, comptime _: type) type { return T1; }
const char_types   = [_]K{ .c, .C };
const symbol_types = [_]K{ .s, .S };
pub fn _CmpSame(comptime op: Op2, comptime f: type, comptime ts: []const K) type { return h.makeDyad(op, Same2, h.Bool2, f, ts); }

// ── Inlined from tiny single-file verbs ──────────────────────────────────────

// Comparison result type: scalar bool, or a bool-vector when x is a @Vector (so
// the SIMD kernels in helper.zig can run x<y / x==y on lanes). `pub const simd`
// marks them vector-safe; the gate there also restricts to i32/f32/bool operands,
// so char/symbol/u32 comparisons keep taking the scalar path.
fn CmpR(comptime T: type) type {
  const info = @typeInfo(T);
  return if (info == .vector) @Vector(info.vector.len, bool) else bool;
}
const LessOp  = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) CmpR(@TypeOf(x)) { return x < y; } };
const MoreOp  = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) CmpR(@TypeOf(x)) { return x > y; } };
const EqualOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) CmpR(@TypeOf(x)) { return x == y; } };
const NotOp   = struct {
  pub const simd = {};
  pub fn f(x: anytype) CmpR(@TypeOf(x)) {
    const T = @TypeOf(x);
    if (comptime @typeInfo(T) == .vector) {
      const Ch = @typeInfo(T).vector.child;
      const z: T = @splat(if (Ch == f32) 0.0 else 0);
      const iszero = x == z;
      // isNan(x) == (x != x); `~` of NaN is true, matching the scalar path.
      if (comptime Ch == f32) return @select(bool, iszero, iszero, x != x);
      return iszero;
    }
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
  _M: VM.Monad = valuesTable,
};
fn valuesDict(_: *VM, x: V) V { return x.m.bv().ref(); }
fn valuesTable(_: *VM, x: V) V { return x.M.bv().ref(); }

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
  // Tier-2 float monadics — negate / abs / sqrt / sqr / exp / log / sin / cos
  // over f64 (d) and f16 (h). Isolated: they add only _d/_D and _h/_H slots.
  pub const @"-D"   = _Dm(.@"-", calc.NegOp);
  pub const @"-H"   = _Hm(.@"-", calc.NegOp);
  pub const @"absD" = _Dm(.abs,  calc.AbsOp);
  pub const @"absH" = _Hm(.abs,  calc.AbsOp);
  pub const @"sqrtD" = _Dm(.sqrt, calc.SqrtOp);
  pub const @"sqrtH" = _Hm(.sqrt, calc.SqrtOp);
  pub const @"sqrD" = _Dm(.sqr,  calc.SqrOp);
  pub const @"sqrH" = _Hm(.sqr,  calc.SqrOp);
  pub const @"expD" = _Dm(.exp,  calc.ExpOp);
  pub const @"expH" = _Hm(.exp,  calc.ExpOp);
  pub const @"logD" = _Dm(.log,  calc.LogOp);
  pub const @"logH" = _Hm(.log,  calc.LogOp);
  pub const @"sinD" = _Dm(.sin,  calc.SinOp);
  pub const @"sinH" = _Hm(.sin,  calc.SinOp);
  pub const @"cosD" = _Dm(.cos,  calc.CosOp);
  pub const @"cosH" = _Hm(.cos,  calc.CosOp);
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
  pub const @"depth x" = @import("depth.zig").Depth;
  pub const @"epoch x" = @import("epoch.zig").Epoch;
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
  // Internal verb emitted by the peephole for the `#'=` idiom (see freq.zig).
  pub const @"freq x"    = @import("freq.zig").Freq;
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

  // Natural (u32) arithmetic — wraps like i; % divides as f32.
  pub const @"n+n" = _U_U(.@"+", calc.AddOp);
  pub const @"n-n" = _U_U(.@"-", calc.SubOp);
  pub const @"n*n" = _U_U(.@"*", calc.MulOp);
  pub const @"n%n" = h.makeDyad(.@"%", h.Float2, h.Float2, calc.DivOp, &nat_types);
  pub const @"n&n" = _U_U(.@"&", calc.MinOp);
  pub const @"n|n" = _U_U(.@"|", calc.MaxOp);
  pub const @"n=n" = _CmpSame(.@"=", EqualOp, &nat_types);
  pub const @"n<n" = _CmpSame(.@"<", LessOp,  &nat_types);
  pub const @"n>n" = _CmpSame(.@">", MoreOp,  &nat_types);

  // f64 (d) arithmetic — closed in f64; % is a true f64 divide.
  pub const @"d+d" = _D_D(.@"+", calc.AddOp);
  pub const @"d-d" = _D_D(.@"-", calc.SubOp);
  pub const @"d*d" = _D_D(.@"*", calc.MulOp);
  pub const @"d%d" = _D_D(.@"%", calc.DivOp);
  pub const @"d&d" = _D_D(.@"&", calc.MinOp);
  pub const @"d|d" = _D_D(.@"|", calc.MaxOp);
  pub const @"d=d" = _CmpSame(.@"=", EqualOp, &dbl_types);
  pub const @"d<d" = _CmpSame(.@"<", LessOp,  &dbl_types);
  pub const @"d>d" = _CmpSame(.@">", MoreOp,  &dbl_types);

  // f16 (h) arithmetic — closed in f16.
  pub const @"h+h" = _H_H(.@"+", calc.AddOp);
  pub const @"h-h" = _H_H(.@"-", calc.SubOp);
  pub const @"h*h" = _H_H(.@"*", calc.MulOp);
  pub const @"h%h" = _H_H(.@"%", calc.DivOp);
  pub const @"h&h" = _H_H(.@"&", calc.MinOp);
  pub const @"h|h" = _H_H(.@"|", calc.MaxOp);
  pub const @"h=h" = _CmpSame(.@"=", EqualOp, &hlf_types);
  pub const @"h<h" = _CmpSame(.@"<", LessOp,  &hlf_types);
  pub const @"h>h" = _CmpSame(.@">", MoreOp,  &hlf_types);

  pub const @"X=X" = _Cmp(.@"=", EqualOp);
  pub const @"X<X" = _Cmp(.@"<", LessOp);
  pub const @"X>X" = _Cmp(.@">", MoreOp);
  // Symbol equality (interned-id compare) and char equality/order — separate
  // structs so they add only the c/C and s/S type-pair slots to =,<,> without
  // disturbing the numeric kernels above. Symbols compare only for equality.
  pub const @"c=c" = _CmpSame(.@"=", EqualOp, &char_types);
  pub const @"c<c" = _CmpSame(.@"<", LessOp,  &char_types);
  pub const @"c>c" = _CmpSame(.@">", MoreOp,  &char_types);
  pub const @"s=s" = _CmpSame(.@"=", EqualOp, &symbol_types);
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

fn makeQuickArray(comptime Defs: type) [Op2.QUICK_COUNT * S1_STRIDE * S1_STRIDE]VM.Dyad {
  @setEvalBranchQuota(10000000);
  var table: [Op2.QUICK_COUNT * S1_STRIDE * S1_STRIDE]VM.Dyad = undefined;
  for (0..Op2.QUICK_COUNT) |oc| {
    const fallback = h.containerFallback(@enumFromInt(oc));
    for (0..S1_STRIDE * S1_STRIDE) |j| table[oc * S1_STRIDE * S1_STRIDE + j] = fallback;
  }
  for (std.meta.declarations(Defs)) |decl| {
    const Verb = @field(Defs, decl.name);
    const op2 = opOf(Verb, Op2) orelse continue;
    if (op2.code() >= Op2.QUICK_COUNT) continue;
    for (std.meta.fields(Verb)) |f| {
      const sig = parseSig(f.name);
      if (sig.len == 2) {
        const xc = stage1code[sig[0].code()];
        const yc = stage1code[sig[1].code()];
        if (xc == S1_OTHER or yc == S1_OTHER)
          @compileError("quick-op slot outside stage-1 types: " ++ decl.name ++ "." ++ f.name);
        const key = op2.code() * S1_STRIDE * S1_STRIDE + xc * S1_STRIDE + yc;
        table[key] = f.defaultValue().?;
      }
    }
  }
  return table;
}

// Dense scratch matrix used only at comptime to apply declaration-order
// overrides (later decls win) before flattening into the sparse sorted rows.
fn makeStage2Scratch(comptime Defs: type) [DYAD2_COUNT * ROW]?VM.Dyad {
  @setEvalBranchQuota(10000000);
  var t: [DYAD2_COUNT * ROW]?VM.Dyad = .{null} ** (DYAD2_COUNT * ROW);
  for (std.meta.declarations(Defs)) |decl| {
    const Verb = @field(Defs, decl.name);
    const op2 = opOf(Verb, Op2) orelse continue;
    if (op2.code() < Op2.QUICK_COUNT) continue;
    for (std.meta.fields(Verb)) |f| {
      const sig = parseSig(f.name);
      if (sig.len == 2)
        t[(op2.code() - Op2.QUICK_COUNT) * ROW + sig[0].code() * K.COUNT + sig[1].code()] = f.defaultValue().?;
    }
  }
  return t;
}

fn countSlots(comptime t: []const ?VM.Dyad) usize {
  @setEvalBranchQuota(1000000);
  var c: usize = 0;
  for (t) |mf| { if (mf != null) c += 1; }
  return c;
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
