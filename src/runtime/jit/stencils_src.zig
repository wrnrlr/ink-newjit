// Prototype stencil source for the AOT copy-and-patch extractor.
//
// This module is compiled to a standalone object file *always at ReleaseFast*,
// regardless of how the rest of the runtime is built. The extractor tool
// (tools/extract_stencils.zig) then reads the .o, walks the symbol table and
// relocation entries, and emits a generated stencil_data.zig consumed by the
// JIT.
//
// Each stencil:
//   1. Does its work using registers reachable via the C ABI (x0 = vm on arm64).
//   2. Ends with a tail-call to one of the extern hole symbols below.
//
// The hole symbols are *never linked* — they exist only so the optimizer emits
// a real PC-relative branch relocation (ARM64_RELOC_BRANCH26 on macOS,
// R_X86_64_PLT32 on linux) that the extractor can patch at JIT time.
//
// Operand patching uses Option A from the design review: an extern `const`
// data slot referenced via ADRP+LDR (or PC32 on x86_64). The extractor records
// these as a single logical "operand hole" — two relocations on arm64, one
// on x86_64 — and the JIT writes the operand value into a per-stencil data
// slot adjacent to the copied code.

const std = @import("std");

// Opaque VM pointer. The runtime knows the real layout; the stencils only
// need to forward it to the next continuation.
pub const VM = opaque {};

// ── Continuation holes ────────────────────────────────────────────────────────
//
// Every stencil except `return_` ends with a tail-call to one of these.
// The extractor records the offset of the trailing branch as a "next hole"
// (or "taken hole" for the conditional alternative) keyed by symbol name.

extern fn __ink_hole_next(vm: *VM) callconv(.c) void;
extern fn __ink_hole_taken(vm: *VM) callconv(.c) void;

// ── Operand hole (Option A: data slot) ────────────────────────────────────────
//
// For per-call-site immediates (constant indices, local slot numbers, etc.)
// the stencil reads from this extern u64. The compiler emits ADRP+LDR
// (arm64) or RIP-relative MOV (x86_64) which the extractor records as a
// single logical "operand hole". The JIT writes the operand bytes into a
// data slot it allocates next to each copied stencil.
extern const __ink_hole_operand: u64;

// ── VM ABI surface ────────────────────────────────────────────────────────────
//
// Real VM has many fields; for the prototype we declare just the few stencil
// shapes need to touch. The runtime side will guarantee these offsets match
// the real layout (Phase 2 picks this up). For now we use opaque-pointer math
// against a single `top` slot to prove the pipeline works.

extern fn __vm_pop_i32(vm: *VM) callconv(.c) i32;
extern fn __vm_push_i32(vm: *VM, v: i32) callconv(.c) void;
extern fn __vm_peek_i32(vm: *VM) callconv(.c) i32;
extern fn __vm_pop_bool(vm: *VM) callconv(.c) bool;

// ── Stencils ──────────────────────────────────────────────────────────────────

/// Pass-through. Smallest possible stencil: a single trailing branch.
/// Useful as a relocation sanity check and a chain terminator that doesn't
/// consume anything from the VM.
pub export fn stencil_nop(vm: *VM) callconv(.c) void {
  return @call(.always_tail, __ink_hole_next, .{vm});
}

/// Push a constant integer onto the VM stack.
/// Reads its operand from the stencil-local data slot (Option A).
pub export fn stencil_const_i(vm: *VM) callconv(.c) void {
  const value: i32 = @truncate(@as(i64, @bitCast(__ink_hole_operand)));
  __vm_push_i32(vm, value);
  return @call(.always_tail, __ink_hole_next, .{vm});
}

/// Pop two i32s, push their sum (wrapping). Operand-free.
pub export fn stencil_add_ii(vm: *VM) callconv(.c) void {
  const y = __vm_pop_i32(vm);
  const x = __vm_pop_i32(vm);
  __vm_push_i32(vm, x +% y);
  return @call(.always_tail, __ink_hole_next, .{vm});
}

/// Pop two i32s, push their product (wrapping).
pub export fn stencil_mul_ii(vm: *VM) callconv(.c) void {
  const y = __vm_pop_i32(vm);
  const x = __vm_pop_i32(vm);
  __vm_push_i32(vm, x *% y);
  return @call(.always_tail, __ink_hole_next, .{vm});
}

/// Branch stencil. Pops a bool; if true take the `taken` path, else fall
/// through to `next`. Two distinct hole symbols → two distinct relocations
/// that the extractor records as `next_off` and `taken_off`.
pub export fn stencil_jump_false(vm: *VM) callconv(.c) void {
  const cond = __vm_pop_bool(vm);
  if (cond) {
    return @call(.always_tail, __ink_hole_next, .{vm});
  }
  return @call(.always_tail, __ink_hole_taken, .{vm});
}

/// Terminal stencil. No NEXT hole — ends with a real `ret` so the JIT chain
/// returns to the C caller cleanly. Marked `is_terminal` in the extracted
/// metadata so the patcher knows not to look for a trailing branch.
pub export fn stencil_return(vm: *VM) callconv(.c) void {
  _ = vm;
  return;
}
