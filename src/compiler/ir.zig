const std = @import("std");
const V = @import("../noun/value.zig").V;
const ArrayFlags = @import("../noun/array.zig").ArrayFlags;
const tape = @import("../runtime/tape.zig");
const OpCode = tape.OpCode;
const KInsn = tape.KInsn;
const opmod = @import("../noun/operator.zig");
const Op1 = opmod.Op1;
const Op2 = opmod.Op2;

pub const ValueId = u32;
pub const NO_VALUE: ValueId = 0xffffffff;

pub const IRInst = struct {
  op: OpCode,
  arg1: u32 = 0,
  arg2: u32 = 0,
  arg3: u32 = 0,
  val: ?V = null,
  inputs: []const ValueId = &.{},
  kcode: ?[]KInsn = null,     // FusedMap postfix program (arg1=ncol, arg2=depth)
  is_dead: bool = false,
  is_pure: bool = false,
  is_last: bool = false,      // last use of this local variable slot

  pub fn deinit(self: IRInst, alloc: std.mem.Allocator) void {
    if (self.val) |v| v.deinit(alloc);
    if (self.inputs.len > 0) alloc.free(self.inputs);
    if (self.kcode) |c| alloc.free(c);
  }

  /// Can this instruction be deleted when nobody uses its result?
  ///
  /// This is an ALLOWLIST, and deliberately so. It used to be a blocklist of
  /// effectful opcodes with `else => false`, which fails OPEN: any opcode nobody
  /// thought about — `.Apply` among them — was assumed pure and silently deleted.
  /// That is what made `z: {[i] gpu.dispatch[…]}' !n` compile to nothing at all
  /// (the each lowers to Derive + .Apply, and `z` is unused), reporting
  /// sub-microsecond timings for work that never ran. Anything not listed here is
  /// treated as effectful, so a newly added opcode fails SAFE.
  ///
  /// `.Apply`/`.Call`/`.TailCall` are deliberately absent: the callee is a runtime
  /// value (lambda, train, FFI handle, adverb-derived verb) and we do not try to
  /// prove it pure. Discarding the result of a call almost always means the caller
  /// wanted its effect, so the conservative answer is also the intended one.
  pub fn isPure(self: IRInst) bool {
    if (self.op == .Nop and self.arg3 == 1) return false;   // effectful-marker Nop
    return switch (self.op) {
      // pure regardless of operands
      .Nop, .Gap, .Const, .Int, .Dup,
      .Global, .Local, .LocalLast,
      .MakeList, .MakePartial,
      // building a derived verb has no effect; APPLYING it goes through .Apply
      .Derive,
      // both are constructed only from pointwise arithmetic, so pure by construction
      .ReduceZip, .FusedMap => true,
      // purity is a property of the primitive being applied
      .Apply1 => self.arg1 < Op1.COUNT and
        @as(Op1, @enumFromInt(self.arg1)).purity() == .pure,
      .Apply2 => self.arg1 < Op2.COUNT and
        @as(Op2, @enumFromInt(self.arg1)).purity() == .pure,
      // Apply3/Apply4 are amend/drill/splice — they mutate
      .Apply3, .Apply4,
      .Apply, .Call, .TailCall,
      .AssignGlobal, .AssignLocal, .ListAssignGlobal, .ListAssignLocal,
      .Return, .Drop, .Jump, .JumpFalse, .JumpTrue, .Command => false,
    };
  }

  pub fn isEffectful(self: IRInst) bool { return !self.isPure(); }
};

pub const IR = struct {
  instructions: std.ArrayList(IRInst),
  alloc: std.mem.Allocator,

  pub fn init(alloc: std.mem.Allocator) IR {
    return .{ .instructions = .empty, .alloc = alloc };
  }

  pub fn deinit(self: *IR) void {
    for (self.instructions.items) |inst| inst.deinit(self.alloc);
    self.instructions.deinit(self.alloc);
  }

  pub fn emitWithArg(self: *IR, op: OpCode, arg: u32, inputs: []const ValueId) !ValueId {
    const id: u32 = @intCast(self.instructions.items.len);
    var inst: IRInst = .{ .op = op, .arg1 = arg, .inputs = try self.alloc.dupe(ValueId, inputs) };
    inst.is_pure = inst.isPure();
    try self.instructions.append(self.alloc, inst);
    return id;
  }

  pub fn emit(self: *IR, op: OpCode, inputs: []const ValueId) !ValueId {
    return self.emitWithArg(op, 0, inputs);
  }

  pub fn emitConstant(self: *IR, val: V) !ValueId {
    const stored = val.ref();
    // Mark array constants immutable so cow() always copies them.
    switch (stored) {
      inline .B, .I, .F, .S, .C, .L => |n| n.setFlag(ArrayFlags.immutable),
      inline .m, .M => |d| d.ptr.meta |= ArrayFlags.immutable,
      else => {},
    }
    const id: u32 = @intCast(self.instructions.items.len);
    try self.instructions.append(self.alloc, .{ .op = .Const, .val = stored, .is_pure = true });
    return id;
  }

  pub fn get(self: *IR, id: ValueId) *IRInst {
    return &self.instructions.items[id];
  }

  pub fn markEffectful(self: *IR, id: ValueId) void {
    self.instructions.items[id].is_pure = false;
  }

  pub fn reset(self: *IR) void {
    for (self.instructions.items) |inst| inst.deinit(self.alloc);
    self.instructions.clearRetainingCapacity();
  }
};
