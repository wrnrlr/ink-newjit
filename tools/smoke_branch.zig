//! Phase-2.2b branch-stencil smoke test.
//!
//! Builds two chains, both passing through a `jump_false` branch:
//!
//!   chain A: push 1 → jump_false → [next: push 42, return] [taken: push 99, return]
//!   chain B: push 0 → jump_false → [same]
//!
//! Chain A pushes 1, jump_false pops it, isTrue() == true → take `next` →
//!   push 42 → return → stack[0] = 42.
//! Chain B pushes 0, jump_false pops it, isTrue() == false → take `taken` →
//!   push 99 → return → stack[0] = 99.
//!
//! Validates that branch26 holes with target=.taken are patched correctly
//! and that the two trailing tail-calls in stencil_jump_false land at
//! different runtime addresses.

const std = @import("std");
const stencil_data = @import("stencil_data");

const VM = extern struct {
    sp: u32 = 0,
    stack: [16]i32 = .{0} ** 16,
};

export fn __vm_pop_i32(vm: *VM) callconv(.c) i32 {
    vm.sp -= 1;
    return vm.stack[vm.sp];
}
export fn __vm_push_i32(vm: *VM, v: i32) callconv(.c) void {
    vm.stack[vm.sp] = v;
    vm.sp += 1;
}
export fn __vm_pop_bool(vm: *VM) callconv(.c) bool {
    vm.sp -= 1;
    return vm.stack[vm.sp] != 0;
}

// Stub for stencil_jump_false's BL into cps_pop_truthy. Our hand-rolled
// VM stores ints, so "truthy" = nonzero — same shape as cps_pop_truthy.
export fn cps_pop_truthy(vm: *VM) callconv(.c) bool {
    vm.sp -= 1;
    return vm.stack[vm.sp] != 0;
}

// Stub for stencil_return's BL into cps_return. No frame to pop here.
export fn cps_return(vm: *VM) callconv(.c) void { _ = vm; }

fn patchBranch26(instr_addr: usize, target_addr: usize) void {
    const pc: i64 = @intCast(instr_addr);
    const t:  i64 = @intCast(target_addr);
    const disp: i64 = @divExact(t - pc, 4);
    std.debug.assert(disp >= -(1 << 25) and disp < (1 << 25));
    const imm26: u32 = @intCast(disp & 0x03FF_FFFF);
    const ptr: *u32 = @ptrFromInt(instr_addr);
    ptr.* = (ptr.* & 0xFC00_0000) | imm26;
}

fn patchAdrpPage21(instr_addr: usize, target_addr: usize) void {
    const pc_page: i64 = @intCast(instr_addr & ~@as(usize, 0xFFF));
    const tgt_page: i64 = @intCast(target_addr & ~@as(usize, 0xFFF));
    const page_disp: i64 = (tgt_page - pc_page) >> 12;
    const imm21: u32 = @bitCast(@as(i32, @intCast(page_disp & 0x1F_FFFF)));
    const immlo: u32 = imm21 & 0x3;
    const immhi: u32 = (imm21 >> 2) & 0x7_FFFF;
    const ptr: *u32 = @ptrFromInt(instr_addr);
    ptr.* = (ptr.* & 0x9F_00_00_1F) | (immlo << 29) | (immhi << 5);
}

fn patchAddPageoff12(instr_addr: usize, target_addr: usize) void {
    const offset: u32 = @intCast(target_addr & 0xFFF);
    const ptr: *u32 = @ptrFromInt(instr_addr);
    ptr.* = (ptr.* & 0xFFC0_03FF) | (offset << 10);
}

const PAGE_SIZE = 16384;
extern fn pthread_jit_write_protect_np(enabled: c_int) void;

fn mapJit(size: usize) ![*]align(PAGE_SIZE) u8 {
    const prot  = std.c.PROT{ .READ = true, .WRITE = true, .EXEC = true };
    const flags = std.c.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true };
    const raw = std.c.mmap(null, size, prot, flags, -1, 0);
    if (raw == std.c.MAP_FAILED) return error.MmapFailed;
    return @ptrCast(@alignCast(raw));
}

fn lookupExternal(symbol: []const u8) ?usize {
    var name = symbol;
    while (name.len > 0 and name[0] == '_') name = name[1..];
    if (std.mem.eql(u8, name, "vm_pop_i32"))    return @intFromPtr(&__vm_pop_i32);
    if (std.mem.eql(u8, name, "vm_push_i32"))   return @intFromPtr(&__vm_push_i32);
    if (std.mem.eql(u8, name, "vm_pop_bool"))   return @intFromPtr(&__vm_pop_bool);
    if (std.mem.eql(u8, name, "cps_pop_truthy")) return @intFromPtr(&cps_pop_truthy);
    if (std.mem.eql(u8, name, "cps_return"))    return @intFromPtr(&cps_return);
    return null;
}

const Placement = struct {
    name: []const u8,
    code_offset: usize,
    operand_slot_offset: usize,
    operand_value: u64,
    /// Override for the .next link if non-zero (otherwise wires to places[i+1]).
    next_override: usize = 0,
    /// Override for the .taken link if non-zero.
    taken_override: usize = 0,
    stencil: *const stencil_data.Stencil,
};

const ChainEntry = struct {
    name: []const u8,
    s: *const stencil_data.Stencil,
    op: u64,
    next_idx: usize = 0,      // 0 = chain[i+1]
    taken_idx: usize = 0,     // 0 = no taken (i.e. not a branch)
};

fn buildChain(buf: [*]u8, chain: []const ChainEntry, places_out: []Placement) usize {
    var cursor: usize = 0;
    for (chain, 0..) |c, i| {
        const code_offset = std.mem.alignForward(usize, cursor, 4);
        cursor = code_offset + c.s.bytes.len;
        var operand_offset: usize = 0;
        for (c.s.holes) |h| if (h.target == .operand) {
            operand_offset = std.mem.alignForward(usize, cursor, 8);
            cursor = operand_offset + 8;
            break;
        };
        places_out[i] = .{
            .name = c.name, .code_offset = code_offset,
            .operand_slot_offset = operand_offset, .operand_value = c.op,
            .stencil = c.s,
        };
        @memcpy(buf[code_offset .. code_offset + c.s.bytes.len], c.s.bytes);
        if (operand_offset != 0) {
            const slot_ptr: *u64 = @ptrCast(@alignCast(buf + operand_offset));
            slot_ptr.* = c.op;
        }
    }
    // Wire overrides from the chain spec.
    for (chain, 0..) |c, i| {
        if (c.next_idx != 0) {
            places_out[i].next_override = @intFromPtr(buf) + places_out[c.next_idx].code_offset;
        }
        if (c.taken_idx != 0) {
            places_out[i].taken_override = @intFromPtr(buf) + places_out[c.taken_idx].code_offset;
        }
    }
    return cursor;
}

fn patchChain(buf: [*]u8, places: []const Placement) void {
    for (places, 0..) |p, i| {
        const code_base = @intFromPtr(buf) + p.code_offset;
        const operand_addr = @intFromPtr(buf) + p.operand_slot_offset;
        const next_addr = if (p.next_override != 0) p.next_override
                          else if (i + 1 < places.len)
                              @intFromPtr(buf) + places[i + 1].code_offset
                          else 0;
        const taken_addr = p.taken_override;
        for (p.stencil.holes) |h| {
            const instr_addr = code_base + h.offset;
            switch (h.kind) {
                .branch26 => {
                    const target: usize = switch (h.target) {
                        .external => lookupExternal(h.symbol)
                            orelse fatalFmt("no impl for external {s}", .{h.symbol}),
                        .next => next_addr,
                        .taken => taken_addr,
                        .operand => unreachable,
                    };
                    patchBranch26(instr_addr, target);
                },
                .page21 => patchAdrpPage21(instr_addr, operand_addr),
                .pageoff12 => patchAddPageoff12(instr_addr, operand_addr),
            }
        }
    }
}

pub fn main(_: std.process.Init.Minimal) !void {
    const const_i = stencil_data.get("const_i") orelse fatal("const_i missing");
    const jf      = stencil_data.get("jump_false") orelse fatal("jump_false missing");
    const ret     = stencil_data.get("return") orelse fatal("return missing");

    const buf = try mapJit(PAGE_SIZE);
    defer _ = std.c.munmap(@ptrCast(@alignCast(buf)), PAGE_SIZE);

    pthread_jit_write_protect_np(0);

    // Chain layout:
    //   [0] const_i COND  — push COND
    //   [1] jump_false    — pop; isTrue ? next=[2] : taken=[4]
    //   [2] const_i 42    — push 42
    //   [3] return        — terminal
    //   [4] const_i 99    — push 99
    //   [5] return        — terminal
    var places: [6]Placement = undefined;
    const chain_spec = [_]ChainEntry{
        .{ .name = "push_cond",  .s = const_i, .op = 1,  .next_idx = 1 },
        .{ .name = "jf",         .s = jf,      .op = 0,  .next_idx = 2, .taken_idx = 4 },
        .{ .name = "push_next",  .s = const_i, .op = 42, .next_idx = 3 },
        .{ .name = "ret_next",   .s = ret,     .op = 0  },
        .{ .name = "push_taken", .s = const_i, .op = 99, .next_idx = 5 },
        .{ .name = "ret_taken",  .s = ret,     .op = 0  },
    };

    // Run twice: once with cond=1 (expect 42), once with cond=0 (expect 99).
    inline for (.{ .{ 1, 42 }, .{ 0, 99 } }) |case| {
        const cond: u64 = case[0];
        const expected: i32 = case[1];
        var mutable_spec = chain_spec;
        mutable_spec[0].op = cond;
        _ = buildChain(buf, &mutable_spec, &places);
        patchChain(buf, &places);

        pthread_jit_write_protect_np(1);

        var vm = VM{};
        const Entry = *const fn (*VM) callconv(.c) void;
        const entry: Entry = @ptrCast(@alignCast(buf + places[0].code_offset));
        entry(&vm);

        if (vm.sp != 1 or vm.stack[0] != expected) {
            std.debug.print("branch: FAIL cond={d} got sp={d} stack[0]={d} (expected {d})\n",
                .{ cond, vm.sp, vm.stack[0], expected });
            std.process.exit(1);
        }
        std.debug.print("branch: OK cond={d} → {d}\n", .{ cond, vm.stack[0] });

        pthread_jit_write_protect_np(0); // back to writable for the next layout
    }
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("branch: {s}\n", .{msg});
    std.process.exit(1);
}

fn fatalFmt(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("branch: ", .{});
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}
