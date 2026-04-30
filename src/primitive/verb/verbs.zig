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
const string = @import("string.zig");

const V = value.V;
const N = value.N;

// TODO: tables can be smaller if we split monads and dyads into their own Op enum
pub const monad_table = makeMonadArray(Monads);
pub const dyad_table  = makeDyadArray(Dyads);

const Monads = struct {
  // Monadic Primitives
  pub const Draw     = @import("graphics.zig").Draw;
  pub const Sqrt = calc.Sqrt;
  pub const Sqr = calc.Sqr;
  pub const Exp = calc.Exp;
  pub const Log = calc.Log;
  pub const Sin = calc.Sin;
  pub const Cos = calc.Cos;
  pub const Neg = calc.Neg;
  pub const Abs = calc.Abs;
  pub const Not = logic.Not;
  pub const Floor = @import("floor.zig").Floor;
  pub const Lowercase = @import("lowercase.zig").Lowercase;
  pub const First = selection.First;
  pub const Uniform = @import("uniform.zig").Uniform;
  pub const Tally = @import("tally.zig").Tally;
  pub const Format = string.Format;
  pub const Keys = @import("keys.zig").Keys;
  pub const Nulls = @import("nulls.zig").Nulls;
  pub const Flip = @import("flip.zig").Flip;
  pub const Iota = @import("iota.zig").Iota;
  pub const Odometer = @import("odometer.zig").Odometer;
  pub const Type = @import("type.zig").Type;
  pub const Where = @import("where.zig").Where;
  pub const Reverse = @import("reverse.zig").Reverse;
  pub const Open =  @import("open.zig").Open;
  pub const Ascend = sort.Ascend;
  pub const Descend = sort.Descend;
  pub const Unitary = @import("unitary.zig").Unitary;
  pub const Group = @import("group.zig").Group;
  pub const Distinct = @import("distinct.zig").Distinct;
  pub const Enlist = @import("enlist.zig").Enlist;
  pub const ReadLines = io.ReadLines;
  pub const ReadBytes = io.ReadBytes;
  pub const ReadData = io.ReadData;
  pub const Values = @import("values.zig").Values;
  pub const GetSymbol = @import("get.zig").GetSymbol;
};

const Dyads = struct {
  // Dyadic Primitives
  pub const Add = calc.Add;
  pub const Sub = calc.Sub;
  pub const Mul = calc.Mul;
  pub const Div = calc.Div;
  pub const Min = calc.Min;
  pub const Max = calc.Max;
  pub const Equal = logic.Equal;
  pub const Less = logic.Less;
  pub const More = logic.More;
  // pub const Pair = @import("pair.zig").Pair;
  pub const Drop = @import("drop.zig").Drop;
  pub const DropKeys = @import("drop_keys.zig").DropKeys;
  pub const Cut = @import("cut.zig").Cut;
  pub const WeedOut = @import("weedout.zig").WeedOut;
  pub const Delete = @import("delete.zig").Delete;
  pub const DictMerge = @import("merge.zig").DictMerge;
  pub const TakeKeys = @import("select.zig").TakeKeys;
  pub const Take = @import("take.zig").Take;
  pub const Reshape = @import("reshape.zig").Reshape;
  pub const Fill = @import("fill.zig").Fill;
  pub const Without = @import("without.zig").Without;
  pub const Pad = @import("pad.zig").Pad;
  pub const Cast = @import("cast.zig").Cast;
  pub const Find = @import("find.zig").Find;
  pub const Random = @import("random.zig").Random;
  pub const Pick = @import("pick.zig").Pick;
  pub const Marshal = @import("marshal.zig").Marshal;
  pub const Unmarshal = @import("marshal.zig").Unmarshal;
  // pub const ApplyN = @import("apply.zig").ApplyN; // TODO re-enable
  pub const Has = member.Has;
  pub const In = member.In;
  pub const WriteLines = io.WriteLines;
  pub const WriteBytes = io.WriteBytes;
  pub const WriteData = io.WriteData;
  pub const Insert = @import("insert.zig").Insert;
  // pub const Upsert = @import("insert.zig").Upsert;
  // pub const UnionJoin = @import("join.zig").UnionJoin;
  // pub const LeftJoin = @import("join.zig").LeftJoin;
  // pub const OuterJoin = dict.OuterJoin;
  pub const Draw     = @import("graphics.zig").Draw;
  pub const DrawDyad = @import("graphics.zig").DrawDyad;
};

fn makeMonadArray(comptime Defs: type) [Op.COUNT * K.COUNT]?util.MonadFn {
  @setEvalBranchQuota(10000000);
  var table: [Op.COUNT * K.COUNT]?util.MonadFn = .{null} ** (Op.COUNT * K.COUNT);
  inline for (std.meta.declarations(Defs)) |decl| {
    const Verb = @field(Defs, decl.name);
    const op = verbOp(Verb) orelse continue;
    inline for (std.meta.fields(Verb)) |f| {
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
  inline for (std.meta.declarations(Defs)) |decl| {
    const Verb = @field(Defs, decl.name);
    const op = verbOp(Verb) orelse continue;
    inline for (std.meta.fields(Verb)) |f| {
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
  inline for (std.meta.fields(Verb)) |f|
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
  inline while (i <= name.len) : (i += 1) {
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
