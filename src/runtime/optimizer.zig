const std = @import("std");
const ir = @import("ir.zig");
const value = @import("../noun/value.zig");
const chunk = @import("tape.zig");
const V = value.V;
const Op = chunk.Op;
const OpCode = chunk.OpCode;

// 256-bit set for local variable indices (max 256 locals per lambda).
const LocalSet = struct {
  bits: [4]u64 = .{0, 0, 0, 0},

  pub fn set(s: *LocalSet, i: u8) void {
    s.bits[i >> 6] |= @as(u64, 1) << @as(u6, @truncate(i));
  }
  pub fn clear(s: *LocalSet, i: u8) void {
    s.bits[i >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(i)));
  }
  pub fn has(s: LocalSet, i: u8) bool {
    return (s.bits[i >> 6] >> @as(u6, @truncate(i))) & 1 != 0;
  }
  pub fn unionWith(s: *LocalSet, o: LocalSet) void {
    for (0..4) |j| s.bits[j] |= o.bits[j];
  }
  pub fn eql(a: LocalSet, b: LocalSet) bool {
    for (0..4) |j| if (a.bits[j] != b.bits[j]) return false;
    return true;
  }
  // Elements in a but not in b.
  pub fn diff(a: LocalSet, b: LocalSet) LocalSet {
    var r = a;
    for (0..4) |j| r.bits[j] &= ~b.bits[j];
    return r;
  }
};

const BB = struct {
  start:   u32,
  end:     u32,   // exclusive (first instruction of next BB or n)
  succ:    [2]u32 = .{0, 0},
  n_succ:  u8     = 0,
  gen:     LocalSet = .{},
  kill:    LocalSet = .{},
  livein:  LocalSet = .{},
  liveout: LocalSet = .{},
};

pub const Optimizer = struct {
  alloc: std.mem.Allocator,

  pub fn init(alloc: std.mem.Allocator) Optimizer {
    return .{ .alloc = alloc };
  }

  pub fn optimize(self: *Optimizer, scope_ir: *ir.IR, root_id: ir.ValueId) !void {
    var changed = true;
    var iter: usize = 0;
    // this looks suspicious, we justy loop 10 times and call optimize
    while (changed and iter < 10) : (iter += 1) {
      changed = false;
      if (try self.constantFolding(scope_ir)) changed = true;
      if (try self.dce(scope_ir, root_id)) changed = true;
    }
  }

  fn constantFolding(self: *Optimizer, scope_ir: *ir.IR) !bool {
    var changed = false;
    for (scope_ir.instructions.items) |*inst| {
      if (inst.is_dead) continue;

      if (inst.op == .Apply1 and inst.inputs.len > 0) {
        if (inst.inputs[0] == ir.NO_VALUE) continue;
        const input = scope_ir.get(inst.inputs[0]);
        if (input.op == .Const) {
          const op = @as(Op, @enumFromInt(inst.arg1));
          if (try self.foldMonad(op, input.val.?)) |res| {
            if (inst.val) |v| v.deinit(self.alloc);
            self.alloc.free(inst.inputs);
            inst.op = .Const;
            inst.val = res;
            inst.inputs = &.{};
            inst.is_pure = true;
            changed = true;
          }
        }
      }

      if (inst.op == .Apply2 and inst.inputs.len > 1) {
        if (inst.inputs[0] == ir.NO_VALUE or inst.inputs[1] == ir.NO_VALUE) continue;
        const left = scope_ir.get(inst.inputs[0]);
        const right = scope_ir.get(inst.inputs[1]);
        if (left.op == .Const and right.op == .Const) {
          const op = @as(Op, @enumFromInt(inst.arg1));
          if (try self.foldDyad(op, left.val.?, right.val.?)) |res| {
            if (inst.val) |v| v.deinit(self.alloc);
            self.alloc.free(inst.inputs);
            inst.op = .Const;
            inst.val = res;
            inst.inputs = &.{};
            inst.is_pure = true;
            changed = true;
          }
        }
      }
    }
    return changed;
  }

  fn foldMonad(self: *Optimizer, op: Op, x: V) !?V {
    _ = self;
    if (x == .i) {
      return switch (op) {
        .@"+" => x.ref(),
        .@"-" => V{ .i = 0 -% x.i },
        .@"~" => V{ .b = (x.i == 0) },
        else => null,
      };
    }
    return null;
  }

  fn foldDyad(self: *Optimizer, op: Op, x: V, y: V) !?V {
    _ = self;
    if (x == .i and y == .i) {
      const xv = x.i;
      const yv = y.i;
      return switch (op) {
        .@"+" => V{ .i = xv +% yv },
        .@"-" => V{ .i = xv -% yv },
        .@"*" => V{ .i = xv *% yv },
        .@"=" => V{ .b = xv == yv },
        .@"~" => V{ .b = xv == yv },
        else => null,
      };
    }
    return null;
  }

  fn dce(self: *Optimizer, scope_ir: *ir.IR, root_id: ir.ValueId) !bool {
    var changed = false;
    const insts = scope_ir.instructions.items;
    const used = try self.alloc.alloc(bool, insts.len);
    defer self.alloc.free(used);
    @memset(used, false);
    
    if (root_id != ir.NO_VALUE) used[root_id] = true;

    var i = insts.len;
    while (i > 0) {
      i -= 1;
      const idx = i;
      const inst = insts[idx];
      
      if (inst.is_dead) continue;

      if (!inst.is_pure or used[idx]) {
        var k: usize = 0;
        while (k < inst.inputs.len) : (k += 1) {
          if (inst.inputs[k] != ir.NO_VALUE) {
            used[inst.inputs[k]] = true;
          }
        }
      } else {
        scope_ir.instructions.items[idx].is_dead = true;
        changed = true;
      }
    }
    return changed;
  }

  pub fn liftInvariants(self: *Optimizer, lambda: *value.LambdaEntry, outer_ir: *ir.IR) !bool {
    _ = self; _ = lambda; _ = outer_ir;
    return false;
  }

  // Mark the final use of each local variable with is_last=true so the
  // lowering pass can emit LocalLast (steal-without-ref) instead of Local.
  // Uses classic backward-dataflow liveness analysis over the IR's CFG.
  pub fn livenessLocals(self: *Optimizer, scope_ir: *ir.IR) !void {
    const insts = scope_ir.instructions.items;
    const n = insts.len;
    if (n == 0) return;

    // ── 1. find basic-block leaders ───────────────────────────────────
    const leaders = try self.alloc.alloc(bool, n);
    defer self.alloc.free(leaders);
    @memset(leaders, false);
    leaders[0] = true;
    for (insts, 0..) |inst, i| {
      if (inst.is_dead) continue;
      switch (inst.op) {
        .Jump, .JumpFalse, .JumpTrue => {
          const t = inst.arg1;
          if (t < n) leaders[t] = true;
          if (i + 1 < n) leaders[i + 1] = true;
        },
        else => {},
      }
    }

    // ── 2. build BBs ──────────────────────────────────────────────────
    var bbs: std.ArrayList(BB) = .empty;
    defer bbs.deinit(self.alloc);
    const bb_of = try self.alloc.alloc(u32, n);
    defer self.alloc.free(bb_of);
    {
      var s: u32 = 0;
      for (1..n + 1) |i| {
        if (i == n or leaders[i]) {
          const id: u32 = @intCast(bbs.items.len);
          for (s..@as(u32, @intCast(i))) |j| bb_of[j] = id;
          try bbs.append(self.alloc, .{ .start = s, .end = @intCast(i) });
          s = @intCast(i);
        }
      }
    }
    const nb = bbs.items.len;

    // ── 3. successor edges ────────────────────────────────────────────
    for (bbs.items, 0..) |*bb, bi| {
      // Walk backward to find last live instruction in the BB.
      var last_op = OpCode.Nop;
      var last_arg: u32 = 0;
      {
        var j = bb.end;
        while (j > bb.start) {
          j -= 1;
          if (!insts[j].is_dead) { last_op = insts[j].op; last_arg = insts[j].arg1; break; }
        }
      }
      switch (last_op) {
        .Return => {},
        .Jump => {
          if (last_arg < n) { bb.succ[0] = bb_of[last_arg]; bb.n_succ = 1; }
        },
        .JumpFalse, .JumpTrue => {
          if (last_arg < n) { bb.succ[0] = bb_of[last_arg]; bb.n_succ = 1; }
          if (bi + 1 < nb) { bb.succ[bb.n_succ] = @intCast(bi + 1); bb.n_succ += 1; }
        },
        else => {
          if (bi + 1 < nb) { bb.succ[0] = @intCast(bi + 1); bb.n_succ = 1; }
        },
      }
    }

    // ── 4. gen / kill per BB ──────────────────────────────────────────
    for (bbs.items) |*bb| {
      for (bb.start..bb.end) |i| {
        const inst = insts[i];
        if (inst.is_dead) continue;
        switch (inst.op) {
          .Local => {
            const idx: u8 = @intCast(inst.arg1);
            if (!bb.kill.has(idx)) bb.gen.set(idx);
          },
          .AssignLocal => bb.kill.set(@intCast(inst.arg1)),
          // Nop with arg3=1 carries a local index from ListAssignLocal.
          .Nop => if (inst.arg3 == 1) bb.kill.set(@intCast(inst.arg1)),
          else => {},
        }
      }
    }

    // ── 5. backward dataflow to fixed point ───────────────────────────
    var changed = true;
    while (changed) {
      changed = false;
      var bi = nb;
      while (bi > 0) {
        bi -= 1;
        const bb = &bbs.items[bi];
        var new_lo = LocalSet{};
        for (0..bb.n_succ) |si| new_lo.unionWith(bbs.items[bb.succ[si]].livein);
        var new_li = bb.gen;
        new_li.unionWith(new_lo.diff(bb.kill));
        if (!new_lo.eql(bb.liveout) or !new_li.eql(bb.livein)) {
          bb.liveout = new_lo;
          bb.livein  = new_li;
          changed = true;
        }
      }
    }

    // ── 6. mark last uses within each BB ─────────────────────────────
    for (bbs.items) |*bb| {
      var live = bb.liveout;
      var i = bb.end;
      while (i > bb.start) {
        i -= 1;
        const inst = &scope_ir.instructions.items[i];
        if (inst.is_dead) continue;
        switch (inst.op) {
          .AssignLocal => live.clear(@intCast(inst.arg1)),
          .Nop         => if (inst.arg3 == 1) live.clear(@intCast(inst.arg1)),
          .Local       => {
            const idx: u8 = @intCast(inst.arg1);
            if (!live.has(idx)) inst.is_last = true;
            live.set(idx);
          },
          else => {},
        }
      }
    }
  }
};
