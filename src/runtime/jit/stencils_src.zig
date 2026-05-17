// CPS stencil source for the copy-and-patch JIT.
//
// Every bytecode OpCode maps to one `pub export fn stencil_<name>(vm)`.
// Each stencil:
//   1. (Optional) Reads its per-call-site operand from a data slot via
//      ADRP+ADD pair (PAGE21/PAGEOFF12 relocations). The slot lives in
//      the JIT buffer next to the copied stencil bytes.
//   2. BLs into a runtime helper (`cps_*` in cps_helpers.zig) to do the
//      actual work.
//   3. Tail-calls __ink_hole_next (B with BR26 relocation) so the chain
//      continues at the next stencil.
//
// Branch stencils (jump_false, jump_true) carry a second hole, taken,
// for the branch-taken target.
//
// The stencil_return terminal ends with `ret` — its containing JIT chain
// returns to the C caller (the CPS-chain caller of this lambda).
//
// stencils_src.zig is compiled to a standalone object file always at
// ReleaseFast. tools/extract_stencils.zig walks the resulting __text
// section's relocations and emits the metadata table consumed by the
// runtime patcher.

const std = @import("std");

// Opaque VM — stencils never touch its fields directly. All access goes
// through the cps_* helpers, which import the real layout.
pub const VM = opaque {};

// ── Continuation holes ────────────────────────────────────────────────────────
extern fn __ink_hole_next(vm: *VM) callconv(.c) void;
extern fn __ink_hole_taken(vm: *VM) callconv(.c) void;

// ── Operand hole (Option A: direct page-relative data slot) ───────────────────
extern const __ink_hole_operand: u64;

/// Load the u32 operand for this stencil from its data slot.
/// Inline asm forces ADRP+ADD with PAGE21+PAGEOFF12 relocations (no GOT
/// indirection).
inline fn loadOperand32() u32 {
    return asm volatile (
        \\adrp x9, ___ink_hole_operand@PAGE
        \\add  x9, x9, ___ink_hole_operand@PAGEOFF
        \\ldr  w9, [x9]
        : [ret] "={x9}" (-> u32)
        :
        : .{ .memory = true });
}

// ── Helper externs (implementations in cps_helpers.zig) ──────────────────────
//
// Naming convention: each bytecode OpCode `X` (PascalCase) maps to
// `cps_<snake_case>(vm, ...)`. Helpers with operands take a single
// `op: u32` parameter; the helper interprets the lower bits as needed
// (u8 for byte operands, u16 for jump offsets, etc.).

extern fn cps_nop(vm: *VM) callconv(.c) void;
extern fn cps_drop(vm: *VM) callconv(.c) void;
extern fn cps_dup(vm: *VM) callconv(.c) void;
extern fn cps_gap(vm: *VM) callconv(.c) void;
extern fn cps_const(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_int(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_local(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_local_last(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_global(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_assign_local(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_assign_global(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_apply1(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_apply2(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_make_list(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_make_dict(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_make_table(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_make_partial(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_derive(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_amend(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_dmend(vm: *VM, op: u32) callconv(.c) void;
extern fn cps_command(vm: *VM) callconv(.c) void;

// ── No-operand stencils ───────────────────────────────────────────────────────

pub export fn stencil_nop(vm: *VM) callconv(.c) void {
    cps_nop(vm);
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_drop(vm: *VM) callconv(.c) void {
    cps_drop(vm);
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_dup(vm: *VM) callconv(.c) void {
    cps_dup(vm);
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_gap(vm: *VM) callconv(.c) void {
    cps_gap(vm);
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_command(vm: *VM) callconv(.c) void {
    cps_command(vm);
    return @call(.always_tail, __ink_hole_next, .{vm});
}

// ── 1-byte operand stencils ──────────────────────────────────────────────────

pub export fn stencil_const(vm: *VM) callconv(.c) void {
    cps_const(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_local(vm: *VM) callconv(.c) void {
    cps_local(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_local_last(vm: *VM) callconv(.c) void {
    cps_local_last(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_global(vm: *VM) callconv(.c) void {
    cps_global(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_assign_local(vm: *VM) callconv(.c) void {
    cps_assign_local(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_assign_global(vm: *VM) callconv(.c) void {
    cps_assign_global(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_apply1(vm: *VM) callconv(.c) void {
    cps_apply1(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_apply2(vm: *VM) callconv(.c) void {
    cps_apply2(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_make_list(vm: *VM) callconv(.c) void {
    cps_make_list(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_make_dict(vm: *VM) callconv(.c) void {
    cps_make_dict(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_make_table(vm: *VM) callconv(.c) void {
    cps_make_table(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_derive(vm: *VM) callconv(.c) void {
    cps_derive(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_amend(vm: *VM) callconv(.c) void {
    cps_amend(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_dmend(vm: *VM) callconv(.c) void {
    cps_dmend(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

// ── 2-byte operand stencils ───────────────────────────────────────────────────
// Same operand load — the helper truncates u32 to u16 / i16 as needed.

pub export fn stencil_int(vm: *VM) callconv(.c) void {
    cps_int(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

// MakePartial has TWO operand bytes (argc, mask). Both are packed into
// the same u32 operand slot: (mask << 8) | argc. The helper unpacks.
pub export fn stencil_make_partial(vm: *VM) callconv(.c) void {
    cps_make_partial(vm, loadOperand32());
    return @call(.always_tail, __ink_hole_next, .{vm});
}

// ── Terminal ──────────────────────────────────────────────────────────────────
// stencil_return is the only stencil that does not end with a tail-call;
// it returns to the C caller, ending this lambda's JIT chain. Phase 2.2b
// wraps this with the frame-popping `cps_return` helper before the ret.

pub export fn stencil_return(vm: *VM) callconv(.c) void {
    _ = vm;
    return;
}

// Smoke-test scaffolding kept from Phase 1/2.1 — the smoke binary still
// exercises this `add_ii` shape. Phase 2.2c will retire it once the
// emitter is wired in.
extern fn __vm_pop_i32(vm: *VM) callconv(.c) i32;
extern fn __vm_push_i32(vm: *VM, v: i32) callconv(.c) void;

pub export fn stencil_add_ii(vm: *VM) callconv(.c) void {
    const y = __vm_pop_i32(vm);
    const x = __vm_pop_i32(vm);
    __vm_push_i32(vm, x +% y);
    return @call(.always_tail, __ink_hole_next, .{vm});
}

pub export fn stencil_const_i(vm: *VM) callconv(.c) void {
    const value: i32 = @bitCast(loadOperand32());
    __vm_push_i32(vm, value);
    return @call(.always_tail, __ink_hole_next, .{vm});
}
