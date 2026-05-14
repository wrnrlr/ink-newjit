const std = @import("std");
const V = @import("../noun/value.zig").V;
const ArrayFlags = @import("../noun/array.zig").ArrayFlags;
const OpCode = @import("tape.zig").OpCode;

pub const ValueId = u32;
pub const NO_VALUE: ValueId = 0xffffffff;

pub const IRInst = struct {
  op: OpCode,
  arg1: u32 = 0,
  arg2: u32 = 0,
  arg3: u32 = 0,
  val: ?V = null,
  inputs: []const ValueId = &.{},
  is_dead: bool = false,
  is_pure: bool = false,
  is_last: bool = false,      // last use of this local variable slot
  cache_slot: ?u8 = null,     // set by liftInvariants: temp local slot for cached global

  pub fn deinit(self: IRInst, alloc: std.mem.Allocator) void {
    if (self.val) |v| v.deinit(alloc);
    if (self.inputs.len > 0) alloc.free(self.inputs);
  }

  pub fn isEffectful(self: IRInst) bool {
    if (self.op == .Nop and self.arg3 == 1) return true;
    return switch (self.op) {
      .AssignGlobal, .AssignLocal, .ListAssignGlobal, .ListAssignLocal,
      .Return, .Amend, .Dmend, .Call, .TailCall, .Drop,
      .Jump, .JumpFalse, .JumpTrue, .Command => true,
      else => false,
    };
  }
};

pub const IR = struct {
  instructions: std.ArrayList(IRInst),
  alloc: std.mem.Allocator,
  extra_locals: u8 = 0,  // slots allocated by liftInvariants; added to lambda.locals

  pub fn init(alloc: std.mem.Allocator) !IR {
    return .{
      .instructions = try std.ArrayList(IRInst).initCapacity(alloc, 0),
      .alloc = alloc,
    };
  }

  pub fn deinit(self: *IR) void {
    for (self.instructions.items) |inst| {
      inst.deinit(self.alloc);
    }
    self.instructions.deinit(self.alloc);
  }

  pub fn emit(self: *IR, op: OpCode, inputs: []const ValueId) !ValueId {
    const id = @as(u32, @intCast(self.instructions.items.len));
    const inputs_copy = try self.alloc.dupe(ValueId, inputs);
    var inst = IRInst{ 
      .op = op, 
      .inputs = inputs_copy,
      .is_pure = false,
    };
    inst.is_pure = !inst.isEffectful();
    try self.instructions.append(self.alloc, inst);
    return id;
  }

  pub fn emitWithArg(self: *IR, op: OpCode, arg: u32, inputs: []const ValueId) !ValueId {
    const id = @as(u32, @intCast(self.instructions.items.len));
    const inputs_copy = try self.alloc.dupe(ValueId, inputs);
    var inst = IRInst{ 
      .op = op, 
      .arg1 = arg, 
      .inputs = inputs_copy,
      .is_pure = false,
    };
    inst.is_pure = !inst.isEffectful();
    try self.instructions.append(self.alloc, inst);
    return id;
  }

  pub fn emitConstant(self: *IR, val: V) !ValueId {
    const id = @as(u32, @intCast(self.instructions.items.len));
    const stored = val.ref();
    // Mark array constants immutable so cow() always copies them.
    switch (stored) {
      inline .B, .I, .F, .S, .C, .L => |n| n.setFlag(ArrayFlags.immutable),
      inline .m, .M => |d| { d.ptr.flags |= ArrayFlags.immutable; },
      else => {},
    }
    try self.instructions.append(self.alloc, .{
      .op = .Const,
      .val = stored,
      .inputs = &.{},
      .is_pure = true,
    });
    return id;
  }

  pub fn get(self: *IR, id: ValueId) *IRInst {
    return &self.instructions.items[id];
  }

  pub fn markEffectful(self: *IR, id: ValueId) void {
    self.instructions.items[id].is_pure = false;
  }

  pub fn reset(self: *IR) void {
    for (self.instructions.items) |inst| {
      inst.deinit(self.alloc);
    }
    self.instructions.clearRetainingCapacity();
  }
};
