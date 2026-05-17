//! Phase-1 smoke test for the AOT stencil extractor + runtime patcher.
//!
//! Reads the generated `stencil_data.zig`, allocates a W^X JIT page,
//! copies `add_ii` followed by `return`, patches every branch26 hole
//! (external calls + next pointer), then invokes the chain.
//!
//! With a tiny on-stack VM seeded with [3, 4], the chain should pop both,
//! push their sum (7), and return cleanly. Any deviation (SIGILL, wrong
//! result, segfault) means a relocation or W^X bug.
//!
//! Operand-bearing stencils (const_i with the ADRP+LDR pair) are not yet
//! tested here — that path is covered in Phase 2 when stencils start
//! carrying immediates.

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

const Placement = struct {
    name: []const u8,
    /// Offset of this stencil's first byte within the JIT page.
    offset: usize,
    /// Stencil metadata from the generated table.
    stencil: *const stencil_data.Stencil,
};

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

pub fn main(_: std.process.Init.Minimal) !void {
    const add_ii = stencil_data.get("add_ii") orelse {
        std.debug.print("smoke: add_ii missing from stencil_data\n", .{});
        std.process.exit(1);
    };
    const ret = stencil_data.get("return") orelse {
        std.debug.print("smoke: return missing from stencil_data\n", .{});
        std.process.exit(1);
    };

    const buf = try mapJit(PAGE_SIZE);
    defer _ = std.c.munmap(@ptrCast(@alignCast(buf)), PAGE_SIZE);

    pthread_jit_write_protect_np(0); // writable

    // Lay out the chain: add_ii at offset 0, return immediately after.
    const places = [_]Placement{
        .{ .name = "add_ii", .offset = 0,                   .stencil = add_ii },
        .{ .name = "return", .offset = add_ii.bytes.len,    .stencil = ret    },
    };

    for (places) |p| {
        @memcpy(buf[p.offset .. p.offset + p.stencil.bytes.len], p.stencil.bytes);
    }

    // Patch holes in every non-terminal stencil.
    for (places) |p| {
        if (p.stencil.is_terminal) continue;
        for (p.stencil.holes) |h| {
            const instr_addr = @intFromPtr(buf) + p.offset + h.offset;
            switch (h.kind) {
                .branch26 => {
                    const target: usize = switch (h.target) {
                        .external => lookupExternal(h.symbol) orelse {
                            std.debug.print("smoke: no impl for external {s}\n", .{h.symbol});
                            std.process.exit(1);
                        },
                        .next => @intFromPtr(buf) + places[1].offset,
                        .taken => unreachable, // add_ii has no taken hole
                        .operand => unreachable,
                    };
                    patchBranch26(instr_addr, target);
                },
                .page21, .pageoff12 => {
                    std.debug.print("smoke: operand patching not implemented yet\n", .{});
                    std.process.exit(1);
                },
            }
        }
    }

    pthread_jit_write_protect_np(1); // executable

    // Run it: seed the stack with [3, 4], call add_ii's entry, expect sp=1 with stack[0]=7.
    var vm = VM{};
    __vm_push_i32(&vm, 3);
    __vm_push_i32(&vm, 4);

    const Entry = *const fn (*VM) callconv(.c) void;
    const entry: Entry = @ptrCast(@alignCast(buf));
    entry(&vm);

    if (vm.sp != 1 or vm.stack[0] != 7) {
        std.debug.print("smoke: FAIL — sp={d} stack[0]={d} (expected sp=1 stack[0]=7)\n",
            .{ vm.sp, vm.stack[0] });
        std.process.exit(1);
    }
    std.debug.print("smoke: OK — add_ii(3, 4) = {d} via JIT chain\n", .{vm.stack[0]});
}
