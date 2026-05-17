//! Smoke test for the AOT stencil extractor + runtime patcher.
//!
//! Builds a chain `const_i 5 → const_i 7 → add_ii → return` in a W^X
//! JIT page. Each stencil's bytes are copied verbatim; every hole is
//! patched:
//!
//!   - branch26 (B/BL): external helpers + next-link
//!   - page21 + pageoff12 (ADRP+ADD): operand-slot address
//!
//! Each operand-bearing stencil gets an 8-byte data slot allocated
//! immediately after its code; the ADRP+ADD pair is patched to point at
//! that slot, and the slot holds the actual operand value.
//!
//! Expected: VM stack ends with sp=1, stack[0]=12.

const std = @import("std");
const stencil_data = @import("stencil_data");

// ── Tiny VM the stencils talk to ──────────────────────────────────────────────
//
// The stencil source declared three extern helpers (__vm_pop_i32,
// __vm_push_i32, __vm_pop_bool). We provide local implementations and
// patch the stencils' BL relocations to point at these addresses.

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

// ── Patcher ───────────────────────────────────────────────────────────────────
//
// branch26: B/BL imm26. The instruction encodes (target - PC) / 4 as a
// signed 26-bit field in bits[25:0]. Patching preserves the opcode (top
// 6 bits) and rewrites the displacement.

fn patchBranch26(instr_addr: usize, target_addr: usize) void {
    const pc: i64 = @intCast(instr_addr);
    const t:  i64 = @intCast(target_addr);
    const disp: i64 = @divExact(t - pc, 4);
    std.debug.assert(disp >= -(1 << 25) and disp < (1 << 25));
    const imm26: u32 = @intCast(disp & 0x03FF_FFFF);
    const ptr: *u32 = @ptrFromInt(instr_addr);
    ptr.* = (ptr.* & 0xFC00_0000) | imm26;
}

/// Patch an ADRP instruction's 21-bit page displacement so it points at
/// `target_addr`'s 4 KB page. The immediate is split across bits 30:29
/// (immlo) and 23:5 (immhi) of the ADRP instruction word.
fn patchAdrpPage21(instr_addr: usize, target_addr: usize) void {
    const pc_page: i64 = @intCast(instr_addr & ~@as(usize, 0xFFF));
    const tgt_page: i64 = @intCast(target_addr & ~@as(usize, 0xFFF));
    const page_disp: i64 = (tgt_page - pc_page) >> 12;
    std.debug.assert(page_disp >= -(1 << 20) and page_disp < (1 << 20));
    const imm21: u32 = @bitCast(@as(i32, @intCast(page_disp & 0x1F_FFFF)));
    const immlo: u32 = imm21 & 0x3;
    const immhi: u32 = (imm21 >> 2) & 0x7_FFFF;
    const ptr: *u32 = @ptrFromInt(instr_addr);
    ptr.* = (ptr.* & 0x9F_00_00_1F) | (immlo << 29) | (immhi << 5);
}

/// Patch an ADD-immediate instruction's 12-bit offset (bits 21:10) so it
/// adds `target_addr`'s offset within its 4 KB page to the ADRP result.
fn patchAddPageoff12(instr_addr: usize, target_addr: usize) void {
    const offset: u32 = @intCast(target_addr & 0xFFF);
    const ptr: *u32 = @ptrFromInt(instr_addr);
    ptr.* = (ptr.* & 0xFFC0_03FF) | (offset << 10);
}

// ── JIT memory (W^X-aware on Apple Silicon) ───────────────────────────────────

const PAGE_SIZE = 16384;
extern fn pthread_jit_write_protect_np(enabled: c_int) void;

fn mapJit(size: usize) ![*]align(PAGE_SIZE) u8 {
    const prot  = std.c.PROT{ .READ = true, .WRITE = true, .EXEC = true };
    const flags = std.c.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true };
    const raw = std.c.mmap(null, size, prot, flags, -1, 0);
    if (raw == std.c.MAP_FAILED) return error.MmapFailed;
    return @ptrCast(@alignCast(raw));
}

// ── Driver ────────────────────────────────────────────────────────────────────

fn lookupExternal(symbol: []const u8) ?usize {
    // The extractor preserves Mach-O's leading underscores (so symbols look
    // like "___vm_pop_i32"). Strip them on lookup.
    var name = symbol;
    while (name.len > 0 and name[0] == '_') name = name[1..];
    if (std.mem.eql(u8, name, "vm_pop_i32"))  return @intFromPtr(&__vm_pop_i32);
    if (std.mem.eql(u8, name, "vm_push_i32")) return @intFromPtr(&__vm_push_i32);
    if (std.mem.eql(u8, name, "vm_pop_bool")) return @intFromPtr(&__vm_pop_bool);
    return null;
}

/// One stencil placed in the JIT buffer plus its (optional) operand slot.
const Placement = struct {
    name: []const u8,
    /// Offset of the stencil's first instruction within the JIT page.
    code_offset: usize,
    /// Offset of the 8-byte operand data slot (0 if the stencil has none).
    operand_slot_offset: usize,
    /// Operand value to write into the data slot.
    operand_value: u64,
    stencil: *const stencil_data.Stencil,
};

pub fn main(_: std.process.Init.Minimal) !void {
    const const_i = stencil_data.get("const_i") orelse fatal("const_i missing");
    const add_ii  = stencil_data.get("add_ii")  orelse fatal("add_ii missing");
    const ret     = stencil_data.get("return")  orelse fatal("return missing");

    const buf = try mapJit(PAGE_SIZE);
    defer _ = std.c.munmap(@ptrCast(@alignCast(buf)), PAGE_SIZE);

    pthread_jit_write_protect_np(0); // writable

    // Layout. Each operand-bearing stencil gets an 8-byte slot
    // immediately after its code; the ADRP+ADD pair is patched to point
    // there. Slot offsets are word-aligned, which ADRP requires for the
    // 4 KB page-relative encoding.
    var cursor: usize = 0;
    var places: [4]Placement = undefined;
    const chain = [_]struct { name: []const u8, s: *const stencil_data.Stencil, op: u64 }{
        .{ .name = "const_5",  .s = const_i, .op = 5  },
        .{ .name = "const_7",  .s = const_i, .op = 7  },
        .{ .name = "add",      .s = add_ii,  .op = 0  },
        .{ .name = "ret",      .s = ret,     .op = 0  },
    };
    for (chain, 0..) |c, i| {
        const code_offset = std.mem.alignForward(usize, cursor, 4);
        cursor = code_offset + c.s.bytes.len;
        var operand_offset: usize = 0;
        // Allocate an operand slot if this stencil reads __ink_hole_operand.
        for (c.s.holes) |h| if (h.target == .operand) {
            operand_offset = std.mem.alignForward(usize, cursor, 8);
            cursor = operand_offset + 8;
            break;
        };
        places[i] = .{
            .name = c.name,
            .code_offset = code_offset,
            .operand_slot_offset = operand_offset,
            .operand_value = c.op,
            .stencil = c.s,
        };
        @memcpy(buf[code_offset .. code_offset + c.s.bytes.len], c.s.bytes);
        if (operand_offset != 0) {
            const slot_ptr: *u64 = @ptrCast(@alignCast(buf + operand_offset));
            slot_ptr.* = c.op;
        }
    }

    // Patch every hole in every non-terminal stencil.
    for (places, 0..) |p, i| {
        if (p.stencil.is_terminal) continue;
        const code_base = @intFromPtr(buf) + p.code_offset;
        const operand_addr = @intFromPtr(buf) + p.operand_slot_offset;
        const next_addr = @intFromPtr(buf) + places[i + 1].code_offset;
        for (p.stencil.holes) |h| {
            const instr_addr = code_base + h.offset;
            switch (h.kind) {
                .branch26 => {
                    const target: usize = switch (h.target) {
                        .external => lookupExternal(h.symbol)
                            orelse fatalFmt("no impl for external {s}", .{h.symbol}),
                        .next => next_addr,
                        .taken, .operand => unreachable,
                    };
                    patchBranch26(instr_addr, target);
                },
                .page21 => {
                    std.debug.assert(h.target == .operand);
                    patchAdrpPage21(instr_addr, operand_addr);
                },
                .pageoff12 => {
                    std.debug.assert(h.target == .operand);
                    patchAddPageoff12(instr_addr, operand_addr);
                },
            }
        }
    }

    pthread_jit_write_protect_np(1); // executable

    var vm = VM{};
    const Entry = *const fn (*VM) callconv(.c) void;
    const entry: Entry = @ptrCast(@alignCast(buf + places[0].code_offset));
    entry(&vm);

    if (vm.sp != 1 or vm.stack[0] != 12) {
        std.debug.print("smoke: FAIL — sp={d} stack[0]={d} (expected sp=1 stack[0]=12)\n",
            .{ vm.sp, vm.stack[0] });
        std.process.exit(1);
    }
    std.debug.print("smoke: OK — const_i(5) → const_i(7) → add_ii → return → {d}\n", .{vm.stack[0]});
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("smoke: {s}\n", .{msg});
    std.process.exit(1);
}

fn fatalFmt(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("smoke: ", .{});
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}
