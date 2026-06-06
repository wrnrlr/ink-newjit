const std = @import("std");
const util = @import("../util.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Value = @import("../noun/value.zig").V;

pub const OpCode = enum(u8) {
  Nop, Gap, Drop, Dup,
	Const, Int,                // Int: inline i16 value (avoids constant pool for small integers)
	Global, Local, LocalLast,  // LocalLast: last use — steals slot without ref increment
	AssignGlobal, AssignLocal, ListAssignGlobal, ListAssignLocal,
	Jump, JumpFalse, JumpTrue,
	Apply1, Apply2,
	ReduceZip,               // fused reduce-of-zip: 2 op bytes (Op1 reduce, Op2 bin); pops 2 args
	Apply3,                  // 1-byte Op3 (amend3/drill3); pops 3 args from stack
	Apply4,                  // 1-byte Op4 (amend4/drill4); pops 4 args from stack
	Return,                  // return
	Call,                    // call a lambda
	TailCall,                // tail call a lambda
	Apply,                   // apply with brackets
	MakeList,                // make a list from count items on stack
	MakePartial,             // pops func + n args, pushes partial
	Derive,                  // derive verb from variadic (adverb) and top value
	Command,                 // meta command (\h \l \d \t \v \f \cd)

	pub const COUNT = @typeInfo(OpCode).@"enum".fields.len;
};

pub const BasicBlock = struct {
  start:  u32,
  end:    u32,     // exclusive — first byte of the next BB (or code.len)
  succ:   [2]u32,
  n_succ: u8,
};

pub const Chunk = struct {
  alloc: Allocator,
  code: ArrayList(u8),
  constants: ArrayList(Value),
  blocks: std.ArrayListUnmanaged(BasicBlock) = .empty,

  pub fn init(alloc: Allocator) !Chunk {
    return .{
      .alloc = alloc,
      .code = try ArrayList(u8).initCapacity(alloc, 0),
      .constants = try ArrayList(Value).initCapacity(alloc, 0),
    };
  }

  pub fn deinit(self: *Chunk) void {
    for (self.constants.items) |*v| v.deinit(self.alloc);
    self.code.deinit(self.alloc);
    self.constants.deinit(self.alloc);
    self.blocks.deinit(self.alloc);
  }

  // Scan bytecode and populate self.blocks with basic block boundaries.
  // Must be called after the bytecode is fully emitted (i.e. after lower()).
  pub fn buildBlocks(self: *Chunk) !void {
    const code = self.code.items;
    const n = code.len;
    self.blocks.clearRetainingCapacity();
    if (n == 0) return;

    const leaders = try self.alloc.alloc(bool, n);
    defer self.alloc.free(leaders);
    @memset(leaders, false);
    leaders[0] = true;

    // First pass: identify leaders.
    var ip: usize = 0;
    while (ip < n) {
      const op: OpCode = @enumFromInt(code[ip]);
      const size = instrSize(code, ip);
      switch (op) {
        .Jump, .JumpFalse, .JumpTrue => {
          const off = @as(u16, code[ip + 1]) | (@as(u16, code[ip + 2]) << 8);
          const target: usize = ip + 3 + off;
          if (target < n) leaders[target] = true;
          if (ip + size < n) leaders[ip + size] = true;
        },
        .Return => {
          if (ip + size < n) leaders[ip + size] = true;
        },
        else => {},
      }
      ip += size;
    }

    // Second pass: collect BBs and compute successors.
    var start: u32 = 0;
    ip = 0;
    var prev_end: ?u32 = null;
    var prev_op: OpCode = .Nop;
    var prev_off: u16 = 0;

    while (ip <= n) {
      const is_leader = ip == n or leaders[ip];
      if (is_leader and ip > 0) {
        const end: u32 = @intCast(ip);
        var bb: BasicBlock = .{ .start = start, .end = end, .succ = .{end, 0}, .n_succ = 0 };
        switch (prev_op) {
          .Return => {},
          .Jump => {
            const target: u32 = prev_end.? + prev_off;
            bb.succ[0] = target;
            bb.n_succ = 1;
          },
          .JumpFalse, .JumpTrue => {
            const target: u32 = prev_end.? + prev_off;
            bb.succ[0] = target;
            bb.succ[1] = end;
            bb.n_succ = 2;
          },
          else => {
            bb.succ[0] = end;
            bb.n_succ = if (end < n) 1 else 0;
          },
        }
        try self.blocks.append(self.alloc, bb);
        start = end;
      }
      if (ip == n) break;
      const op: OpCode = @enumFromInt(code[ip]);
      const size = instrSize(code, ip);
      if (op == .Jump or op == .JumpFalse or op == .JumpTrue) {
        prev_off = @as(u16, code[ip + 1]) | (@as(u16, code[ip + 2]) << 8);
        prev_end = @intCast(ip + size);
      } else {
        prev_off = 0;
        prev_end = @intCast(ip + size);
      }
      prev_op = op;
      ip += size;
    }
  }

  // Returns the size in bytes of the instruction starting at `ip`.
  pub fn instrSize(code: []const u8, ip: usize) usize {
    const op: OpCode = @enumFromInt(code[ip]);
    return switch (op) {
      .Nop, .Gap, .Drop, .Return, .Command => 1,
      .Int, .Jump, .JumpFalse, .JumpTrue, .MakePartial, .ReduceZip => 3,
      .ListAssignGlobal, .ListAssignLocal => 2 + code[ip + 1],
      else => 2,
    };
  }

  pub fn write(self: *Chunk, byte: u8) !void {
    try self.code.append(self.alloc, byte);
  }

  pub fn writeOp(self: *Chunk, op: OpCode) !void {
    try self.write(@intFromEnum(op));
  }

  pub fn write16(self: *Chunk, val: u16) !void {
    try self.write(@as(u8, @intCast(val & 0xff)));
    try self.write(@as(u8, @intCast((val >> 8) & 0xff)));
  }

  pub fn writeAt(self: *Chunk, idx: usize, byte: u8) void {
    self.code.items[idx] = byte;
  }

  pub fn addConstant(self: *Chunk, value: Value) !u8 {
    const index = @as(u8, @intCast(self.constants.items.len));
    try self.constants.append(self.alloc, value);
    return index;
  }
};
