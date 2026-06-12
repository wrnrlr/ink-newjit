/// Event loop for IPC: poll open connections, accept new clients, dispatch handlers.
///
/// Activated by `\p port` in a script — the runner enters the event loop after
/// the script finishes if a port has been set.
///
/// Handler convention: `pg` and `ps` globals are the fallback handlers.
///   pg: {[msg] "echo: ", msg}   / return value sent back as reply
///   ps: {[msg] `0 0: msg}       / no reply (async style)
///
/// For GPU/FFI extensions that run their own event loop, the exported C function
/// `terse_poll()` does one non-blocking pass and can be called each frame.
const std = @import("std");
const posix = std.posix;
const V = @import("../noun/value.zig").V;
const VM = @import("vm.zig").VM;
const Call = @import("call.zig").Call;
const ffi = @import("../ffi.zig");
const verb_io = @import("../primitive/verb/io.zig");

const MAX_CONNS = 64;

/// Non-blocking single pass over all open connections.
/// Accepts new clients on listening sockets, reads and dispatches on connected ones.
/// `handler` overrides the global `pg`/`ps` fallbacks when non-blank.
pub fn pollOnce(vm: *VM, handler: V) void {
    if (vm.conns.map.count() == 0) return;

    var pfds: [MAX_CONNS]posix.pollfd = undefined;
    var ids: [MAX_CONNS]u32 = undefined;
    var n: usize = 0;

    var it = vm.conns.map.iterator();
    while (it.next()) |entry| {
        if (n >= MAX_CONNS) break;
        pfds[n] = .{
            .fd      = entry.value_ptr.fd(),
            .events  = posix.POLL.IN,
            .revents = 0,
        };
        ids[n] = entry.key_ptr.*;
        n += 1;
    }
    if (n == 0) return;

    const ready = posix.poll(pfds[0..n], 0) catch return;
    if (ready == 0) return;

    // Save/restore current_vm so FFI callbacks from within handlers work, without
    // clobbering the outer vm pointer when pollOnce is called from GPU frame code.
    const prev_vm = ffi.getCurrentVm();
    ffi.setCurrentVm(vm);
    defer ffi.restoreVm(prev_vm);

    for (pfds[0..n], ids[0..n]) |pfd, conn_id| {
        if (pfd.revents & posix.POLL.IN == 0) continue;
        const conn = vm.conns.get(conn_id) orelse continue;
        if (conn.isListening()) {
            acceptClient(vm, conn_id);
        } else {
            dispatchMsg(vm, conn_id, handler);
        }
    }
}

fn acceptClient(vm: *VM, listen_id: u32) void {
    const conn = vm.conns.get(listen_id) orelse return;
    const server = if (conn.server) |*s| s else return;
    const iol = std.Io.Threaded.global_single_threaded.io();
    const stream = server.accept(iol) catch return;
    _ = vm.conns.add(.{ .stream = stream }) catch {
        var s = stream;
        s.close(iol);
    };
}

fn dispatchMsg(vm: *VM, conn_id: u32, handler: V) void {
    const msg = verb_io.readConnLine(vm, conn_id);
    if (msg.tag() == .err) {
        vm.conns.remove(conn_id);
        return;
    }
    defer msg.deinit(vm.alloc);

    const h = resolveHandler(vm, handler);
    if (h.tag() == .blank) return;

    var c = Call{ .vm = vm };
    const result = c.apply(h.ref(), &.{msg.ref()}, false);
    defer result.deinit(vm.alloc);

    if (result.tag() != .blank and result.tag() != .err) {
        _ = sendReply(vm, conn_id, result);
    }
}

fn resolveHandler(vm: *VM, explicit: V) V {
    if (explicit.tag() != .blank) return explicit;
    if (vm.names.get("pg")) |slot| {
        const g = vm.globals[slot];
        if (g.tag() != .blank) return g;
    }
    if (vm.names.get("ps")) |slot| {
        const g = vm.globals[slot];
        if (g.tag() != .blank) return g;
    }
    return .blank;
}

fn sendReply(vm: *VM, conn_id: u32, v: V) V {
    switch (v.tag()) {
        .C => return verb_io.writeConnRaw(vm, conn_id, v.C.slice()),
        .s => return verb_io.writeConnRaw(vm, conn_id, vm.getSymbol(v.s)),
        else => {
            const fmt = @import("../noun/format.zig");
            const util = @import("../util.zig");
            var mock = util.MockWriter.init(vm.alloc) catch return V{ .err = .memory };
            defer mock.deinit();
            var formatter = fmt.TerseFormatter.init(vm, vm.alloc, .Text);
            var w = mock.writer();
            formatter.formatter().fmt(v, &w.interface) catch return V{ .err = .io };
            return verb_io.writeConnRaw(vm, conn_id, mock.getText());
        },
    }
}

pub fn runLoop(vm: *VM) void {
    while (true) {
        pollOnce(vm, .blank);
        _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 1_000_000 }, null);
    }
}
