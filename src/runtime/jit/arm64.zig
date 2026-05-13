// arm64 instruction encoding helpers.
// Only the subset needed by the JIT emitter.

const std = @import("std");

pub const Reg = enum(u5) {
  x0=0, x1=1, x2=2, x8=8,
  x19=19, x20=20, x29=29, x30=30,
  sp=31,
};

pub const Buf = struct {
  data: []u8,
  pos:  usize = 0,

  pub fn emit(b: *Buf, instr: u32) void {
    std.mem.writeInt(u32, b.data[b.pos..][0..4], instr, .little);
    b.pos += 4;
  }

  pub fn written(b: *const Buf) []const u8 { return b.data[0..b.pos]; }
  pub fn bytePos(b: *const Buf) usize { return b.pos; }

  // Patch a previously emitted BL instruction at byte `offset`
  // with the correct PC-relative offset to `target`.
  pub fn patchBl(b: *Buf, offset: usize, target: usize) void {
    const pc = offset; // BL is at this byte offset in the buffer
    const base = @intFromPtr(b.data.ptr);
    const from = base + pc;
    const delta = @as(i64, @intCast(target)) - @as(i64, @intCast(from));
    const words = @divExact(delta, 4);
    const imm26: u32 = @as(u32, @bitCast(@as(i32, @intCast(words)))) & 0x03FF_FFFF;
    std.mem.writeInt(u32, b.data[offset..][0..4], 0x94000000 | imm26, .little);
  }
};

// MOV Xd, Xn  (ORR Xd, XZR, Xn)
pub fn mov(d: Reg, n: Reg) u32 {
  return 0xAA000000 |
    (@as(u32, @intFromEnum(n)) << 16) |
    (0x1F << 5) |
    @as(u32, @intFromEnum(d));
}

// MOVZ Wd, #imm16  (zero-extend, 32-bit)
pub fn movzW(d: Reg, imm: u16) u32 {
  return 0x52800000 |
    (@as(u32, imm) << 5) |
    @as(u32, @intFromEnum(d));
}

// MOVZ Xd, #imm16  (zero-extend, 64-bit)
pub fn movzX(d: Reg, imm: u16) u32 {
  return 0xD2800000 |
    (@as(u32, imm) << 5) |
    @as(u32, @intFromEnum(d));
}

// MOVK Xd, #imm16, LSL #shift  (keep other bits, 64-bit)
pub fn movkX(d: Reg, imm: u16, shift: u6) u32 {
  const hw: u32 = switch (shift) { 0 => 0, 16 => 1, 32 => 2, 48 => 3, else => unreachable };
  return 0xF2800000 |
    (hw << 21) |
    (@as(u32, imm) << 5) |
    @as(u32, @intFromEnum(d));
}

// Load a 64-bit immediate into Xd using MOVZ + up to 3x MOVK.
// Writes directly into buf.
pub fn mov64(b: *Buf, d: Reg, val: u64) void {
  const w0: u16 = @truncate(val);
  const w1: u16 = @truncate(val >> 16);
  const w2: u16 = @truncate(val >> 32);
  const w3: u16 = @truncate(val >> 48);
  b.emit(movzX(d, w0));
  if (w1 != 0) b.emit(movkX(d, w1, 16));
  if (w2 != 0) b.emit(movkX(d, w2, 32));
  if (w3 != 0) b.emit(movkX(d, w3, 48));
}

// BLR Xn  (branch-with-link to register)
pub fn blr(n: Reg) u32 {
  return 0xD63F0000 | (@as(u32, @intFromEnum(n)) << 5);
}

// BR Xn  (branch to register, no link)
pub fn br(n: Reg) u32 {
  return 0xD61F0000 | (@as(u32, @intFromEnum(n)) << 5);
}

// BL #offset  (PC-relative, offset in bytes, must be multiple of 4)
// Caller is responsible for patching if target isn't known yet.
pub fn bl(offset_bytes: i32) u32 {
  const words = @divExact(offset_bytes, 4);
  const imm26: u32 = @as(u32, @bitCast(words)) & 0x03FF_FFFF;
  return 0x94000000 | imm26;
}

// RET
pub fn ret() u32 { return 0xD65F03C0; }

// STP X29, X30, [SP, #-size]!   (pre-index, size must be multiple of 16, negative)
pub fn stpFpLr(size: u7) u32 {
  // imm7 field = size / 8, signed 7-bit
  const imm7: u32 = @as(u7, @bitCast(-@as(i7, @intCast(size / 8))));
  return 0xA9800000 | (imm7 << 15) | (30 << 10) | (31 << 5) | 29;
}

// LDP X29, X30, [SP], #size   (post-index)
pub fn ldpFpLr(size: u7) u32 {
  const imm7: u32 = @as(u7, @truncate(size / 8));
  return 0xA8C00000 | (imm7 << 15) | (30 << 10) | (31 << 5) | 29;
}

// STP X19, X20, [SP, #16]  (signed offset)
pub fn stpX19X20at16() u32 {
  // imm7 = 16/8 = 2
  return 0xA9010000 | (20 << 10) | (31 << 5) | 19;
}

// LDP X19, X20, [SP, #16]
pub fn ldpX19X20at16() u32 {
  return 0xA9410000 | (20 << 10) | (31 << 5) | 19;
}

// STP X19, X30, [SP, #-size]!   (pre-index; saves vm ptr + link register)
pub fn stpX19X30(size: u7) u32 {
  const imm7: u32 = @as(u7, @bitCast(-@as(i7, @intCast(size / 8))));
  return 0xA9800000 | (imm7 << 15) | (30 << 10) | (31 << 5) | 19;
}

// LDP X19, X30, [SP], #size   (post-index)
pub fn ldpX19X30(size: u7) u32 {
  const imm7: u32 = @as(u7, @truncate(size / 8));
  return 0xA8C00000 | (imm7 << 15) | (30 << 10) | (31 << 5) | 19;
}

// MOV X29, SP  (set frame pointer)
pub fn movFpSp() u32 { return 0x910003FD; }

// NOP
pub fn nop() u32 { return 0xD503201F; }
