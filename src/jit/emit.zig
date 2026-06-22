const std = @import("std");

// ─── Minimal AArch64 code emitter ─────────────────────────────────────────────
//
// Just enough of the A64 encoding to compile elementwise array stencils. Each
// instruction is a 32-bit word. Encodings are built from register fields by the
// helpers below so a typo stays local; the unit tests run the generated code, so
// any encoding error surfaces as a wrong result (or a contained crash), not a
// silent miscompile in the interpreter.

pub const Reg = u5;

// Condition codes.
const COND_LO: u32 = 0b0011; // unsigned lower (C == 0)

fn imm19(off_instrs: i32) u32 {
  return @as(u32, @bitCast(off_instrs)) & 0x7FFFF;
}

// ret x30
fn ret() u32 {
  return 0xD65F03C0;
}
// movz Xd, #imm16  (Xd = imm16, zero-extended)
fn movzX(rd: Reg, imm16: u16) u32 {
  return 0xD2800000 | (@as(u32, imm16) << 5) | rd;
}
// add Xd, Xn, #imm12
fn addImmX(rd: Reg, rn: Reg, imm12: u12) u32 {
  return 0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
}
// subs Xd, Xn, Xm   (cmp Xn,Xm == subs xzr,Xn,Xm)
fn subsX(rd: Reg, rn: Reg, rm: Reg) u32 {
  return 0xEB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
// ldr Wt, [Xn, Xm, lsl #2]   (32-bit load, scaled)
fn ldrWreg(rt: Reg, rn: Reg, rm: Reg) u32 {
  return 0xB8607800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
}
// str Wt, [Xn, Xm, lsl #2]
fn strWreg(rt: Reg, rn: Reg, rm: Reg) u32 {
  return 0xB8207800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
}
// add Wd, Wn, Wm
pub fn addWreg(rd: Reg, rn: Reg, rm: Reg) u32 {
  return 0x0B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
// sub Wd, Wn, Wm
pub fn subWreg(rd: Reg, rn: Reg, rm: Reg) u32 {
  return 0x4B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
// mul Wd, Wn, Wm   (madd Wd,Wn,Wm,wzr)
pub fn mulWreg(rd: Reg, rn: Reg, rm: Reg) u32 {
  return 0x1B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
// ldr Xt, [Xn, #imm12*8]   (64-bit load, unsigned scaled offset)
fn ldrXimm(rt: Reg, rn: Reg, imm12: u12) u32 {
  return 0xF9400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rt;
}
// cbz Xt, +off
fn cbzX(rt: Reg, off_instrs: i32) u32 {
  return 0xB4000000 | (imm19(off_instrs) << 5) | rt;
}
// b.cond +off
fn bcond(cond: u32, off_instrs: i32) u32 {
  return 0x54000000 | (imm19(off_instrs) << 5) | cond;
}

pub const Emitter = struct {
  code: std.ArrayList(u32) = .empty,
  alloc: std.mem.Allocator,

  pub fn init(alloc: std.mem.Allocator) Emitter {
    return .{ .alloc = alloc };
  }
  pub fn deinit(self: *Emitter) void {
    self.code.deinit(self.alloc);
  }
  fn emit(self: *Emitter, word: u32) !void {
    try self.code.append(self.alloc, word);
  }
  fn at(self: *Emitter) i32 {
    return @intCast(self.code.items.len);
  }
  pub fn bytes(self: *Emitter) []const u8 {
    return std.mem.sliceAsBytes(self.code.items);
  }
};

/// The arithmetic stencils we can compile (each maps to one A64 instruction).
pub const BinOp = enum { add, sub, mul };

fn binWord(op: BinOp, rd: Reg, rn: Reg, rm: Reg) u32 {
  return switch (op) {
    .add => addWreg(rd, rn, rm),
    .sub => subWreg(rd, rn, rm),
    .mul => mulWreg(rd, rn, rm),
  };
}

/// Emit `void(*)(i32 *out, const i32 *x, const i32 *y, usize n)` computing
/// `out[i] = x[i] OP y[i]` for i in [0,n). Registers (AAPCS64):
///   x0=out  x1=x  x2=y  x3=n  x4=i  w5,w6=temps
pub fn arrayBinOp(em: *Emitter, op: BinOp) !void {
  const cbz_idx = em.at();
  try em.emit(0); // placeholder: cbz x3, .end   (patched below)
  try em.emit(movzX(4, 0)); // i = 0
  const loop_idx = em.at();
  try em.emit(ldrWreg(5, 1, 4)); // w5 = x[i]
  try em.emit(ldrWreg(6, 2, 4)); // w6 = y[i]
  try em.emit(binWord(op, 5, 5, 6)); // w5 = w5 OP w6
  try em.emit(strWreg(5, 0, 4)); // out[i] = w5
  try em.emit(addImmX(4, 4, 1)); // i += 1
  try em.emit(subsX(31, 4, 3)); // cmp i, n
  const blo_idx = em.at();
  try em.emit(bcond(COND_LO, loop_idx - blo_idx)); // b.lo .loop
  const end_idx = em.at();
  try em.emit(ret());
  // Patch the forward branch now that .end is known.
  em.code.items[@intCast(cbz_idx)] = cbzX(3, end_idx - cbz_idx);
}

/// Tiny canary: `i32(*)(i32 a, i32 b)` returning a+b. Proves the exec pipeline.
pub fn scalarAdd(em: *Emitter) !void {
  try em.emit(addWreg(0, 0, 1)); // w0 = w0 + w1
  try em.emit(ret());
}

// ─── Fused elementwise chain ──────────────────────────────────────────────────
//
// The capability static Zig kernels can't provide: compile an *arbitrary-length*
// elementwise arithmetic expression — given as a postfix tape over a set of leaf
// arrays — into a single native loop. A long chain that would otherwise take N
// passes (N temporaries, N× the memory traffic) collapses to one pass. This is
// the copy-and-patch payoff: a runtime-shaped expression becomes native code.

/// One postfix step: push leaf k's element, or apply a binary op to the top two.
pub const Step = union(enum) { load: u8, op: BinOp };

pub const ChainError = error{ TooDeep, Malformed };

const STACK_REGS: u8 = 8; // value stack lives in w8..w15

/// Emit `void(*)(i32 *out, const i32 *const *leaves, usize n)` computing, for
/// each i, the postfix `tape` evaluated over `leaves[k][i]`, into `out[i]`.
/// Registers: x0=out x1=leaves x2=n x3=i x4=leaf base; value stack w8..w15.
pub fn arrayChain(em: *Emitter, tape: []const Step) !void {
  const cbz_idx = em.at();
  try em.emit(0); // cbz x2, .end   (patched below)
  try em.emit(movzX(3, 0)); // i = 0
  const loop_idx = em.at();
  var depth: u8 = 0;
  for (tape) |step| switch (step) {
    .load => |k| {
      if (depth >= STACK_REGS) return ChainError.TooDeep;
      try em.emit(ldrXimm(4, 1, k)); // x4 = leaves[k]
      try em.emit(ldrWreg(@intCast(8 + depth), 4, 3)); // w(8+depth) = x4[i]
      depth += 1;
    },
    .op => |o| {
      if (depth < 2) return ChainError.Malformed;
      const d: Reg = @intCast(8 + depth - 2);
      const s: Reg = @intCast(8 + depth - 1);
      try em.emit(binWord(o, d, d, s)); // stack[-2] = stack[-2] OP stack[-1]
      depth -= 1;
    },
  };
  if (depth != 1) return ChainError.Malformed; // must reduce to exactly one value
  try em.emit(strWreg(8, 0, 3)); // out[i] = w8
  try em.emit(addImmX(3, 3, 1)); // i += 1
  try em.emit(subsX(31, 3, 2)); // cmp i, n
  const blo_idx = em.at();
  try em.emit(bcond(COND_LO, loop_idx - blo_idx)); // b.lo .loop
  const end_idx = em.at();
  try em.emit(ret());
  em.code.items[@intCast(cbz_idx)] = cbzX(2, end_idx - cbz_idx);
}
