const std = @import("std");
const value = @import("../noun/value.zig");
const V = value.V;
const N = value.N;
const VM = @import("vm.zig").VM;
const exec_mod = @import("../primitive/verb/exec.zig");

pub fn apply(vm: *VM, sym_idx: u32, args: []const V) anyerror!V {
    const name = vm.getSymbol(sym_idx);

    if (std.mem.eql(u8, name, "t")) {
        var ts: std.posix.timespec = undefined;
        _ = std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
        const us: i64 = ts.sec * 1_000_000 + @divTrunc(ts.nsec, 1000);
        return .{ .i = @truncate(us) };
    }
    if (std.mem.eql(u8, name, "argv")) {
        return vm.argv.ref();
    }
    if (std.mem.eql(u8, name, "env")) {
        return getEnv(vm);
    }
    if (std.mem.eql(u8, name, "prng")) {
        const has_arg = args.len == 1 and args[0] != .blank;
        if (!has_arg) return getPrngState(vm);
        return setPrngState(vm, args[0]);
    }
    if (std.mem.eql(u8, name, "x")) {
        if (args.len == 1 and args[0] != .blank) return forkExec(vm, args[0], null);
        if (args.len == 2 and args[0] != .blank) return forkExec(vm, args[0], args[1]);
        return V{ .err = .rank };
    }
    return V{ .err = .@"type" };
}

fn getPrngState(vm: *VM) V {
    const s = vm.prng.s;
    var arr: [8]i32 = undefined;
    for (s, 0..) |u, i| {
        arr[i * 2]     = @bitCast(@as(u32, @truncate(u)));
        arr[i * 2 + 1] = @bitCast(@as(u32, @truncate(u >> 32)));
    }
    return V.Ints(vm.alloc, &arr) catch V{ .err = .memory };
}

fn setPrngState(vm: *VM, v: V) V {
    if (v.tag() != .I or v.I.ptr.len != 8) return V{ .err = .length };
    const src = v.I.slice();
    for (0..4) |i| {
        const lo: u32 = @bitCast(src[i * 2]);
        const hi: u32 = @bitCast(src[i * 2 + 1]);
        vm.prng.s[i] = @as(u64, lo) | (@as(u64, hi) << 32);
    }
    return .blank;
}

fn getEnv(vm: *VM) anyerror!V {
    var n: usize = 0;
    { var i: usize = 0; while (std.c.environ[i]) |_| : (i += 1) n += 1; }

    const keys_raw = try vm.alloc.alloc(u32, n);
    defer vm.alloc.free(keys_raw);

    const vals_n = try N(V).init(vm.alloc, n);
    errdefer (V{ .L = vals_n }).deinit(vm.alloc);
    @memset(vals_n.slice(), .blank);

    var i: usize = 0;
    var j: usize = 0;
    while (std.c.environ[i]) |entry_ptr| : (i += 1) {
        const entry = std.mem.span(entry_ptr);
        const sep = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        keys_raw[j] = try vm.intern(entry[0..sep]);
        vals_n.slice()[j] = try V.Chars(vm.alloc, entry[sep + 1..]);
        j += 1;
    }
    const actual_n = j;

    const keys_v = try V.Symbols(vm.alloc, keys_raw[0..actual_n]);
    errdefer keys_v.deinit(vm.alloc);

    // Resize the list value to actual count (set remaining slots to blank already done above)
    vals_n.ptr.len = @intCast(actual_n);

    return V{ .m = try value.Dict.init(vm.alloc, keys_v, V{ .L = vals_n }) };
}

fn forkExec(vm: *VM, cmd: V, stdin_v: ?V) anyerror!V {
    return exec_mod.execFromV(vm, cmd, stdin_v);
}
