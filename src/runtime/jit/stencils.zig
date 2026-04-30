// Stencil scanning and patching for Copy-and-Patch JIT.
//
// Each stencil is a machine-code fragment in the text segment that:
//   1. Does its work (push a value, etc.)
//   2. Ends with a NEXT HOLE: MOVZ X8,#0; MOVK X8,#0,LSL16; ...; BR X8
//      The BR chains to the next stencil (or handler section) in JIT memory.
//
// Parameterised stencils additionally carry an OPERAND HOLE:
//   MOVZ X1, #0xFFFF  (= 0xD29FFFE1)
// which is patched to MOVZ X1, #<actual_operand> before execution.
//
// Stencil functions are defined in vm.zig (needs VM type) and are scanned
// here at JIT-cache initialisation time.

// ── Hole signatures (u32, little-endian, native byte order) ──────────────────
pub const OPERAND_SIG: u32 = 0xD29FFFE1; // MOVZ X1, #0xFFFF
pub const NEXT_SIG:    u32 = 0xD2800008; // MOVZ X8, #0  (first word of NEXT hole)

// Full 5-word NEXT hole that we scan for:
//   MOVZ X8, #0          0xD2800008
//   MOVK X8, #0, LSL 16  0xF2A00008
//   MOVK X8, #0, LSL 32  0xF2C00008
//   MOVK X8, #0, LSL 48  0xF2E00008
//   BR   X8              0xD61F0100
const NEXT_WORDS = [5]u32{ 0xD2800008, 0xF2A00008, 0xF2C00008, 0xF2E00008, 0xD61F0100 };

pub const StencilInfo = struct {
  /// Pointer to the stencil's machine code in the text segment.
  bytes: [*]const u8,
  /// Number of bytes to copy (includes the 5-word NEXT hole).
  size:  usize,
  /// Byte offset of the OPERAND hole within `bytes` (if present).
  operand_offset: ?usize,
  /// Byte offset of the first word of the NEXT hole within `bytes`.
  next_offset: usize,
};

/// Scan without skipping any prologue — for stencils that call other functions
/// and therefore need their own STP/LDP frame preserved in the copied body.
pub fn scanWithFrame(fn_addr: usize) ?StencilInfo {
  const MAX_WORDS = 256;
  const p: [*]const u32 = @ptrFromInt(fn_addr);
  var operand_off: ?usize = null;

  for (0..MAX_WORDS) |i| {
    const w = p[i];
    if (w == OPERAND_SIG) { operand_off = i * 4; continue; }
    if (w == NEXT_SIG and i + 4 < MAX_WORDS) {
      if (p[i+1] == NEXT_WORDS[1] and p[i+2] == NEXT_WORDS[2] and
        p[i+3] == NEXT_WORDS[3] and p[i+4] == NEXT_WORDS[4])
      {
        return .{
          .bytes          = @ptrFromInt(fn_addr),
          .size           = (i + 5) * 4,
          .operand_offset = operand_off,
          .next_offset    = i * 4,
        };
      }
    }
  }
  return null;
}

/// Scan a function's machine code for OPERAND and NEXT holes.
///
/// On arm64/macOS the compiler adds a frame-record prologue (stp x29,x30 +
/// mov x29,sp) even for leaf functions when frame pointers are enabled.
/// We detect and SKIP this prologue so the copied stencil body starts with
/// the actual work instructions (which access VM fields via x0, not x29).
///
/// If the prologue is unexpectedly large (> 4 instructions — typical of debug
/// builds that spill locals to the stack via x29), we return null and fall
/// back to the handler-call emitter, which is always safe.
pub fn scan(fn_addr: usize) ?StencilInfo {
  const MAX_PROLOGUE = 4; // tolerate up to 4 frame-setup instructions
  const MAX_WORDS    = 256;
  const p: [*]const u32 = @ptrFromInt(fn_addr);

  // ── Detect and skip the compiler-generated prologue ───────────────────
  // Recognised frame-setup patterns (top byte of the u32, little-endian):
  //   0xA9 / 0xA8  →  STP / LDP pair (stores to sp)
  //   0x91         →  ADD Xd, Xn, #imm  (includes ADD X29, SP, #0 = mov x29,sp)
  //   0xD1         →  SUB Xd, Xn, #imm  (sub sp, sp, #N)
  var skip: usize = 0;
  for (0..MAX_PROLOGUE) |i| {
    const top = p[i] >> 24;
    if (top == 0xA9 or top == 0xA8 or top == 0x91 or top == 0xD1)
      skip = i + 1
    else
      break;
  }
  // If the prologue exhausted the budget, reject this stencil.
  if (skip >= MAX_PROLOGUE) return null;

  // ── Scan the body for holes ───────────────────────────────────────────
  const body: [*]const u32 = @ptrFromInt(fn_addr + skip * 4);
  var operand_off: ?usize = null;

  for (0..MAX_WORDS) |i| {
    const w = body[i];

    if (w == OPERAND_SIG) {
      operand_off = i * 4;
      continue;
    }

    if (w == NEXT_SIG and i + 4 < MAX_WORDS) {
      if (body[i+1] == NEXT_WORDS[1] and
        body[i+2] == NEXT_WORDS[2] and
        body[i+3] == NEXT_WORDS[3] and
        body[i+4] == NEXT_WORDS[4])
      {
        return .{
          .bytes          = @ptrFromInt(fn_addr + skip * 4),
          .size           = (i + 5) * 4,
          .operand_offset = operand_off,
          .next_offset    = i * 4,
        };
      }
    }
  }
  return null;
}

/// Patch the NEXT hole in a copied stencil slice to jump to `target`.
/// `data` is the writable JIT buffer; `hole_off` is the byte offset of the hole.
pub fn patchNext(data: []u8, hole_off: usize, target: usize) void {
  const ptr: [*]u32 = @alignCast(@ptrCast(data.ptr + hole_off));
  const a = target;
  ptr[0] = 0xD2800008 | (@as(u32, @truncate( a        & 0xFFFF)) << 5);
  ptr[1] = 0xF2A00008 | (@as(u32, @truncate((a >> 16) & 0xFFFF)) << 5);
  ptr[2] = 0xF2C00008 | (@as(u32, @truncate((a >> 32) & 0xFFFF)) << 5);
  ptr[3] = 0xF2E00008 | (@as(u32, @truncate((a >> 48) & 0xFFFF)) << 5);
  // ptr[4] = 0xD61F0100 (BR X8) — leave as-is
}

/// Patch the OPERAND hole in a copied stencil slice with a u16 value.
pub fn patchOperand(data: []u8, hole_off: usize, value: u16) void {
  const ptr: *u32 = @alignCast(@ptrCast(data.ptr + hole_off));
  ptr.* = 0xD2800001 | (@as(u32, value) << 5); // MOVZ X1, #value
}
