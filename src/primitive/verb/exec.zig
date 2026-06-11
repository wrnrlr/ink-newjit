const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;

// Core: spawn argv with optional stdin bytes, capture stdout as chars V.
// For small stdin (< pipe buffer ~64KB) the write-then-read sequence is safe.
pub fn execImpl(vm: *VM, argv: []const []const u8, stdin_bytes: ?[]const u8) V {
    const io_obj = std.Io.Threaded.global_single_threaded.io();
    if (stdin_bytes) |stdin| {
        var child = std.process.spawn(io_obj, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return V{ .err = .io };
        defer child.kill(io_obj);
        if (child.stdin) |sin| {
            sin.writeStreamingAll(io_obj, stdin) catch {};
            sin.close(io_obj);
            child.stdin = null;
        }
        var scratch: [4096]u8 = undefined;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(vm.alloc);
        if (child.stdout) |sout| {
            var r = sout.readerStreaming(io_obj, &scratch);
            r.interface.appendRemainingUnlimited(vm.alloc, &out) catch {};
        }
        _ = child.wait(io_obj) catch {};
        return V.Chars(vm.alloc, out.items) catch V{ .err = .memory };
    } else {
        const result = std.process.run(vm.alloc, io_obj, .{
            .argv = argv,
        }) catch return V{ .err = .io };
        defer vm.alloc.free(result.stdout);
        defer vm.alloc.free(result.stderr);
        return V.Chars(vm.alloc, result.stdout) catch V{ .err = .memory };
    }
}

// Build argv from a list V. Returns heap-allocated slice; caller must free.
fn argvFromList(vm: *VM, x: V) ?[]const []const u8 {
    const items = x.L.slice();
    const argv = vm.alloc.alloc([]const u8, items.len) catch return null;
    for (items, 0..) |item, i| {
        argv[i] = switch (item.tag()) {
            .C => item.C.slice(),
            .s => vm.getSymbol(item.s),
            else => {
                vm.alloc.free(argv);
                return null;
            },
        };
    }
    return argv;
}

// Public helper used by syms.zig for `x symbol dispatch.
// cmd: C (shell string), s (shell symbol), or L (argv list)
// stdin_v: optional stdin value (only C is supported)
pub fn execFromV(vm: *VM, cmd: V, stdin_v: ?V) V {
    const stdin_bytes: ?[]const u8 = if (stdin_v) |sv|
        if (sv.tag() == .C) sv.C.slice() else null
    else
        null;
    switch (cmd.tag()) {
        .C => {
            const argv: [3][]const u8 = .{ "sh", "-c", cmd.C.slice() };
            return execImpl(vm, &argv, stdin_bytes);
        },
        .s => {
            const argv: [3][]const u8 = .{ "sh", "-c", vm.getSymbol(cmd.s) };
            return execImpl(vm, &argv, stdin_bytes);
        },
        .L => {
            const argv = argvFromList(vm, cmd) orelse return V{ .err = .@"type" };
            defer vm.alloc.free(argv);
            return execImpl(vm, argv, stdin_bytes);
        },
        else => return V{ .err = .@"type" },
    }
}

// ---------------------------------------------------------------------------
// Monadic exec
// ---------------------------------------------------------------------------

fn execC(vm: *VM, x: V) V {
    const argv: [3][]const u8 = .{ "sh", "-c", x.C.slice() };
    return execImpl(vm, &argv, null);
}

fn execS(vm: *VM, x: V) V {
    const argv: [3][]const u8 = .{ "sh", "-c", vm.getSymbol(x.s) };
    return execImpl(vm, &argv, null);
}

fn execL(vm: *VM, x: V) V {
    const argv = argvFromList(vm, x) orelse return V{ .err = .@"type" };
    defer vm.alloc.free(argv);
    return execImpl(vm, argv, null);
}

pub const Exec = struct {
    pub const op = .exec;
    _C: VM.Monad = execC,
    _L: VM.Monad = execL,
    _s: VM.Monad = execS,
};

// ---------------------------------------------------------------------------
// Dyadic exec: stdin exec cmd
// ---------------------------------------------------------------------------

fn execCC(vm: *VM, x: V, y: V) V {
    const argv: [3][]const u8 = .{ "sh", "-c", y.C.slice() };
    return execImpl(vm, &argv, x.C.slice());
}

fn execCL(vm: *VM, x: V, y: V) V {
    const argv = argvFromList(vm, y) orelse return V{ .err = .@"type" };
    defer vm.alloc.free(argv);
    return execImpl(vm, argv, x.C.slice());
}

pub const ExecDyad = struct {
    pub const op = .exec;
    _C_C: VM.Dyad = execCC,
    _C_L: VM.Dyad = execCL,
};
