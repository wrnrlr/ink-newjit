const std = @import("std");
const builtin = @import("builtin");
const VM = @import("../../runtime/vm.zig").VM;
const Conns = @import("../../runtime/registry.zig").Conns;

// Raw socket read for binary IPC. Windows uses Winsock recv (not posix.read)
// and IPC is unsupported there, so this errors on Windows without referencing
// posix.read (a comptime-dead branch keeps it out of the Windows build).
fn sockRead(sock: anytype, buf: []u8) error{Io}!usize {
  if (builtin.os.tag != .windows) return std.posix.read(sock, buf) catch error.Io;
  return error.Io;
}
const sort = @import("sort.zig");
const format = @import("../../noun/format.zig");
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;
const binary = @import("../../encoding/binary.zig");

fn writeFile(vm: *VM, id: u32, content: []const u8) !void {
  // Guard invalid ids (e.g. `2:` applied to a bogus handle) rather than
  // indexing the registry out of bounds.
  if (id >= vm.fs.texts.items.len) return error.BadFileId;
  if (vm.fs.getPath(id)) |path| {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, content, 0);
  }
  try vm.fs.updateFile(id, content);
}

// ---------------------------------------------------------------------------
// ReadLines  0: (monad)
// ---------------------------------------------------------------------------

fn readLinesBySymbol(vm: *VM, x: V) V {
  const id = vm.mapFile(vm.getSymbol(x.s)) catch return V{ .err = .io };
  return readLinesById(vm, V{ .i = @intCast(id) });
}
fn readLinesByChars(vm: *VM, x: V) V {
  const id = vm.mapFile(x.C.slice()) catch return V{ .err = .io };
  return readLinesById(vm, V{ .i = @intCast(id) });
}
fn readLinesById(vm: *VM, x: V) V {
  const id: u32 = @intCast(@abs(x.i));
  if (Conns.isConn(id)) return readSocketLine(vm, id);
  const text = vm.fs.getFileText(id);
  var list = std.ArrayList(V).initCapacity(vm.alloc, 0) catch return V{ .err = .memory };
  defer list.deinit(vm.alloc);
  var iter = std.mem.splitScalar(u8, text, '\n');
  while (iter.next()) |line| {
    const stripped = std.mem.trimEnd(u8, line, &[_]u8{'\r'});
    const s = V.Chars(vm.alloc, stripped) catch return V{ .err = .memory };
    list.append(vm.alloc, s) catch return V{ .err = .memory };
  }
  return V.Values(vm.alloc, list.items) catch return V{ .err = .memory };
}

pub const ReadLines = struct {
  pub const op = .@"0:";
  _s: VM.Monad = readLinesBySymbol,
  _C: VM.Monad = readLinesByChars,
  _i: VM.Monad = readLinesById,
};

// ---------------------------------------------------------------------------
// WriteLines  0: (dyad)
// ---------------------------------------------------------------------------

fn writeLinesConsole(vm: *VM, _: V, y: V) V {
  if (y.tag() == .C) {
    vm.print("{s}\n", .{y.C.slice()});
    return .blank;
  }
  if (y.tag() == .s) {
    vm.print("{s}\n", .{vm.getSymbol(y.s)});
    return .blank;
  }
  if (y.tag() == .L) {
    for (y.L.slice(), 0..) |item, i| {
      if (i > 0) vm.print("\n", .{});
      if (item.tag() == .C) vm.print("{s}", .{item.C.slice()})
      else if (item.tag() == .s) vm.print("{s}", .{vm.getSymbol(item.s)});
    }
    vm.print("\n", .{});
    return .blank;
  }
  return V{ .err = .@"type" };
}
fn writeLinesBySymbol(vm: *VM, x: V, y: V) V {
  const path = vm.getSymbol(x.s);
  if (path.len == 0 or std.mem.eql(u8, path, "0")) return writeLinesConsole(vm, x, y);
  const id = vm.mapFileW(path) catch return V{ .err = .io };
  return writeLinesById(vm, V{ .i = @intCast(id) }, y);
}
fn writeLinesByChars(vm: *VM, x: V, y: V) V {
  const id = vm.mapFileW(x.C.slice()) catch return V{ .err = .io };
  return writeLinesById(vm, V{ .i = @intCast(id) }, y);
}
fn writeLinesById_L(vm: *VM, x: V, y: V) V { return writeLinesById(vm, x, y); }
fn writeLinesById_C(vm: *VM, x: V, y: V) V { return writeLinesById(vm, x, y); }
fn writeLinesById_s(vm: *VM, x: V, y: V) V { return writeLinesById(vm, x, y); }
fn writeLinesById(vm: *VM, x: V, y: V) V {
  const id: u32 = @intCast(@abs(x.i));
  if (Conns.isConn(id)) return writeSocketLine(vm, id, y);
  var out = std.ArrayList(u8).initCapacity(vm.alloc, 0) catch return V{ .err = .memory };
  defer out.deinit(vm.alloc);
  switch (y) {
    .L => for (y.L.slice(), 0..) |item, i| {
      if (i > 0) out.append(vm.alloc, '\n') catch return V{ .err = .memory };
      if (item.tag() == .C) out.appendSlice(vm.alloc, item.C.slice()) catch return V{ .err = .memory }
      else if (item.tag() == .s) out.appendSlice(vm.alloc, vm.getSymbol(item.s)) catch return V{ .err = .memory };
    },
    .C => out.appendSlice(vm.alloc, y.C.slice()) catch return V{ .err = .memory },
    .s => out.appendSlice(vm.alloc, vm.getSymbol(y.s)) catch return V{ .err = .memory },
    else => return V{ .err = .@"type" },
  }
  out.append(vm.alloc, '\n') catch return V{ .err = .memory };
  writeFile(vm, id, out.items) catch return V{ .err = .io };
  return .blank;
}

pub const WriteLines = struct {
  pub const op = .@"0:";
  _s_L: VM.Dyad = writeLinesBySymbol,
  _s_C: VM.Dyad = writeLinesBySymbol,
  _s_s: VM.Dyad = writeLinesBySymbol,
  _C_L: VM.Dyad = writeLinesByChars,
  _C_C: VM.Dyad = writeLinesByChars,
  _C_s: VM.Dyad = writeLinesByChars,
  _i_L: VM.Dyad = writeLinesById_L,
  _i_C: VM.Dyad = writeLinesById_C,
  _i_s: VM.Dyad = writeLinesById_s,
};

// ---------------------------------------------------------------------------
// Raw stdio for byte-stream protocols (LSP/Jupyter frames over stdin/stdout).
//   1: `stdin        → up to 64 KiB of available bytes (blocks for ≥1), "" at EOF
//   `stdout 1: data  → write raw bytes, no trailing newline, flush
//   `stderr 1: data  → same, to stderr (safe for logging beside a stdout protocol)
// The caller frames/buffers in k; reads are partial-by-design.
// ---------------------------------------------------------------------------

fn readStdinBytes(vm: *VM) V {
  const io = std.Io.Threaded.global_single_threaded.io();
  var buf: [65536]u8 = undefined;
  const n = std.Io.File.stdin().readStreaming(io, &.{buf[0..]}) catch |err| {
    if (err == error.EndOfStream) return V.Chars(vm.alloc, "") catch V{ .err = .memory };
    return V{ .err = .io };
  };
  // n == 0 also signals EOF; hand k an empty char vector so its loop can stop.
  return V.Chars(vm.alloc, buf[0..n]) catch V{ .err = .memory };
}

fn writeStdRaw(vm: *VM, comptime is_stdout: bool, data: []const u8) V {
  // stdout shares the VM's output writer so it interleaves correctly with any
  // ordinary `` `0 0:… `` prints; stderr uses its own fd.
  if (is_stdout) if (vm.out) |out| {
    out.writeAll(data) catch return V{ .err = .io };
    out.flush() catch return V{ .err = .io };
    return .blank;
  };
  // Streaming (appending) write — a fresh file.writer() would positional-write
  // from offset 0 each call, so successive writes would clobber each other.
  const io = std.Io.Threaded.global_single_threaded.io();
  const file = if (is_stdout) std.Io.File.stdout() else std.Io.File.stderr();
  file.writeStreamingAll(io, data) catch return V{ .err = .io };
  return .blank;
}

// ---------------------------------------------------------------------------
// ReadBytes  1: (monad)
// ---------------------------------------------------------------------------

fn readBytesBySymbol(vm: *VM, x: V) V {
  const name = vm.getSymbol(x.s);
  if (std.mem.eql(u8, name, "stdin")) return readStdinBytes(vm);
  const id = vm.mapFile(name) catch return V{ .err = .io };
  return readBytesById(vm, V{ .i = @intCast(id) });
}
fn readBytesByChars(vm: *VM, x: V) V {
  const id = vm.mapFile(x.C.slice()) catch return V{ .err = .io };
  return readBytesById(vm, V{ .i = @intCast(id) });
}
fn readBytesById(vm: *VM, x: V) V {
  const id: u32 = @intCast(@abs(x.i));
  if (Conns.isConn(id)) return readSocketBytes(vm, id);
  return V.Chars(vm.alloc, vm.fs.getFileText(id)) catch return V{ .err = .memory };
}

pub const ReadBytes = struct {
  pub const op = .@"1:";
  _s: VM.Monad = readBytesBySymbol,
  _C: VM.Monad = readBytesByChars,
  _i: VM.Monad = readBytesById,
};

// ---------------------------------------------------------------------------
// WriteBytes  1: (dyad)
// ---------------------------------------------------------------------------

fn writeBytesBySymbol(vm: *VM, x: V, y: V) V {
  const name = vm.getSymbol(x.s);
  if (std.mem.eql(u8, name, "stdout")) return writeStdRaw(vm, true, y.C.slice());
  if (std.mem.eql(u8, name, "stderr")) return writeStdRaw(vm, false, y.C.slice());
  const id = vm.mapFileW(name) catch return V{ .err = .io };
  return writeBytesByHandle(vm, V{ .i = @intCast(id) }, y);
}
fn writeBytesByChars(vm: *VM, x: V, y: V) V {
  const id = vm.mapFileW(x.C.slice()) catch return V{ .err = .io };
  return writeBytesByHandle(vm, V{ .i = @intCast(id) }, y);
}
fn writeBytesByHandle(vm: *VM, x: V, y: V) V {
  const id: u32 = @intCast(@abs(x.i));
  if (Conns.isConn(id)) return writeSocketBytes(vm, id, y.C.slice());
  writeFile(vm, id, y.C.slice()) catch return V{ .err = .io };
  return .blank;
}

pub const WriteBytes = struct {
  pub const op = .@"1:";
  _s_C: VM.Dyad = writeBytesBySymbol,
  _C_C: VM.Dyad = writeBytesByChars,
  _i_C: VM.Dyad = writeBytesByHandle,
};

// ---------------------------------------------------------------------------
// ReadData  2: (monad)
// ---------------------------------------------------------------------------

fn readDataBySymbol(vm: *VM, x: V) V {
  const id = vm.mapFile(vm.getSymbol(x.s)) catch return V{ .err = .io };
  return readDataById(vm, V{ .i = @intCast(id) });
}
fn readDataByChars(vm: *VM, x: V) V {
  const id = vm.mapFile(x.C.slice()) catch return V{ .err = .io };
  return readDataById(vm, V{ .i = @intCast(id) });
}
fn readDataById(vm: *VM, x: V) V {
  const id: u32 = @intCast(x.i);
  if (Conns.isConn(id)) return readConnBinary(vm, id);
  // A loaded module's `\d` namespace must not leak into the caller's scope.
  const saved_ns = vm.compiler.namespace;
  defer vm.compiler.namespace = saved_ns;
  return vm.eval(vm.fs.getFileText(id)) catch return V{ .err = .io };
}

pub const ReadData = struct {
  pub const op = .@"2:";
  _s: VM.Monad = readDataBySymbol,
  _C: VM.Monad = readDataByChars,
  _i: VM.Monad = readDataById,
};

// ---------------------------------------------------------------------------
// WriteData  2: (dyad)
// ---------------------------------------------------------------------------

fn writeDataOrFfi(vm: *VM, lib_path: []const u8, y: V) V {
  // Intercept: "lib.so" 2: (`sym; arity)  →  load FFI function
  if (y.tag() == .L) {
    const sl = y.L.slice();
    if (sl.len == 2 and sl[0].tag() == .s and sl[1].tag() == .i) {
      const sym_name = vm.getSymbol(sl[0].s);
      const arity: u8 = @intCast(@max(0, @min(8, sl[1].i)));
      return @import("../../ffi.zig").ffiLoad(vm, lib_path, sym_name, arity);
    }
  }
  const id = vm.mapFile(lib_path) catch return V{ .err = .io };
  return writeDataFallback(vm, V{ .i = @intCast(id) }, y);
}
fn writeDataBySymbol(vm: *VM, x: V, y: V) V {
  return writeDataOrFfi(vm, vm.getSymbol(x.s), y);
}
fn writeDataByChars(vm: *VM, x: V, y: V) V {
  return writeDataOrFfi(vm, x.C.slice(), y);
}

/// `handle 2: value` — binary-serialize and send over a conn, or write to a file.
fn writeDataByIdValue(vm: *VM, x: V, y: V) V {
  const id: u32 = @intCast(x.i);
  if (Conns.isConn(id)) return writeConnBinary(vm, id, y);
  return writeDataFallback(vm, x, y);
}

/// `handle 2: lambda` — attach a per-handle IPC callback.
fn writeDataByIdCallback(vm: *VM, x: V, y: V) V {
  const id: u32 = @intCast(x.i);
  if (Conns.isConn(id)) {
    vm.conns.setCallback(id, y.ref()) catch return V{ .err = .memory };
    return .blank;
  }
  return writeDataFallback(vm, x, y);
}

pub const WriteData = struct {
  pub const op = .@"2:";
  _s_I: VM.Dyad = writeDataBySymbol,
  _s_F: VM.Dyad = writeDataBySymbol,
  _s_S: VM.Dyad = writeDataBySymbol,
  _s_C: VM.Dyad = writeDataBySymbol,
  _s_B: VM.Dyad = writeDataBySymbol,
  _s_L: VM.Dyad = writeDataBySymbol,
  _s_m: VM.Dyad = writeDataBySymbol,
  _s_M: VM.Dyad = writeDataBySymbol,
  _C_I: VM.Dyad = writeDataByChars,
  _C_F: VM.Dyad = writeDataByChars,
  _C_S: VM.Dyad = writeDataByChars,
  _C_C: VM.Dyad = writeDataByChars,
  _C_B: VM.Dyad = writeDataByChars,
  _C_L: VM.Dyad = writeDataByChars,
  _C_m: VM.Dyad = writeDataByChars,
  _C_M: VM.Dyad = writeDataByChars,
  _i_I: VM.Dyad = writeDataByIdValue,
  _i_F: VM.Dyad = writeDataByIdValue,
  _i_S: VM.Dyad = writeDataByIdValue,
  _i_C: VM.Dyad = writeDataByIdValue,
  _i_B: VM.Dyad = writeDataByIdValue,
  _i_L: VM.Dyad = writeDataByIdValue,
  _i_m: VM.Dyad = writeDataByIdValue,
  _i_M: VM.Dyad = writeDataByIdValue,
  _i_o: VM.Dyad = writeDataByIdCallback,
  _i_p: VM.Dyad = writeDataByIdCallback,
};

pub fn writeDataFallback(vm: *VM, x: V, y: V) V {
  const id = @as(u32, @intCast(x.i));
  var mock = util.MockWriter.init(vm.alloc) catch return V{ .err = .memory };
  defer mock.deinit();
  var formatter = format.TerseFormatter.init(vm, vm.alloc, .Text);
  var w = mock.writer();
  formatter.formatter().fmt(y, &w.interface) catch return V{ .err = .io };
  writeFile(vm, id, mock.getText()) catch return V{ .err = .io };
  return .blank;
}

// ---------------------------------------------------------------------------
// Network open/close (> and < verbs)
// ---------------------------------------------------------------------------

/// Start a TCP server on `port`, accept the first client, return conn handle.
pub fn netListen(vm: *VM, port: u16) V {
  const io = std.Io.Threaded.global_single_threaded.io();
  const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.unspecified(port) };
  var server = addr.listen(io, .{ .reuse_address = true }) catch return V{ .err = .io };
  const stream = server.accept(io) catch {
    server.deinit(io);
    return V{ .err = .io };
  };
  const id = vm.conns.add(.{ .server = server, .stream = stream }) catch return V{ .err = .memory };
  return V{ .i = @intCast(id) };
}

/// Create a listening server socket without blocking for a client.
/// Used by the event loop — accept happens inside `pollOnce`.
pub fn netListenOnly(vm: *VM, port: u16) V {
  const io = std.Io.Threaded.global_single_threaded.io();
  const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.unspecified(port) };
  const server = addr.listen(io, .{ .reuse_address = true }) catch return V{ .err = .io };
  const id = vm.conns.add(.{ .server = server }) catch return V{ .err = .memory };
  return V{ .i = @intCast(id) };
}

/// Connect as a TCP client to `host`:`port`, return conn handle.
pub fn netConnect(vm: *VM, host: []const u8, port: u16) V {
  const io = std.Io.Threaded.global_single_threaded.io();
  const addr = std.Io.net.IpAddress.parse(host, port) catch return V{ .err = .io };
  const stream = addr.connect(io, .{ .mode = .stream }) catch return V{ .err = .io };
  const id = vm.conns.add(.{ .stream = stream }) catch return V{ .err = .memory };
  return V{ .i = @intCast(id) };
}

/// Close a connection handle.
pub fn netClose(vm: *VM, id: u32) V {
  vm.conns.remove(id);
  return .blank;
}

/// Parse "host:port" string.  Returns null on bad format.
fn parseHostPort(s: []const u8) ?struct { host: []const u8, port: u16 } {
  const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
  const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return null;
  return .{ .host = s[0..colon], .port = port };
}

// ---------------------------------------------------------------------------
// Socket read / write helpers (used by the 0: and 1: handlers above)
// ---------------------------------------------------------------------------

/// Receive one newline-terminated message from a connected socket.
/// Public so that serve.zig can use it for event-loop dispatch.
pub fn readConnLine(vm: *VM, id: u32) V {
  return readSocketLine(vm, id);
}

/// Receive one binary IPC message (4-byte LE length prefix + binary payload).
/// Used by `2: handle` and the event loop in serve.zig.
pub fn readConnBinary(vm: *VM, id: u32) V {
  const conn = vm.conns.get(id) orelse return V{ .err = .io };
  if (conn.stream == null) return V{ .err = .io };
  const sock = conn.stream.?.socket.handle;
  var len_buf: [4]u8 = undefined;
  var total: usize = 0;
  while (total < 4) {
    const n = sockRead(sock, len_buf[total..]) catch return V{ .err = .io };
    if (n == 0) return V{ .err = .io };
    total += n;
  }
  const payload_len = std.mem.readInt(u32, &len_buf, .little);
  const payload = vm.alloc.alloc(u8, payload_len) catch return V{ .err = .memory };
  defer vm.alloc.free(payload);
  total = 0;
  while (total < payload_len) {
    const n = sockRead(sock, payload[total..]) catch return V{ .err = .io };
    if (n == 0) return V{ .err = .io };
    total += n;
  }
  return binary.deserialize(vm.alloc, &vm.symbols, payload) catch V{ .err = .domain };
}

/// Send a binary IPC message (4-byte LE length prefix + binary payload).
/// Used by `handle 2: value` and the event loop in serve.zig.
pub fn writeConnBinary(vm: *VM, id: u32, y: V) V {
  const ser = binary.serialize(vm.alloc, &vm.symbols, y) catch return V{ .err = .io };
  defer ser.deinit(vm.alloc);
  const data = ser.C.slice();
  const conn = vm.conns.get(id) orelse return V{ .err = .io };
  if (conn.stream == null) return V{ .err = .io };
  const io_ctx = std.Io.Threaded.global_single_threaded.io();
  var write_buf: [65536]u8 = undefined;
  var w = conn.stream.?.writer(io_ctx, &write_buf);
  var len_buf: [4]u8 = undefined;
  std.mem.writeInt(u32, &len_buf, @intCast(data.len), .little);
  w.interface.writeAll(&len_buf) catch return V{ .err = .io };
  w.interface.writeAll(data) catch return V{ .err = .io };
  w.interface.flush() catch return V{ .err = .io };
  return .blank;
}

fn readSocketLine(vm: *VM, id: u32) V {
  const conn = vm.conns.get(id) orelse return V{ .err = .io };
  if (conn.stream == null) return V{ .err = .io };
  const sock = conn.stream.?.socket.handle;
  var buf = std.ArrayList(u8).initCapacity(vm.alloc, 0) catch return V{ .err = .memory };
  defer buf.deinit(vm.alloc);
  var byte: [1]u8 = undefined;
  while (true) {
    const n = sockRead(sock, &byte) catch return V{ .err = .io };
    if (n == 0) {
      // EOF: if nothing was buffered, the connection was closed by the peer.
      if (buf.items.len == 0) return V{ .err = .io };
      break;
    }
    if (byte[0] == '\n') break;
    buf.append(vm.alloc, byte[0]) catch return V{ .err = .memory };
  }
  return V.Chars(vm.alloc, buf.items) catch V{ .err = .memory };
}

/// Receive all available bytes (up to 64 KiB) from a connected socket.
fn readSocketBytes(vm: *VM, id: u32) V {
  const conn = vm.conns.get(id) orelse return V{ .err = .io };
  if (conn.stream == null) return V{ .err = .io };
  const sock = conn.stream.?.socket.handle;
  var buf: [65536]u8 = undefined;
  const n = sockRead(sock, &buf) catch return V{ .err = .io };
  return V.Chars(vm.alloc, buf[0..n]) catch V{ .err = .memory };
}

/// Send a value as a newline-terminated line to a socket.
fn writeSocketLine(vm: *VM, id: u32, y: V) V {
  const data: []const u8 = switch (y) {
    .C => y.C.slice(),
    .s => vm.getSymbol(y.s),
    else => return V{ .err = .@"type" },
  };
  return writeSocketRaw(vm, id, data);
}

/// Send raw bytes (+ trailing newline) to a socket.
fn writeSocketBytes(vm: *VM, id: u32, data: []const u8) V {
  return writeSocketRaw(vm, id, data);
}

/// Send raw bytes (+ trailing newline) to a connected socket.
/// Public so that serve.zig can send handler replies.
pub fn writeConnRaw(vm: *VM, id: u32, data: []const u8) V {
  return writeSocketRaw(vm, id, data);
}

fn writeSocketRaw(vm: *VM, id: u32, data: []const u8) V {
  const conn = vm.conns.get(id) orelse return V{ .err = .io };
  if (conn.stream == null) return V{ .err = .io };
  const io = std.Io.Threaded.global_single_threaded.io();
  var write_buf: [65536]u8 = undefined;
  var w = conn.stream.?.writer(io, &write_buf);
  w.interface.writeAll(data) catch return V{ .err = .io };
  w.interface.writeByte('\n') catch return V{ .err = .io };
  w.interface.flush() catch return V{ .err = .io };
  return .blank;
}

// ---------------------------------------------------------------------------
// NetOpen  > (monad): open a file, listen for a client, or connect to server
// ---------------------------------------------------------------------------

fn netOpenByInt(vm: *VM, x: V) V {
  if (x.i == 0 or x.i > 65535 or x.i < -65535) return V{ .err = .domain };
  if (x.i > 0) return netListen(vm, @intCast(x.i));
  // Negative port: async listen — enter event loop after script.
  const port: u16 = @intCast(-x.i);
  const h = netListenOnly(vm, port);
  if (h.tag() == .err) return h;
  vm.listen_handle = @intCast(h.i);
  return h;
}

fn netOpenByChars(vm: *VM, x: V) V {
  const s = x.C.slice();
  if (parseHostPort(s)) |hp| return netConnect(vm, hp.host, hp.port);
  // No colon → fall back to grade-descend (original `>C` semantics)
  return sort.gradeDescend(vm, x);
}

fn netOpenBySymbol(vm: *VM, x: V) V {
  const s = vm.getSymbol(x.s);
  if (parseHostPort(s)) |hp| return netConnect(vm, hp.host, hp.port);
  const id = vm.mapFile(s) catch return V{ .err = .io };
  return V{ .i = @intCast(id) };
}

pub const NetOpen = struct {
  pub const op = .@">";
  _i: VM.Monad = netOpenByInt,
  _C: VM.Monad = netOpenByChars,
  _s: VM.Monad = netOpenBySymbol,
};

// ---------------------------------------------------------------------------
// CloseHandle  < (integer monad): close an open handle
// ---------------------------------------------------------------------------

pub fn closeHandle(vm: *VM, x: V) V {
  if (x.i < 0) return V{ .err = .domain };
  const id: u32 = @intCast(x.i);
  if (Conns.isConn(id)) {
    vm.conns.remove(id);
    return .blank;
  }
  // Not a socket handle — fall back to grade-ascending (degenerate scalar case)
  return sort.gradeAscend(vm, x);
}
