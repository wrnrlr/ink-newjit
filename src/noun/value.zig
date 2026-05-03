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

pub const LambdaEntry = struct {
  arity:  u8,
  locals: u8,
  chunk:  *Chunk,
  range:  u32,
};

pub const DerivedEntry = struct {
  base:   V,
  adverb: Adverb,
};

pub const FnTables = struct {
  alloc:   Alloc,
  lambdas: std.ArrayList(LambdaEntry) = .empty,
  derived: std.ArrayList(DerivedEntry) = .empty,

  pub fn init(alloc: Alloc) FnTables {
    return .{ .alloc = alloc };
  }

  pub fn deinit(self: *FnTables) void {
    for (self.lambdas.items) |e| { e.chunk.deinit(); self.alloc.destroy(e.chunk); }
    self.lambdas.deinit(self.alloc);
    for (self.derived.items) |e| e.base.deinit(self.alloc);
    self.derived.deinit(self.alloc);
  }

  pub fn addLambda(self: *FnTables, entry: LambdaEntry) !u24 {
    const idx = self.lambdas.items.len;
    try self.lambdas.append(self.alloc, entry);
    return @intCast(idx);
  }

  pub fn addDerived(self: *FnTables, entry: DerivedEntry) !u24 {
    const idx = self.derived.items.len;
    try self.derived.append(self.alloc, entry);
    return @intCast(idx);
  }

  pub fn lambdaAt(self: *const FnTables, idx: u24) LambdaEntry { return self.lambdas.items[idx]; }
  pub fn derivedAt(self: *const FnTables, idx: u24) DerivedEntry { return self.derived.items[idx]; }
};

pub const Partial = struct {
  // *anyopaque to avoid a circular type reference: Partial → MemoryPool(Partial) → Partial.
  // Stored as opaque, cast back to *std.heap.MemoryPool(Partial) in deinit.
  pool:  *anyopaque,
  rc:    u32,
  fill:  u8,   // bitmask: bit i set → args[i] is filled
  arity: u8,   // original function arity
  _pad:  u16,
  ref:   Fn,
  args:  [8]V, // .blank = unfilled slot

  pub fn deinit(p: *Partial, alloc: Alloc) void {
    p.rc -= 1;
    if (p.rc == 0) {
      for (0..8) |i| if (p.fill & (@as(u8, 1) << @intCast(i)) != 0) p.args[i].deinit(alloc);
      const Pool = std.heap.MemoryPool(Partial);
      @as(*Pool, @ptrCast(@alignCast(p.pool))).destroy(p);
    }
  }

  pub fn filledCount(p: *const Partial) u8 { return @popCount(p.fill); }
  pub fn remaining(p: *const Partial) u8 { return p.arity - p.filledCount(); }
  pub fn isFull(p: *const Partial) bool { return p.filledCount() >= p.arity; }

  pub fn filledSlice(p: *const Partial) []const V { return p.args[0..p.arity]; }
};

pub const Err = enum { domain, length, rank, nyi, memory, @"type", io };

pub const Adverb = enum(u8) {
  @"'", @"/", @"\\", @"':", @"/:", @"\\:"
};

pub const V = union(K) {
  // Field order must match K enum declaration order exactly.
  blank, err: Err,
  b: bool, i: i32, f: f32, s: u32, c: u8,
  func: Fn,          // inline 8-byte, no alloc, no RC
  partial: *Partial, // heap, RC inside Partial
  L: N(V), m: Dict, M: Dict,
  x: *ExtObj,        // heap, RC inside ExtObj
  B: N(bool), I: N(i32), F: N(f32), S: N(u32), C: N(u8),

  pub const @"0N" = std.math.minInt(i32);

  pub inline fn wrap(comptime k: K, v: holder(k)) V { return @unionInit(V, @tagName(k), v); }
  pub inline fn unwrap(v: V, comptime k: K) holder(k) { return @field(v, @tagName(k)); }
  fn holder(comptime k: K) type {
    return switch (k) {
      .blank => void,
      .b => bool, .B => N(bool),
      .i => i32, .I => N(i32),
      .f => f32, .F => N(f32),
      .s => u32, .S => N(u32),
      .c => u8, .C => N(u8),
      .m, .M => Dict,
      .L => V,
      else => @compileError("no backing type for " ++ @tagName(k)),
    };
  }
  
  pub fn ref(v: V) V {
    switch (v) {
      inline .I => |n| { if (n.ptr.rc != std.math.maxInt(u32)) n.ptr.rc += 1; },
      inline .B, .F, .S, .C, .L => |n| n.ptr.rc += 1,
      inline .m, .M => |n| n.ptr.rc += 1,
      .partial => |p| p.rc += 1,
      .x => |obj| { _ = obj.ref(); },
      else => {},
    }
    return v;
  }

  pub fn deinit(v: V, alloc: Alloc) void {
    switch (v) {
      inline .B, .I, .F, .S, .C, .L, .m, .M => |n| n.deinit(alloc),
      .partial => |p| p.deinit(alloc),
      .x => |obj| obj.deinit(alloc),
      else => {},
    }
  }

  pub fn cow(v: *V, alloc: Alloc) !void {
    switch (v.*) {
      inline .B, .I, .F, .S, .C, .L, .m, .M => |n, t| {
        if (n.ptr.rc > 1 or n.ptr.flags & ArrayFlags.immutable != 0) {
          const next = try n.clone(alloc);
          n.deinit(alloc);
          v.* = @unionInit(V, @tagName(t), next);
        }
      },
      else => {},
    }
  }

  pub fn len(v: V) usize {
    return switch (v) {
      inline .B, .I, .F, .S, .C, .L => |n| n.ptr.len,
      inline .m => |n| n.ptr.len,
      inline .M => |n| {
        const bv = n.bv();
        if (bv.tag() == .L) {
          const slice = bv.L.slice();
          if (slice.len == 0) return 0;
          return slice[0].len();
        }
        return bv.len();
      },
      else => 1,
    };
  }

  pub fn eq(x: V, y: V) bool {
    const t = activeTag(x);
    if (t != activeTag(y)) return false;
    return switch (x) {
      .blank => true, .err => x.err == y.err,
      .b => x.b == y.b, .i => x.i == y.i, .f => x.f == y.f,
      .s => x.s == y.s, .c => x.c == y.c,
      .func => @as(u64, @bitCast(x.func)) == @as(u64, @bitCast(y.func)),
      .partial => x.partial == y.partial, // pointer equality
      .x => x.x == y.x,                  // pointer equality
      inline else => |n| {
        const T = @TypeOf(n);
        inline for (std.meta.fields(V)) |f| {
          if (f.type == T) {
            if (t == @field(K, f.name)) return n.eq(@field(y, f.name));
          }
        }
        return false;
      },
    };
  }

  pub fn at(v: V, i: usize) V {
    return switch (v) {
      .B => |n| .{ .b = n.slice()[i] }, .I => |n| .{ .i = n.slice()[i] }, .F => |n| .{ .f = n.slice()[i] },
      .S => |n| .{ .s = n.slice()[i] }, .C => |n| .{ .c = n.slice()[i] },
      .L => |n| n.slice()[i].ref(),
      inline .m, .M => |n| n.bv().at(i),
      else => v.ref(),
    };
  }

  pub fn arity(v: V) u8 {
    return switch (v) {
      .func => |r| r.getRealArity(),
      .partial => |p| p.remaining(),
      .blank => 0,
      else => 1,
    };
  }

  pub fn isNull(v: V) bool {
    return switch (v) {
      .blank => false,
      inline .b, .i, .f, .s, .c => |a, kt| kt.isNullFn()(a),
      inline .B, .I, .F, .S, .C, .L => |n| n.ptr.len == 0,
      inline .m, .M => |n| n.ptr.len == 0,
      else => false,
    };
  }

  pub fn isTrue(v: V) bool {
    return switch (v) {
      .b => |a| a,
      .c => |a| a != 0, .s => |a| a != 0,
      .i => |a| a != 0 and a != @"0N", .f => |a| a != 0.0 and !std.math.isNan(a),
      inline .B, .I, .F, .S, .C, .L => |n| n.ptr.len > 0,
      inline .m, .M => |n| n.ptr.len > 0,
      .func, .partial => true,
      else => false,
    };
  }

  pub fn rc(v: V) usize {
    return switch (v) {
      inline .B, .I, .F, .S, .C, .L => |n| n.ptr.rc,
      inline .m, .M => |n| n.ptr.rc,
      .partial => |p| p.rc,
      .x => |obj| obj.rc,
      else => 1,
    };
  }

  pub inline fn tag(v: V) K { return activeTag(v); }
  pub inline fn code(v: V) usize { return v.tag().code(); }
  pub fn isAtom(v: V) bool { return v.tag().isAtom(); }
  pub fn isVec(v: V) bool { return v.tag().isVec(); }
  pub fn isDict(v: V) bool { return switch (v.tag()) { .m, .M => true, else => false }; }

  pub fn isLambda(v: V) bool { return v == .func and v.func.getKind() == .lambda; }
  pub fn isPartial(v: V) bool { return v == .partial; }
  pub fn asPartial(v: V) *Partial { return v.partial; }

  pub fn intsFromSlice(alloc: Alloc, x: []const i32) !V { return .{ .I = try N(i32).n1(alloc, x) }; }
  pub fn floatsFromSlice(alloc: Alloc, x: []const f32) !V { return .{ .F = try N(f32).n1(alloc, x) }; }
  pub fn symbolsFromSlice(alloc: Alloc, x: []const u32) !V { return .{ .S = try N(u32).n1(alloc, x) }; }
  pub fn valuesFromSlice(alloc: Alloc, x: []const V) !V { return .{ .L = try N(V).n1(alloc, x) }; }
  pub fn charsFromSlice(alloc: Alloc, x: []const u8) !V { return .{ .C = try N(u8).n1(alloc, x) }; }
  pub fn make(comptime kk: K, comptime T: type, alloc: Alloc, vals: []const T) !V {
    return @unionInit(V, @tagName(kk), try N(T).n1(alloc, vals));
  }
};

const gpu = @import("gpu");
pub const Loc = gpu.Loc;
pub const GpuCtx = gpu.GpuCtx;
pub const GpuRange = gpu.GpuRange;

// Storage header.
//   loc=cpu: inline data follows at data_offset.
//   loc=gpu: a GpuMeta block (GpuRange + *GpuCtx) follows at @sizeOf(Rc);
//            actual data lives in the ctx's wgpu arena.
// Header is 16 bytes (was 8) — +8 bytes per allocation, accepted for
// uniformity. ctx lives in GpuMeta so CPU storage doesn't carry it.
pub const GpuMeta = extern struct {
  range: GpuRange,
  ctx:   ?*GpuCtx,
};

pub const ArrayFlags = struct {
  pub const immutable: u8 = 1 << 0; // do not mutate in place even at rc=1
  pub const ascending: u8 = 1 << 1; // elements are sorted ascending
  pub const distinct:  u8 = 1 << 2; // no duplicate elements
  pub const boolean:   u8 = 1 << 3; // all values are 0 or 1
};

pub const Rc = extern struct {
  rc:    u32,
  len:   u32,
  loc:   u32   = @intFromEnum(Loc.cpu),
  flags: u8    = 0,
  _pad:  [3]u8 = .{0, 0, 0},
  pub fn data(r: *Rc, comptime T: type) [*]T {
    return @as([*]T, @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(r) + @sizeOf(Rc), @alignOf(T))));
  }
  pub fn isGpu(r: *const Rc) bool { return r.loc == @intFromEnum(Loc.gpu); }
  pub fn gpuMeta(r: *Rc) *GpuMeta {
    return @ptrFromInt(@intFromPtr(r) + @sizeOf(Rc));
  }
};

fn allocRc(alloc: Alloc, comptime T: type, n: usize) !*Rc {
  const header_size = std.mem.alignForward(usize, @sizeOf(Rc), @alignOf(T));
  const raw = try alloc.alloc(u8, header_size + (n * @sizeOf(T)));
  const h = @as(*Rc, @ptrCast(@alignCast(raw.ptr)));
  h.* = .{ .rc = 1, .len = @intCast(n) };
  return h;
}

fn freeRc(alloc: Alloc, r: *Rc, comptime T: type, n: usize) void {
  const header_size = std.mem.alignForward(usize, @sizeOf(Rc), @alignOf(T));
  alloc.free(@as([*]u8, @ptrCast(r))[0..header_size + (n * @sizeOf(T))]);
}

pub const Dict = struct {
  ptr: *Rc,
  pub fn init(alloc: Alloc, keys: V, vals: V) !Dict {
    const p = try allocRc(alloc, V, 2); p.len = @intCast(keys.len());
    p.data(V)[0] = keys; p.data(V)[1] = vals;
    return .{ .ptr = p };
  }
  pub fn deinit(self: Dict, alloc: Alloc) void {
    self.ptr.rc -= 1; if (self.ptr.rc > 0) return;
    const d = self.ptr.data(V); d[0].deinit(alloc); d[1].deinit(alloc);
    freeRc(alloc, self.ptr, V, 2);
  }
  pub fn av(self: Dict) V { return self.ptr.data(V)[0]; }
  pub fn bv(self: Dict) V { return self.ptr.data(V)[1]; }
  pub fn avPtr(self: Dict) *V { return &self.ptr.data(V)[0]; }
  pub fn bvPtr(self: Dict) *V { return &self.ptr.data(V)[1]; }
  pub fn eq(self: Dict, other: Dict) bool { return self.av().eq(other.av()) and self.bv().eq(other.bv()); }
  pub fn clone(self: Dict, alloc: Alloc) !Dict { return try Dict.init(alloc, self.av().ref(), self.bv().ref()); }
};

pub fn N(comptime T: type) type {
  return struct {
    const Self = @This();
    pub const alignment = @max(@alignOf(Rc), @alignOf(T));
    pub const data_offset = std.mem.alignForward(usize, @sizeOf(Rc), @alignOf(T));
    const align_enum: std.mem.Alignment = @enumFromInt(@ctz(@as(usize, alignment)));

    ptr: *align(@alignOf(Rc)) Rc,

    pub fn init(alloc: Alloc, n: usize) !Self {
      const total = data_offset + n * @sizeOf(T);
      const buf = try alloc.alignedAlloc(u8, align_enum, total);
      const header: *align(@alignOf(Rc)) Rc = @ptrCast(buf.ptr);
      header.* = .{ .rc = 1, .len = @intCast(n) };
      if (comptime T == bool) header.flags = ArrayFlags.boolean;
      return .{ .ptr = header };
    }

    pub fn setFlag(a: Self, f: u8) void { a.ptr.flags |= f; }
    pub fn hasFlag(a: Self, f: u8) bool { return a.ptr.flags & f != 0; }
    // Allocate a GPU-resident header. The body is a GpuMeta (no inline
    // data); actual data lives in the ctx's wgpu arena.
    pub fn initGpu(ctx: *GpuCtx, range: GpuRange, n: usize) !Self {
      const total = @sizeOf(Rc) + @sizeOf(GpuMeta);
      const buf = try ctx.alloc.alignedAlloc(u8, align_enum, total);
      const header: *align(@alignOf(Rc)) Rc = @ptrCast(buf.ptr);
      header.* = .{ .rc = 1, .len = @intCast(n), .loc = @intFromEnum(Loc.gpu) };
      header.gpuMeta().* = .{ .range = range, .ctx = ctx };
      return .{ .ptr = header };
    }
    pub fn deinit(a: Self, alloc: Alloc) void {
      if (a.ptr.rc == std.math.maxInt(u32)) return;
      a.ptr.rc -= 1;
      if (a.ptr.rc != 0) return;
      if (a.ptr.isGpu()) {
        const meta = a.ptr.gpuMeta();
        const ctx = meta.ctx.?;
        ctx.free(meta.range, @intCast(a.ptr.len * @sizeOf(T)));
        const total = @sizeOf(Rc) + @sizeOf(GpuMeta);
        const base: [*]u8 = @ptrCast(a.ptr);
        const buf: []align(alignment) u8 = @as([*]align(alignment) u8, @alignCast(base))[0..total];
        ctx.alloc.free(buf);
        return;
      }
      if (T == V) for (a.slice()) |child| child.deinit(alloc);
      const total = data_offset + a.ptr.len * @sizeOf(T);
      const base: [*]u8 = @ptrCast(a.ptr);
      const buf: []align(alignment) u8 = @as([*]align(alignment) u8, @alignCast(base))[0..total];
      alloc.free(buf);
    }
    pub fn isGpu(a: Self) bool { return a.ptr.isGpu(); }
    pub fn gpuRange(a: Self) GpuRange {
      std.debug.assert(a.ptr.isGpu());
      return a.ptr.gpuMeta().range;
    }
    pub fn slice(a: Self) []T {
      std.debug.assert(!a.ptr.isGpu());
      const base: [*]u8 = @ptrCast(a.ptr);
      return @as([*]T, @ptrCast(@alignCast(base + data_offset)))[0..a.ptr.len];
    }
    pub fn eq(a: Self, b: Self) bool {
      if (a.ptr.len != b.ptr.len) return false;
      if (T == V) {
        for (a.slice(), b.slice()) |v1, v2| if (!v1.eq(v2)) return false; return true;
      }
      return std.mem.eql(T, a.slice(), b.slice());
    }
    pub fn clone(a: Self, alloc: Alloc) !Self {
      const next = try Self.init(alloc, a.ptr.len);
      if (T == V) {
        for (a.slice(), next.slice()) |src, *dst| dst.* = src.ref();
      } else @memcpy(next.slice(), a.slice());
      return next;
    }
    pub fn n1(alloc: Alloc, x: []const T) !Self {
      const n = try Self.init(alloc, x.len);
      if (T == V) { for (x, n.slice()) |src, *dst| dst.* = src.ref(); } else @memcpy(n.slice(), x);
      return n;
    }
    pub fn fromSlice(alloc: Alloc, x: []const T) !Self {
      const n = try Self.init(alloc, x.len);
      @memcpy(n.slice(), x);
      return n;
    }
    pub fn fromRange(alloc: Alloc, start: T, step: T, count: usize) !Self {
      const res = try Self.init(alloc, count);
      var cur = start;
      for (res.slice()) |*val| { val.* = cur; cur += step; }
      if (comptime (T == i32 or T == u32 or T == f32)) {
        if (count > 0 and step > @as(T, 0)) res.ptr.flags |= ArrayFlags.ascending;
      }
      return res;
    }
    pub fn zeros(alloc: Alloc, count: usize) !Self {
      const res = try Self.init(alloc, count);
      @memset(res.slice(), if (T == V) .blank else std.mem.zeroes(T));
      return res;
    }
  };
}

test "V size" { try std.testing.expect(@sizeOf(V) <= 16); }
test "FnRef size" { try std.testing.expect(@sizeOf(Fn) == 8); }

test "wrap" {
  try std.testing.expect(V.wrap(.b, true).b);
  try std.testing.expect(V.wrap(.i, 2).i == 2);
  try std.testing.expect(V.wrap(.f, 2.3).f == 2.3);
  try std.testing.expect(V.wrap(.c, 'A').c == 'A');
}

test "FnRef inline kinds" {
  const r1 = Fn.makeBuiltin(.@"+");
  try std.testing.expect(r1.getKind() == .builtin);
  try std.testing.expect(r1.getOp() == .@"+");
  try std.testing.expect(r1.arity == 2);

  const r2 = Fn.makeBuiltinMonad(.@"*");
  try std.testing.expect(r2.monad == 1);
  try std.testing.expect(r2.getRealArity() == 1);

  const r3 = Fn.makeDerivedBuiltin(.@"+", .@"/");
  try std.testing.expect(r3.getKind() == .derived_builtin);
  try std.testing.expect(r3.getAdverb() == .@"/");
}

test "atoms" {
  const v1 = V{ .i = 42 }; const v2 = V{ .f = 3.14 };
  try std.testing.expect(v1.eq(v1)); try std.testing.expect(!v1.eq(v2));
}

test "vectors" {
  const alloc = std.testing.allocator;
  const v1 = try N(i32).n1(alloc, &.{1, 2, 3}); defer v1.deinit(alloc);
  const v2 = try N(i32).n1(alloc, &.{1, 2, 3}); defer v2.deinit(alloc);
  try std.testing.expect((V{ .I = v1 }).eq(.{ .I = v2 }));
}

test "ref counting" {
  const alloc = std.testing.allocator;
  const v1 = try N(i32).n1(alloc, &.{1, 2, 3});
  const V1 = V{ .I = v1 };
  try std.testing.expectEqual(@as(usize, 1), V1.rc());
  _ = V1.ref();
  try std.testing.expectEqual(@as(usize, 2), V1.rc());
  V1.deinit(alloc);
  try std.testing.expectEqual(@as(usize, 1), V1.rc());
  V1.deinit(alloc);
}

test "gpu storage init/deinit" {
  const alloc = std.testing.allocator;
  var stub = gpu.StubBackend.init(alloc);
  const range = GpuRange{ .buf = @enumFromInt(7), .offset = 256 };
  const v = try N(i32).initGpu(&stub.ctx, range, 100);
  try std.testing.expect(v.isGpu());
  try std.testing.expectEqual(@as(usize, 100), v.ptr.len);
  try std.testing.expectEqual(@as(u32, 256), v.gpuRange().offset);
  v.deinit(alloc); // alloc is unused on the gpu path; ctx.alloc is what frees
}
