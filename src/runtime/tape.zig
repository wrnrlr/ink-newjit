const std = @import("std");
const util = @import("../util.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Value = @import("../noun/value.zig").V;

pub const OpCode = enum(u8) {
  Nop, Gap, Drop,
	Const, Int,                // Int: inline i16 value (avoids constant pool for small integers)
	Global, Local, LocalLast,  // LocalLast: last use — steals slot without ref increment
	AssignGlobal, AssignLocal, ListAssignGlobal, ListAssignLocal,
	Jump, JumpFalse, JumpTrue,
	Apply1, Apply2,
	Return,                  // return
	Call,                    // call a lambda
	TailCall,                // tail call a lambda
	Apply,                   // apply with brackets
	MakeList,                // make a list from count items on stack
	MakePartial,             // pops func + n args, pushes partial
	Derive,                  // derive verb from variadic (adverb) and top value
	Amend,                   // @[target; index; function; argument]
	Dmend,                   // .[target; path; function; argument]
	MakeDict,                // make a dict from keys and values on stack
	MakeTable,               // make a table from items on stack
	Command,                 // meta command (\h \l \d \t \v \f \cd)
};

/// Op is used to encode primitive IDs and dispatch.
pub const Op = enum(u8) {
  @"%", @"!", @"&", @"+", @"*", @"|", @"<", @">", @"=", @"~",
  @",", @"^", @"#", @"_", @"$", @"?", @"@", @"-", @".",
  sqrt, sqr, exp, log, sin, cos, abs,
  first, last, count, in, has,
  @"0:", @"1:", @"2:", @"9:",
  @":",
  
  // special
  // amend, drill, splice,
  
  // adverbs
  // @"'", @"/", @"\\", @"':", @"/:", @"\\:",
  
  pub const COUNT = @typeInfo(Op).@"enum".fields.len;

  pub fn fromString(s: []const u8) ?Op {
    inline for (std.meta.fields(Op)) |f| {
      if (std.mem.eql(u8, f.name, s)) return @enumFromInt(f.value);
    }
    return null;
  }

  pub fn toString(self: Op) []const u8 { return @tagName(self); }
  pub inline fn code(op: Op) usize { return @intFromEnum(op); }
};

pub const Chunk = struct {
  alloc: Allocator,
  code: ArrayList(u8),
  constants: ArrayList(Value),

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
