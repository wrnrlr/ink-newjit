const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;

// ─── The inferred-type abstract domain ────────────────────────────────────────
//
// An inferred type `Ty` is the static knowledge we have about an IR value before
// it runs. It is intentionally richer than `K` (which fuses element-type with a
// single rank bit) so it can carry nesting and, in Phase 3, symbolic shape. `Ty`
// projects back *down* to `K` via `toK`, which is the only coupling to the
// runtime dispatch tables / stencil catalog. When `toK` returns null the value
// has no precise runtime type and must stay on the dynamic-dispatch path — that
// graceful fallback is what makes the whole system "invisible".

/// Element-type axis. `bottom` = not-yet-computed (worklist seed); `unknown` = ⊤
/// (dynamic). `b/i/f/s/c` mirror the scalar `K` backing kinds; `fn_/dict/table`
/// are opaque element domains (we know the structure but not its contents).
pub const Elem = enum(u8) {
  bottom,
  unknown,
  b, i, f, s, c,
  fn_, dict, table,

  /// Position in the numeric cast chain b ⊏ i ⊏ f, or null for non-numeric.
  fn numRank(e: Elem) ?u8 {
    return switch (e) { .b => 0, .i => 1, .f => 2, else => null };
  }
  fn fromNumRank(r: u8) Elem {
    return switch (r) { 0 => .b, 1 => .i, else => .f };
  }
};

/// One dimension's size. Phase 1 only ever produces `.unknown` / `.known`;
/// `.symbolic` (a fresh size variable) is wired up in Phase 3.
pub const Dim = union(enum) {
  unknown,
  known: u32,
  symbolic: u16,

  pub fn eql(a: Dim, b: Dim) bool {
    return switch (a) {
      .unknown => b == .unknown,
      .known => |x| b == .known and b.known == x,
      .symbolic => |x| b == .symbolic and b.symbolic == x,
    };
  }
  pub fn join(a: Dim, b: Dim) Dim {
    return if (a.eql(b)) a else .unknown;
  }
};

pub const MAX_RANK: u8 = 4;
/// Sentinel rank meaning "rank itself is unknown" (⊤ on the rank axis).
pub const RANK_TOP: u8 = 0xff;

pub const Ty = struct {
  elem: Elem = .bottom,
  rank: u8 = 0, // 0 atom, 1 vector, >=2 nested; RANK_TOP = unknown rank
  shape: [MAX_RANK]Dim = .{ .unknown, .unknown, .unknown, .unknown },

  pub const BOTTOM: Ty = .{ .elem = .bottom, .rank = 0 };
  pub const TOP: Ty = .{ .elem = .unknown, .rank = RANK_TOP };

  pub fn atom(e: Elem) Ty {
    return .{ .elem = e, .rank = 0 };
  }
  pub fn vector(e: Elem, length: ?u32) Ty {
    var t: Ty = .{ .elem = e, .rank = 1 };
    if (length) |n| t.shape[0] = .{ .known = n };
    return t;
  }

  pub fn isBottom(t: Ty) bool {
    return t.elem == .bottom;
  }
  pub fn isTop(t: Ty) bool {
    return t.elem == .unknown and t.rank == RANK_TOP;
  }

  /// Project to a concrete runtime class, or null when there is no precise `K`
  /// (unknown element, unknown/nested rank). Null ⇒ keep dynamic dispatch.
  pub fn toK(t: Ty) ?K {
    const scalar: K = switch (t.elem) {
      .b => .b, .i => .i, .f => .f, .s => .s, .c => .c,
      .dict => return .m,
      .table => return .M,
      .fn_ => return .o,
      .bottom, .unknown => return null,
    };
    return switch (t.rank) {
      0 => scalar,
      1 => containerOf(scalar),
      else => null, // nested or unknown rank → no single K
    };
  }

  /// Seed an inferred type from a concrete runtime value's class. `length` is the
  /// known array length when available (lets vectors carry a `Dim.known`).
  pub fn fromK(k: K, length: ?u32) Ty {
    return switch (k) {
      .b => atom(.b),
      .i => atom(.i),
      .f => atom(.f),
      .s => atom(.s),
      .c => atom(.c),
      .B => vector(.b, length),
      .I => vector(.i, length),
      .F => vector(.f, length),
      .S => vector(.s, length),
      .C => vector(.c, length),
      .o, .p => .{ .elem = .fn_, .rank = 0 },
      .m => .{ .elem = .dict, .rank = 0 },
      .M => .{ .elem = .table, .rank = 0 },
      // Heterogeneous list: we know it is a rank-1 container, but not its element.
      .L => .{ .elem = .unknown, .rank = 1 },
      .blank, .err, .x => TOP,
    };
  }

  /// Componentwise lattice join (least upper bound).
  pub fn join(a: Ty, b: Ty) Ty {
    if (a.isBottom()) return b;
    if (b.isBottom()) return a;
    const e = joinElem(a.elem, b.elem);
    const r = if (a.rank == b.rank) a.rank else RANK_TOP;
    var t: Ty = .{ .elem = e, .rank = r };
    if (r != RANK_TOP and r != 0) {
      for (0..@min(r, MAX_RANK)) |i| t.shape[i] = a.shape[i].join(b.shape[i]);
    }
    return t;
  }
};

fn joinElem(a: Elem, b: Elem) Elem {
  if (a == b) return a;
  if (a == .bottom) return b;
  if (b == .bottom) return a;
  // Numeric cast lattice: b ⊏ i ⊏ f. join picks the wider numeric type.
  if (a.numRank()) |ra| {
    if (b.numRank()) |rb| return Elem.fromNumRank(@max(ra, rb));
  }
  return .unknown;
}

/// Runtime (non-comptime) version of `K.container` for scalar kinds.
fn containerOf(k: K) K {
  return @enumFromInt(@intFromEnum(k) | K.VEC_BIT);
}

// ─── tests ────────────────────────────────────────────────────────────────────

test "toK round-trips concrete classes" {
  try std.testing.expectEqual(@as(?K, .i), Ty.fromK(.i, null).toK());
  try std.testing.expectEqual(@as(?K, .I), Ty.fromK(.I, 3).toK());
  try std.testing.expectEqual(@as(?K, .F), Ty.fromK(.F, null).toK());
  try std.testing.expectEqual(@as(?K, .m), Ty.fromK(.m, null).toK());
  // Heterogeneous list has no precise K.
  try std.testing.expectEqual(@as(?K, null), Ty.fromK(.L, null).toK());
  try std.testing.expectEqual(@as(?K, null), Ty.TOP.toK());
}

test "join follows the numeric cast lattice" {
  // i ⊔ f = f, both scalars.
  try std.testing.expectEqual(@as(?K, .f), Ty.atom(.i).join(Ty.atom(.f)).toK());
  // b ⊔ i = i.
  try std.testing.expectEqual(@as(?K, .i), Ty.atom(.b).join(Ty.atom(.i)).toK());
  // scalar ⊔ vector ⇒ rank disagreement ⇒ no precise K.
  try std.testing.expectEqual(@as(?K, null), Ty.atom(.i).join(Ty.vector(.i, null)).toK());
  // incompatible elements ⇒ ⊤ element.
  try std.testing.expectEqual(@as(?K, null), Ty.atom(.i).join(Ty.atom(.s)).toK());
  // bottom is the identity.
  try std.testing.expectEqual(@as(?K, .f), Ty.BOTTOM.join(Ty.atom(.f)).toK());
}

test "vector join keeps a matching known length but drops a mismatch" {
  const a = Ty.vector(.f, 4);
  const b = Ty.vector(.f, 4);
  try std.testing.expect(a.join(b).shape[0].eql(.{ .known = 4 }));
  const c = Ty.vector(.f, 2);
  try std.testing.expect(a.join(c).shape[0] == .unknown);
}
