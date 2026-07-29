/// Event loop for IPC: poll open connections, accept new clients, run the timer,
/// dispatch handlers.
///
/// Entered automatically after a script finishes when it left anything for the
/// loop to do — a listening port (`\p port` / `> -port`), a timer, or a handler
/// attached to an outbound connection.  `` `serve[] `` enters it explicitly and
/// `` `poll[] `` runs a single non-blocking pass, which is what a GPU frame loop
/// wants (the C export `terse_poll()` is the same thing for extensions).
///
/// Handlers live in the `z` namespace — q's `.z`, minus the leading dot, which
/// ink cannot spell because `.` is a verb.  They are ordinary globals whose
/// names the compiler mangles to `z.member`, so either spelling defines them:
/// `z.pg:{…}` directly, or `pg:{…}` inside a `\d z` block.
///
///   z.pg:{[m] "echo: ", m}   message handler; a non-blank result is replied
///   z.pg:{[h;m] …}           dyadic form also receives the calling handle
///   z.ps:{[m] …}             same, but never replies (the async side)
///   z.po:{[h] …}             a peer connected
///   z.pc:{[h] …}             a peer went away
///   z.ts:{[] …}              timer tick, every `` `timer[ms] `` milliseconds
///
/// Only the callbacks are namespaced. The services a script calls INTO
/// (`` `on ``, `` `timer ``, `` `poll ``, …) stay backtick symbols: they are
/// already outside the global namespace, and the split keeps "I call the
/// runtime" visibly distinct from "the runtime calls me".
///
/// A handler attached to one handle with `` `on[h;f] `` takes priority over the
/// globals, which is how a process talks to several peers with different
/// protocols at once.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const V = @import("../noun/value.zig").V;
const VM = @import("vm.zig").VM;
const Call = @import("call.zig").Call;
const ffi = @import("../ffi.zig");
const syms = @import("syms.zig");
const verb_io = @import("../primitive/verb/io.zig");

/// How a handler's return value is treated.
const Reply = enum { on_value, never };

const Handler = struct { f: V, reply: Reply };

/// Non-blocking single pass over all open connections: fire the timer if due,
/// accept new clients on listening sockets, read and dispatch on connected ones.
/// `handler` overrides the `z.pg`/`z.ps` fallbacks when non-blank.
/// IPC relies on posix poll(2), which Windows' std lacks — there it is a no-op.
pub fn pollOnce(vm: *VM, handler: V) void {
  if (builtin.os.tag != .windows) pollOncePosix(vm, handler);
}

fn pollOncePosix(vm: *VM, handler: V) void {
  fireTimer(vm);
  if (vm.conns.map.count() == 0) return;

  // Sized to the live connection count — every handle is polled every pass.
  // A fixed buffer would silently starve whichever handles fell off the end,
  // and HashMap order is not stable, so it would starve a different set each
  // time.  Falls back to skipping the pass (not to a partial one) if the
  // allocation fails.
  const n_conns = vm.conns.map.count();
  const pfds = vm.alloc.alloc(posix.pollfd, n_conns) catch return;
  defer vm.alloc.free(pfds);
  const ids = vm.alloc.alloc(u32, n_conns) catch return;
  defer vm.alloc.free(ids);

  var n: usize = 0;
  var it = vm.conns.map.iterator();
  while (it.next()) |entry| {
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
    if (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
    // A handler may have closed handles, so re-check before touching this one.
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
  const new_id = vm.conns.add(.{ .stream = stream }) catch {
    var s = stream;
    s.close(iol);
    return;
  };
  // New client inherits the callback set on the listening socket.
  const cb = vm.conns.getCallback(listen_id);
  if (cb.tag() != .blank) {
    vm.conns.setCallback(new_id, cb.ref()) catch {};
  }
  callHook(vm, "z.po", new_id);
}

/// Drop a connection, giving `pc` a chance to see the handle first.  The hook
/// runs BEFORE the handle is invalidated so it can still read `` `peer[h] ``,
/// and the handle is removed afterwards even if the hook errors.
fn dropConn(vm: *VM, conn_id: u32) void {
  callHook(vm, "z.pc", conn_id);
  vm.conns.remove(conn_id);
}

fn dispatchMsg(vm: *VM, conn_id: u32, handler: V) void {
  const msg = verb_io.readConnBinary(vm, conn_id);
  if (msg.tag() == .err) {
    msg.deinit(vm.alloc);
    dropConn(vm, conn_id);
    return;
  }
  defer msg.deinit(vm.alloc);

  const h = resolveHandler(vm, conn_id, handler);
  if (h.f.tag() == .blank) return;

  var c = Call{ .vm = vm };
  // Arity picks the calling convention: ink has no `.z.w`, so a handler that
  // wants to know WHO called takes the handle as its first argument.  That
  // also lets it stash the handle and answer later, out of band — which is
  // what a gateway or a load balancer is built on.
  const result = if (h.f.arity() >= 2)
    c.apply(h.f.ref(), &.{ V{ .i = @intCast(conn_id) }, msg.ref() }, false)
  else
    c.apply(h.f.ref(), &.{msg.ref()}, false);
  defer result.deinit(vm.alloc);

  // Blank means "no reply".  An error is REPLIED, not swallowed: errors are
  // ordinary values in ink, and a caller blocked on `2: h` would otherwise wait
  // forever because the handler happened to fail.
  if (h.reply == .on_value and result.tag() != .blank) {
    // The handler may have closed this handle; writeConnBinary errors safely.
    _ = verb_io.writeConnBinary(vm, conn_id, result);
  }
}

fn resolveHandler(vm: *VM, conn_id: u32, explicit: V) Handler {
  if (explicit.tag() != .blank) return .{ .f = explicit, .reply = .on_value };
  // Per-handle handler (`on[h;f]`) takes priority over the globals.
  const cb = vm.conns.getCallback(conn_id);
  if (cb.tag() != .blank) return .{ .f = cb, .reply = .on_value };
  if (globalFn(vm, "z.pg")) |g| return .{ .f = g, .reply = .on_value };
  // `z.ps` is the async side: it is called for its effect and never answers,
  // even when it happens to return a value.
  if (globalFn(vm, "z.ps")) |g| return .{ .f = g, .reply = .never };
  return .{ .f = .blank, .reply = .never };
}

fn globalFn(vm: *VM, name: []const u8) ?V {
  const slot = vm.names.get(name) orelse return null;
  const g = vm.globals[slot];
  if (g.tag() == .blank) return null;
  return g;
}

/// Call a global hook with a single handle argument, ignoring its result.
fn callHook(vm: *VM, name: []const u8, conn_id: u32) void {
  const f = globalFn(vm, name) orelse return;
  var c = Call{ .vm = vm };
  const r = c.apply(f.ref(), &.{V{ .i = @intCast(conn_id) }}, false);
  r.deinit(vm.alloc);
}

/// Run the global `ts` if `` `timer[ms] `` is set and the interval has elapsed.
/// The next deadline is computed from NOW, not from the old deadline, so a slow
/// tick delays the next one instead of queueing up a burst of catch-up calls.
fn fireTimer(vm: *VM) void {
  if (vm.timer_ms == 0) return;
  const now = syms.microsNow();
  if (now < vm.timer_next) return;
  vm.timer_next = now + @as(i64, vm.timer_ms) * 1000;
  const f = globalFn(vm, "z.ts") orelse return;
  const prev_vm = ffi.getCurrentVm();
  ffi.setCurrentVm(vm);
  defer ffi.restoreVm(prev_vm);
  var c = Call{ .vm = vm };
  const r = if (f.arity() >= 1) c.apply(f.ref(), &.{.blank}, false) else c.apply(f.ref(), &.{}, false);
  r.deinit(vm.alloc);
}

/// True when the process still has something to serve: a listening port, a
/// timer, or a handler waiting on an outbound connection.
pub fn hasWork(vm: *VM) bool {
  return vm.listen_handle != null or vm.timer_ms > 0 or vm.conns.hasCallbacks();
}

pub fn runLoop(vm: *VM) void {
  if (builtin.os.tag != .windows) runLoopPosix(vm);
}

fn runLoopPosix(vm: *VM) void {
  while (true) {
    pollOncePosix(vm, .blank);
    _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 1_000_000 }, null);
  }
}
