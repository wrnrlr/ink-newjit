// CPS helpers: one runtime function per bytecode OpCode, called from the
// JIT stencils in src/runtime/jit/stencils_src.zig.
//
// Each helper takes the operand(s) as parameters instead of reading them
// from the bytecode stream (vm.readByte / vm.read16). Otherwise the
// semantics match the corresponding doXxx in vm.zig.
//
// Errors that the interpreter raises with `try` become V.err values
// pushed onto the VM stack — there is no Zig error to propagate up
// through a JIT chain.

const std = @import("std");
const VM = @import("../vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const Err = @import("../../noun/value.zig").Err;
const N = @import("../../noun/array.zig").N;
const K = @import("../../noun/class.zig").K;
const Op = @import("../tape.zig").Op;
const Adverb = @import("../../noun/operator.zig").Adverb;
const Fn = @import("../../noun/operator.zig").Fn;
const Dict = @import("../../noun/dict.zig").Dict;
const dispatch = @import("../../primitive/dispatch.zig");
const amend_mod = @import("../../primitive/amend.zig");
const promote = @import("../../primitive/promote.zig").promote;
const enlist = @import("../../primitive/verb/enlist.zig").enlist;
const dict = @import("../../primitive/verb/pair.zig").dict;
const command = @import("../command.zig");

// ── Push helpers ──────────────────────────────────────────────────────────────
//
// Stack pushes can fail with VM.StackOverflow. Helpers convert that to a
// V.stack error so the chain can continue without unwinding through Zig.

fn pushOr(vm: *VM, v: V) void {
    vm.push(v) catch {
        // Stack is already full — replace TOS with an error rather than
        // dropping the value silently.
        v.deinit(vm.alloc);
        if (vm.stack_len > 0) {
            vm.stack[vm.stack_len - 1].deinit(vm.alloc);
            vm.stack[vm.stack_len - 1] = V{ .err = .memory };
        }
    };
}

fn pushErr(vm: *VM, e: Err) void {
    pushOr(vm, V{ .err = e });
}

// ── No-operand helpers ────────────────────────────────────────────────────────

pub export fn cps_nop(vm: *VM) callconv(.c) void {
    _ = vm;
}

pub export fn cps_gap(vm: *VM) callconv(.c) void {
    _ = vm;
}

pub export fn cps_drop(vm: *VM) callconv(.c) void {
    var v = vm.pop();
    v.deinit(vm.alloc);
}

pub export fn cps_dup(vm: *VM) callconv(.c) void {
    const top = vm.stack[vm.stack_len - 1];
    pushOr(vm, top.ref());
}

// ── 1-byte operand helpers ────────────────────────────────────────────────────

pub export fn cps_const(vm: *VM, op: u32) callconv(.c) void {
    const idx: u8 = @truncate(op);
    const v = vm.current_chunk.constants.items[idx];
    pushOr(vm, v.ref());
}

pub export fn cps_local(vm: *VM, op: u32) callconv(.c) void {
    const idx: u8 = @truncate(op);
    const v = vm.stack[vm.currentFrame().base + idx];
    pushOr(vm, v.ref());
}

pub export fn cps_local_last(vm: *VM, op: u32) callconv(.c) void {
    const idx: u8 = @truncate(op);
    const slot = vm.currentFrame().base + idx;
    const v = vm.stack[slot];
    vm.stack[slot] = .blank;
    pushOr(vm, v);
}

pub export fn cps_global(vm: *VM, op: u32) callconv(.c) void {
    const idx: u8 = @truncate(op);
    pushOr(vm, vm.globals[idx].ref());
}

pub export fn cps_assign_local(vm: *VM, op: u32) callconv(.c) void {
    const idx: u8 = @truncate(op);
    const val = vm.pop();
    const stack_idx = vm.currentFrame().base + idx;
    vm.stack[stack_idx].deinit(vm.alloc);
    vm.stack[stack_idx] = val;
    pushOr(vm, .blank);
}

pub export fn cps_assign_global(vm: *VM, op: u32) callconv(.c) void {
    const idx: u8 = @truncate(op);
    const val = vm.pop();
    vm.globals[idx].deinit(vm.alloc);
    vm.globals[idx] = val;
    pushOr(vm, .blank);
}

pub export fn cps_apply1(vm: *VM, op: u32) callconv(.c) void {
    const k: Op = @enumFromInt(@as(u8, @truncate(op)));
    const a = vm.pop();
    defer a.deinit(vm.alloc);
    pushOr(vm, dispatch.dispatch1(vm, k, a));
}

pub export fn cps_apply2(vm: *VM, op: u32) callconv(.c) void {
    const k: Op = @enumFromInt(@as(u8, @truncate(op)));
    const b = vm.pop();
    defer b.deinit(vm.alloc);
    const a = vm.pop();
    defer a.deinit(vm.alloc);
    pushOr(vm, dispatch.dispatch2(vm, k, a, b));
}

pub export fn cps_make_list(vm: *VM, op: u32) callconv(.c) void {
    const argc: u8 = @truncate(op);
    const start = vm.stack_len - argc;
    const values = vm.stack[start..vm.stack_len];
    const list_val = V.Values(vm.alloc, values) catch {
        for (values) |*v| v.deinit(vm.alloc);
        vm.stack_len = start;
        pushErr(vm, .memory);
        return;
    };
    for (values) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    pushOr(vm, list_val);
}

pub export fn cps_make_dict(vm: *VM, op: u32) callconv(.c) void {
    const n: u8 = @truncate(op);
    const start = vm.stack_len - 2 * @as(usize, n);
    var keys: V = undefined;
    var vals: V = undefined;
    if (n == 1) {
        keys = vm.stack[start].ref();
        vals = vm.stack[start + 1].ref();
    } else {
        const k_list = V.Values(vm.alloc, vm.stack[start .. start + n]) catch {
            for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
            vm.stack_len = start;
            pushErr(vm, .memory);
            return;
        };
        keys = promote(vm.alloc, k_list.L);
        const v_list = V.Values(vm.alloc, vm.stack[start + n .. start + 2 * n]) catch {
            keys.deinit(vm.alloc);
            for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
            vm.stack_len = start;
            pushErr(vm, .memory);
            return;
        };
        vals = promote(vm.alloc, v_list.L);
    }
    const res = if (n == 1) blk: {
        const d = Dict.init(vm.alloc, keys, vals) catch {
            keys.deinit(vm.alloc);
            vals.deinit(vm.alloc);
            for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
            vm.stack_len = start;
            pushErr(vm, .memory);
            return;
        };
        break :blk V{ .m = d };
    } else dict(vm, keys, vals);
    if (n > 1) {
        keys.deinit(vm.alloc);
        vals.deinit(vm.alloc);
    }
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    pushOr(vm, res);
}

pub export fn cps_make_table(vm: *VM, op: u32) callconv(.c) void {
    const n: u8 = @truncate(op);
    const start = vm.stack_len - 2 * @as(usize, n);
    const keys = if (n == 1) enlist(vm.alloc, vm.stack[start]) else blk: {
        const list = V.Values(vm.alloc, vm.stack[start .. start + n]) catch {
            for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
            vm.stack_len = start;
            pushErr(vm, .memory);
            return;
        };
        break :blk promote(vm.alloc, list.L);
    };
    const vals = if (n == 1) enlist(vm.alloc, vm.stack[start + 1]) else blk: {
        const list = V.Values(vm.alloc, vm.stack[start + n .. start + 2 * n]) catch {
            keys.deinit(vm.alloc);
            for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
            vm.stack_len = start;
            pushErr(vm, .memory);
            return;
        };
        break :blk promote(vm.alloc, list.L);
    };
    const d = Dict.init(vm.alloc, keys, vals) catch {
        keys.deinit(vm.alloc);
        vals.deinit(vm.alloc);
        for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
        vm.stack_len = start;
        pushErr(vm, .memory);
        return;
    };
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    pushOr(vm, V{ .M = d });
}

pub export fn cps_make_partial(vm: *VM, op: u32) callconv(.c) void {
    const argc: u8 = @truncate(op);
    const mask: u8 = @truncate(op >> 8);
    const args_start = vm.stack_len - argc;
    const stack_args = vm.stack[args_start..vm.stack_len];
    const func_val = vm.stack[args_start - 1];

    var base_ref: Fn = undefined;
    var existing: [8]V = .{.blank} ** 8;
    var existing_fill: u8 = 0;
    if (func_val == .partial) {
        const p = func_val.asPartial();
        base_ref = p.ref;
        existing = p.args;
        existing_fill = p.fill;
    } else if (func_val == .func) {
        base_ref = func_val.func;
    } else {
        for (vm.stack[args_start - 1 .. vm.stack_len]) |*v| v.deinit(vm.alloc);
        vm.stack_len = args_start - 1;
        pushErr(vm, .@"type");
        return;
    }

    const arity = base_ref.getRealArity();
    var merged: [8]V = .{.blank} ** 8;
    var fill: u8 = 0;
    for (0..arity) |i| {
        if (existing_fill & (@as(u8, 1) << @intCast(i)) != 0) {
            merged[i] = existing[i].ref();
            fill |= @as(u8, 1) << @intCast(i);
        }
    }
    var arg_idx: usize = 0;
    for (0..arity) |i| {
        if (fill & (@as(u8, 1) << @intCast(i)) == 0) {
            const should_fill = if (existing_fill != 0) true else ((mask >> @intCast(i)) & 1) != 0;
            if (should_fill and arg_idx < argc) {
                merged[i] = stack_args[arg_idx].ref();
                fill |= @as(u8, 1) << @intCast(i);
                arg_idx += 1;
            }
        }
    }

    const p = vm.partial_pool.create(vm.alloc) catch {
        for (vm.stack[args_start - 1 .. vm.stack_len]) |*v| v.deinit(vm.alloc);
        vm.stack_len = args_start - 1;
        pushErr(vm, .memory);
        return;
    };
    p.* = .{ .pool = &vm.partial_pool, .rc = 1, .fill = fill, .arity = arity, ._pad = 0, .ref = base_ref, .args = merged };

    for (vm.stack[args_start - 1 .. vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = args_start - 1;
    pushOr(vm, .{ .partial = p });
}

pub export fn cps_derive(vm: *VM, op: u32) callconv(.c) void {
    const adv: Adverb = @enumFromInt(@as(u8, @truncate(op)));
    const base_v = vm.pop();
    const derived: Fn = if (base_v == .func) blk: {
        const ref = base_v.func;
        base_v.deinit(vm.alloc);
        break :blk switch (ref.getKind()) {
            .builtin => Fn.makeDerivedBuiltin(ref.getOp(), adv),
            .lambda  => Fn.makeDerivedLambda(ref.idx, adv),
            else => blk2: {
                const idx = vm.fn_tables.addDerived(.{ .base = V{ .func = ref }, .adverb = adv }) catch {
                    pushErr(vm, .memory);
                    return;
                };
                break :blk2 Fn.makeDerivedTable(idx);
            },
        };
    } else blk: {
        const idx = vm.fn_tables.addDerived(.{ .base = base_v, .adverb = adv }) catch {
            pushErr(vm, .memory);
            return;
        };
        break :blk Fn.makeDerivedTable(idx);
    };
    pushOr(vm, .{ .func = derived });
}

pub export fn cps_amend(vm: *VM, op: u32) callconv(.c) void {
    const argc: u8 = @truncate(op);
    const start = vm.stack_len - argc;
    const res = amend_mod.amend(vm, vm.stack[start..vm.stack_len]) catch {
        for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
        vm.stack_len = start;
        pushErr(vm, .memory);
        return;
    };
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    pushOr(vm, res);
}

pub export fn cps_dmend(vm: *VM, op: u32) callconv(.c) void {
    const argc: u8 = @truncate(op);
    const start = vm.stack_len - argc;
    const res = amend_mod.dmend(vm, vm.stack[start..vm.stack_len]) catch {
        for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
        vm.stack_len = start;
        pushErr(vm, .memory);
        return;
    };
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    pushOr(vm, res);
}

// ── 2-byte operand helpers ────────────────────────────────────────────────────

pub export fn cps_int(vm: *VM, op: u32) callconv(.c) void {
    const v: i32 = @as(i16, @bitCast(@as(u16, @truncate(op))));
    pushOr(vm, .{ .i = v });
}

pub export fn cps_command(vm: *VM) callconv(.c) void {
    var cmd_v = vm.pop();
    defer cmd_v.deinit(vm.alloc);
    const bytes = cmd_v.C.slice();
    const sep1 = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    const verb = bytes[0..sep1];
    const rest = if (sep1 < bytes.len) bytes[sep1 + 1 ..] else "";
    const sep2 = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    const n = std.fmt.parseInt(u32, rest[0..sep2], 10) catch 1;
    const args = if (sep2 < rest.len) std.mem.trim(u8, rest[sep2 + 1 ..], " \t") else "";
    const result = command.exec(vm, verb, n, args) catch {
        pushErr(vm, .memory);
        return;
    };
    pushOr(vm, result);
}

// ── Branch helper ─────────────────────────────────────────────────────────────
//
// JumpFalse / JumpTrue stencils call this to pop TOS and decide which
// continuation to take. Returning `bool` (not a V) is intentional: bool
// fits in a single C-ABI register and avoids the value-copy overhead.

pub export fn cps_pop_truthy(vm: *VM) callconv(.c) bool {
    const v = vm.pop();
    defer v.deinit(vm.alloc);
    return v.isTrue();
}

// ── Return (terminal stencil) ─────────────────────────────────────────────────
//
// In CPS-land each lambda is a separate JIT-compiled C function. Calling
// a lambda is a BL to its entry; returning is a `ret`. cps_return does
// the bookkeeping doReturn did in the interpreter: pop the result, pop
// the frame the caller pushed for us, clean up locals between
// [frame.result_slot, stack_len), restore the parent chunk, push the
// result back so the caller's next stencil sees it.

/// Force the linker to retain every cps_* symbol even when ReleaseFast's
/// dead-code elimination cannot see a Zig call site. The JIT looks these
/// up by name at patch time — they must be in the final binary.
/// Take the address at runtime via `anchor()` so LLVM cannot dead-strip.
pub const force_keep = [_]*const anyopaque{
    @ptrCast(&cps_nop),
    @ptrCast(&cps_gap),
    @ptrCast(&cps_drop),
    @ptrCast(&cps_dup),
    @ptrCast(&cps_const),
    @ptrCast(&cps_int),
    @ptrCast(&cps_local),
    @ptrCast(&cps_local_last),
    @ptrCast(&cps_global),
    @ptrCast(&cps_assign_local),
    @ptrCast(&cps_assign_global),
    @ptrCast(&cps_apply1),
    @ptrCast(&cps_apply2),
    @ptrCast(&cps_make_list),
    @ptrCast(&cps_make_dict),
    @ptrCast(&cps_make_table),
    @ptrCast(&cps_make_partial),
    @ptrCast(&cps_derive),
    @ptrCast(&cps_amend),
    @ptrCast(&cps_dmend),
    @ptrCast(&cps_command),
    @ptrCast(&cps_pop_truthy),
    @ptrCast(&cps_return),
};

/// Mutable runtime anchor for the force_keep table. VM.create writes
/// each pointer into `cps_anchor_sink` (volatile) so the optimizer is
/// forced to preserve every function in the table.
pub var cps_anchor_ptr: *const [23]*const anyopaque = undefined;
pub var cps_anchor_sink: usize = 0;

pub fn anchor() *const [23]*const anyopaque {
    return &force_keep;
}

pub export fn cps_return(vm: *VM) callconv(.c) void {
    const result = vm.pop();
    if (vm.frames_len == 0) {
        // Top-level return: leave the result on the stack.
        pushOr(vm, result);
        return;
    }
    const frame = vm.popFrame();
    if (vm.frames_len == 0) {
        for (vm.stack[0..vm.stack_len]) |*v| v.deinit(vm.alloc);
        vm.stack_len = 0;
        pushOr(vm, result);
        return;
    }
    const parent_idx = vm.currentFrame().lambda_idx;
    vm.current_chunk = if (parent_idx == std.math.maxInt(u24)) vm.chunk
                       else vm.fn_tables.lambdaAt(parent_idx).chunk;
    for (vm.stack[frame.result_slot..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = frame.result_slot;
    pushOr(vm, result);
}
