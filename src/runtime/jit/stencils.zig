// Stencil scanning and patching for Copy-and-Patch JIT.
const std           = @import("std");
const build_options = @import("build_options");
//
// Each stencil is a machine-code fragment in the text segment that:
//   1. Does its work (push a value, etc.)
//   2. Ends with a NEXT HOLE: MOVZ X8,#0xDEAD; MOVK X8,#0xBEEF,LSL16; ...; BR X8
//      The BR chains to the next stencil (or handler section) in JIT memory.
//      patchNext() overwrites the MOVZ/MOVK words with the actual target address.
//
// Parameterised stencils additionally carry an OPERAND HOLE:
//   MOVZ X1, #0xCA11  (= 0xD2994221)
// which is patched to MOVZ X1, #<actual_operand> before execution.
//
// Stencil functions are defined in vm.zig (needs VM type) and are scanned
// here at JIT-cache initialisation time.

// ── Hole signatures (u32, little-endian, native byte order) ──────────────────
//
// Magic sentinel values chosen so they cannot appear in naturally-generated
// ARM64 code.  Using non-zero, unusual immediates prevents the scanner from
// false-matching instructions that the compiler emits for other purposes
// (e.g. MOVZ X1, #0xFFFF generated for maxInt(u32) comparisons, or
//  MOVZ X8, #0 generated for zero-initialisation).
//
//   OPERAND_SIG: MOVZ X1, #0xCA11  (0xD2994221)
//   NEXT_SIG[0]: MOVZ X8, #0xDEAD  (0xD29BD5A8)
//   NEXT_SIG[1]: MOVK X8, #0xBEEF, LSL16  (0xF2B7DDE8)
//   NEXT_SIG[2]: MOVK X8, #0xCAFE, LSL32  (0xF2D95FC8)
//   NEXT_SIG[3]: MOVK X8, #0xBABE, LSL48  (0xF2F757C8)
//   NEXT_SIG[4]: BR   X8                   (0xD61F0100) — unchanged
pub const OPERAND_SIG: u32 = 0xD2994221; // MOVZ X1, #0xCA11
pub const NEXT_SIG:    u32 = 0xD29BD5A8; // MOVZ X8, #0xDEAD  (first word of NEXT hole)

// Full 5-word NEXT hole that we scan for:
const NEXT_WORDS = [5]u32{ 0xD29BD5A8, 0xF2B7DDE8, 0xF2D95FC8, 0xF2F757C8, 0xD61F0100 };

pub const StencilInfo = struct {
  /// Pointer to the stencil's machine code in the text segment.
  bytes: [*]const u8,
  /// Number of bytes to copy (includes the 5-word NEXT hole, or both holes for branch stencils).
  size:  usize,
  /// Byte offset of the OPERAND hole within `bytes` (if present).
  operand_offset: ?usize,
  /// Byte offset of the first word of the (fall-through) NEXT hole within `bytes`.
  /// Unused (set to 0) when is_terminal is true.
  next_offset: usize,
  /// Byte offset of the second NEXT hole — taken path for branch stencils, or second tail in non-branch.
  branch_offset: ?usize = null,
  /// Byte offset of the third NEXT hole — for stencils with 3 tail-duplicated paths (e.g. specDyad in ReleaseFast).
  branch_offset2: ?usize = null,
  /// True for terminal stencils (e.g. Return) that end with RET instead of a NEXT hole.
  /// The emitter must NOT set pending_next_hole after copying a terminal stencil.
  is_terminal: bool = false,
};

/// Return true if the code words [0, next_word) contain any arm64 PC-relative
/// branch instruction whose target lies at or beyond word (next_word + 5).
/// Such a branch would jump outside the stencil's copied region (which ends
/// after the 5-word NEXT hole) and cause an illegal-instruction crash in the
/// JIT buffer.  Also rejects ADRP (position-dependent page-relative loads)
/// and BL (position-dependent call) for the same reason.
fn hasEscapingBranch(code: [*]const u32, next_word: usize) bool {
  const end: i64 = @as(i64, @intCast(next_word)) + 5;
  for (0..next_word) |i| {
    const w = code[i];
    const top = w >> 24;
    // ADRP: position-dependent page-relative address load.
    if ((top & 0x9F) == 0x90) return true;
    // BL: position-dependent call.
    if (top >= 0x94 and top <= 0x97) return true;
    // PC-relative branches: check if the target escapes the stencil bounds.
    const base: i64 = @intCast(i);
    const target: i64 = switch (top) {
      // B.cond (conditional branch): imm19 in bits [23:5]
      0x54 => base + @as(i64, @as(i19, @bitCast(@as(u19, @truncate(w >> 5))))),
      // CBZ / CBNZ 32-bit [0x34/0x35] and 64-bit [0xB4/0xB5]: imm19 in bits [23:5]
      0x34, 0x35, 0xB4, 0xB5 => base + @as(i64, @as(i19, @bitCast(@as(u19, @truncate(w >> 5))))),
      // TBZ / TBNZ 32-bit [0x36/0x37] and 64-bit [0xB6/0xB7]: imm14 in bits [18:5]
      0x36, 0x37, 0xB6, 0xB7 => base + @as(i64, @as(i14, @bitCast(@as(u14, @truncate(w >> 5))))),
      // B unconditional: imm26 in bits [25:0]
      0x14, 0x15, 0x16, 0x17 => base + @as(i64, @as(i26, @bitCast(@as(u26, @truncate(w))))),
      else => continue,
    };
    if (target >= end) return true;
  }
  return false;
}

/// Scan without skipping any prologue — for stencils that call other functions
/// and therefore need their own STP/LDP frame preserved in the copied body.
/// Returns null if the stencil body contains branches that escape the copied
/// region (a ReleaseFast code-layout hazard).
pub fn scanWithFrame(fn_addr: usize) ?StencilInfo {
  const MAX_WORDS = 256;
  const p: [*]const u32 = @ptrFromInt(fn_addr);
  var operand_off: ?usize = null;

  for (0..MAX_WORDS) |i| {
    const w = p[i];
    // Record only the FIRST occurrence so a compiler-generated instruction
    // that accidentally matches later in the body does not overwrite the
    // real hole offset.
    if (w == OPERAND_SIG) { if (operand_off == null) operand_off = i * 4; continue; }
    if (w == NEXT_SIG and i + 4 < MAX_WORDS) {
      if (p[i+1] == NEXT_WORDS[1] and p[i+2] == NEXT_WORDS[2] and
        p[i+3] == NEXT_WORDS[3] and p[i+4] == NEXT_WORDS[4])
      {
        if (hasEscapingBranch(p, i)) return null;
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

    // Record only the FIRST occurrence — see scanWithFrame for rationale.
    if (w == OPERAND_SIG) {
      if (operand_off == null) operand_off = i * 4;
      continue;
    }

    if (w == NEXT_SIG and i + 4 < MAX_WORDS) {
      if (body[i+1] == NEXT_WORDS[1] and
        body[i+2] == NEXT_WORDS[2] and
        body[i+3] == NEXT_WORDS[3] and
        body[i+4] == NEXT_WORDS[4])
      {
        if (hasEscapingBranch(body, i)) return null;
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

/// Alias for patchNext — patches the taken (second) NEXT hole of a branch stencil.
pub const patchBranch = patchNext;

/// Scan a function for THREE NEXT holes.
/// Used when ReleaseFast tail-duplicates a 3-path stencil (e.g. specDyad: int fast path,
/// float fast path, slow BLR path each get their own NEXT hole copy).
/// The emitter patches all three holes to the same successor address.
pub fn scan3WithFrame(fn_addr: usize) ?StencilInfo {
  const MAX_WORDS = 256;
  const p: [*]const u32 = @ptrFromInt(fn_addr);
  var operand_off: ?usize = null;
  var first_next:  ?usize = null;
  var second_next: ?usize = null;

  var i: usize = 0;
  while (i < MAX_WORDS) : (i += 1) {
    const w = p[i];
    if (w == OPERAND_SIG) {
      if (operand_off == null) operand_off = i * 4;
      continue;
    }
    if (w == NEXT_SIG and i + 4 < MAX_WORDS) {
      if (p[i+1] == NEXT_WORDS[1] and p[i+2] == NEXT_WORDS[2] and
          p[i+3] == NEXT_WORDS[3] and p[i+4] == NEXT_WORDS[4])
      {
        if (first_next == null) {
          first_next = i * 4;
          i += 4;
        } else if (second_next == null) {
          second_next = i * 4;
          i += 4;
        } else {
          return .{
            .bytes          = @ptrFromInt(fn_addr),
            .size           = (i + 5) * 4,
            .operand_offset = operand_off,
            .next_offset    = first_next.?,
            .branch_offset  = second_next.?,
            .branch_offset2 = i * 4,
          };
        }
      }
    }
  }
  return null;
}

/// Scan a function for TWO NEXT holes (for branch stencils with fall-through + taken paths).
/// Does not skip the compiler prologue (like scanWithFrame) since branch stencils use BLR.
/// Returns StencilInfo with next_offset = first hole, branch_offset = second hole.
/// For non-branch stencils the emitter patches both holes to the same successor address.
pub fn scan2WithFrame(fn_addr: usize) ?StencilInfo {
  const MAX_WORDS = 256;
  const p: [*]const u32 = @ptrFromInt(fn_addr);
  var operand_off: ?usize = null;
  var first_next: ?usize = null;

  var i: usize = 0;
  while (i < MAX_WORDS) : (i += 1) {
    const w = p[i];
    if (w == OPERAND_SIG) {
      if (operand_off == null) operand_off = i * 4;
      continue;
    }
    if (w == NEXT_SIG and i + 4 < MAX_WORDS) {
      if (p[i+1] == NEXT_WORDS[1] and p[i+2] == NEXT_WORDS[2] and
          p[i+3] == NEXT_WORDS[3] and p[i+4] == NEXT_WORDS[4])
      {
        if (first_next == null) {
          first_next = i * 4;
          i += 4; // skip remaining 4 words of this hole; loop will add 1
        } else {
          return .{
            .bytes          = @ptrFromInt(fn_addr),
            .size           = (i + 5) * 4,
            .operand_offset = operand_off,
            .next_offset    = first_next.?,
            .branch_offset  = i * 4,
          };
        }
      }
    }
  }
  return null;
}

/// Scan a function for a terminal stencil that ends with RET (0xD65F03C0).
/// Used for the Return stencil: the JIT function ends with a proper RET instead
/// of a NEXT hole, so Phase 2 is never entered for lambdas that end at Return.
/// Includes the compiler prologue in the copied region (like scanWithFrame) so
/// the BLR inside can save/restore LR correctly.
pub fn scanTerminal(fn_addr: usize) ?StencilInfo {
  const MAX_WORDS   = 64;
  const RET_WORD: u32 = 0xD65F03C0;
  const p: [*]const u32 = @ptrFromInt(fn_addr);

  for (0..MAX_WORDS) |i| {
    if (p[i] == RET_WORD) {
      return .{
        .bytes          = @ptrFromInt(fn_addr),
        .size           = (i + 1) * 4, // includes the RET instruction
        .operand_offset = null,
        .next_offset    = 0,           // unused for terminal stencils
        .is_terminal    = true,
      };
    }
  }
  return null;
}

/// Validate a single registered stencil for unpatched NEXT-hole sentinels.
///
/// Copies the stencil bytes into a scratch buffer, patches all declared holes
/// with a harmless dummy address, then scans for any surviving NEXT_SIG words
/// (0xD29BD5A8 = MOVZ X8, #0xDEAD).  Any survivor means the scanner captured
/// fewer holes than actually exist in the stencil — left unpatched they would
/// cause a SIGILL at the first hot call.
///
/// Panics with the stencil name and byte offset of the first unpatched hole.
pub fn validateStencil(name: []const u8, info: StencilInfo) void {
  if (info.is_terminal) return; // terminal stencils have no NEXT holes

  var buf: [1024]u8 align(4) = undefined;
  std.debug.assert(info.size <= buf.len);
  @memcpy(buf[0..info.size], info.bytes[0..info.size]);

  // Patch all declared holes with an address whose low 16 bits != 0xDEAD,
  // so the patched words are guaranteed not to match NEXT_SIG themselves.
  const dummy: usize = 1;
  patchNext(&buf, info.next_offset, dummy);
  if (info.branch_offset)  |off| patchNext(&buf, off, dummy);
  if (info.branch_offset2) |off| patchNext(&buf, off, dummy);

  const words: [*]const u32 = @alignCast(@ptrCast(&buf));
  const n_words = info.size / 4;
  for (0..n_words) |i| {
    if (words[i] == NEXT_SIG) {
      std.debug.panic(
        "JIT stencil '{s}': unpatched NEXT hole at byte {d} " ++
        "(scanner captured too few holes — try scan3WithFrame or scan2WithFrame)\n",
        .{ name, i * 4 },
      );
    }
  }
}

/// Validate all non-null entries in a StencilTable.
/// Uses comptime field iteration so new table fields are covered automatically.
/// No-op unless the binary was built with -Dparanoid (zero runtime cost otherwise).
pub fn validateTable(table: anytype) void {
  if (!build_options.paranoid) return;
  inline for (@typeInfo(@TypeOf(table)).@"struct".fields) |field| {
    if (@field(table, field.name)) |info| {
      validateStencil(field.name, info);
    }
  }
}
