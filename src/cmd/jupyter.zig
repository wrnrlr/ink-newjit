// ink Jupyter kernel — `ink jupyter -f <connection-file>`.
//
// Implements the Jupyter messaging protocol (v5.3) over ZeroMQ, talking the
// ZMTP 3.0 wire protocol (NULL security mechanism) directly so the kernel has
// no external dependencies: HMAC-SHA256 comes from std.crypto and the sockets
// are raw std.posix TCP.  This lets editors with Jupyter REPL support (e.g.
// Zed) evaluate ink interactively, complementing the `ink lsp` server.
//
// Sockets (all bound by the kernel):
//   hb      REP    — echo heartbeat
//   shell   ROUTER — execute_request / kernel_info_request / …
//   control ROUTER — shutdown_request / interrupt_request
//   stdin   ROUTER — input replies (unused; the kernel never prompts)
//   iopub   PUB    — status / stream / execute_result broadcasts
//
// A single poll() loop drives every socket on one thread, matching the VM's
// single-threaded model (the VM is never touched from another thread).
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const libc = std.c;
const json = std.json;

const Fd = posix.fd_t;
const Alloc = std.mem.Allocator;
const VM = @import("runtime/vm.zig").VM;
const Repl = @import("repl.zig").Repl;
const MockWriter = @import("util.zig").MockWriter;
const modules = @import("modules.zig");
const Lexer = @import("parser/lexer.zig").Lexer;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const PROTOCOL_VERSION = "5.3";

// ── connection file ─────────────────────────────────────────────────────────
const Config = struct {
  ip: []const u8,
  transport: []const u8,
  key: []const u8,
  shell_port: u16,
  control_port: u16,
  stdin_port: u16,
  hb_port: u16,
  iopub_port: u16,
};

fn cfgStr(o: json.ObjectMap, key: []const u8, dflt: []const u8) []const u8 {
  const v = o.get(key) orelse return dflt;
  return if (v == .string) v.string else dflt;
}
fn cfgPort(o: json.ObjectMap, key: []const u8) u16 {
  const v = o.get(key) orelse return 0;
  return switch (v) {
    .integer => |n| @intCast(n),
    .string => |s| std.fmt.parseInt(u16, s, 10) catch 0,
    else => 0,
  };
}

// ── ZMTP framing ────────────────────────────────────────────────────────────
const SocketType = enum { router, pub_, rep };

fn socketTypeName(t: SocketType) []const u8 {
  return switch (t) { .router => "ROUTER", .pub_ => "PUB", .rep => "REP" };
}

// Build the 64-byte ZMTP 3.0 greeting we send on every new connection.
fn greeting(buf: *[64]u8) void {
  @memset(buf, 0);
  buf[0] = 0xFF; // signature
  buf[9] = 0x7F;
  buf[10] = 3; // version major
  buf[11] = 0; // version minor
  @memcpy(buf[12..16], "NULL"); // mechanism (20 bytes, zero-padded)
  // buf[32] as-server = 0 (ignored for NULL); buf[33..64] filler = 0.
}

// Append a single ZMTP frame (flags + length + body) to out.
fn appendFrame(out: *std.ArrayList(u8), gpa: Alloc, body: []const u8, more: bool, command: bool) !void {
  var flags: u8 = 0;
  if (more) flags |= 0x01;
  if (command) flags |= 0x04;
  if (body.len < 256) {
    try out.append(gpa, flags);
    try out.append(gpa, @intCast(body.len));
  } else {
    try out.append(gpa, flags | 0x02); // long
    var len8: [8]u8 = undefined;
    std.mem.writeInt(u64, &len8, body.len, .big);
    try out.appendSlice(gpa, &len8);
  }
  try out.appendSlice(gpa, body);
}

// Build the NULL-mechanism READY command advertising our socket type.
fn appendReady(out: *std.ArrayList(u8), gpa: Alloc, t: SocketType) !void {
  var body: std.ArrayList(u8) = .empty;
  defer body.deinit(gpa);
  try body.append(gpa, 5);
  try body.appendSlice(gpa, "READY");
  // metadata property: Socket-Type = <name>
  const name = "Socket-Type";
  const val = socketTypeName(t);
  try body.append(gpa, @intCast(name.len));
  try body.appendSlice(gpa, name);
  var len4: [4]u8 = undefined;
  std.mem.writeInt(u32, &len4, @intCast(val.len), .big);
  try body.appendSlice(gpa, &len4);
  try body.appendSlice(gpa, val);
  try appendFrame(out, gpa, body.items, false, true);
}

// ── raw libc socket wrappers ────────────────────────────────────────────────
// This std exposes networking through std.Io.net, but the ZMTP framing needs
// byte-level control, so we call the libc syscalls directly.
fn parseIp4(s: []const u8) !u32 {
  var octets: [4]u8 = undefined;
  var it = std.mem.splitScalar(u8, s, '.');
  var i: usize = 0;
  while (it.next()) |part| : (i += 1) {
    if (i >= 4) return error.BadAddress;
    octets[i] = std.fmt.parseInt(u8, part, 10) catch return error.BadAddress;
  }
  if (i != 4) return error.BadAddress;
  return @bitCast(octets); // network byte order on little-endian hosts
}

fn bindListen(ip: []const u8, port: u16) !Fd {
  const fd = libc.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
  if (fd < 0) return error.SocketFailed;
  errdefer _ = libc.close(fd);
  try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
  var addr = libc.sockaddr.in{
    .port = std.mem.nativeToBig(u16, port),
    .addr = try parseIp4(ip),
  };
  if (libc.bind(fd, @ptrCast(&addr), @sizeOf(libc.sockaddr.in)) != 0) return error.BindFailed;
  if (libc.listen(fd, 16) != 0) return error.ListenFailed;
  return fd;
}

// One peer connection on a listening socket.
const Conn = struct {
  fd: Fd,
  got_greeting: bool = false,
  in: std.ArrayList(u8) = .empty,
  parts: std.ArrayList([]u8) = .empty, // accumulating multipart message
};

// A bound ZMTP listening socket plus its accepted peers.
const Socket = struct {
  fd: Fd,
  kind: SocketType,
  conns: std.ArrayList(Conn) = .empty,

  fn bind(cfg: Config, port: u16, kind: SocketType) !Socket {
    return .{ .fd = try bindListen(cfg.ip, port), .kind = kind };
  }

  // Accept a pending peer: register it and send greeting + READY immediately.
  fn accept(self: *Socket, gpa: Alloc) !void {
    const cfd = libc.accept(self.fd, null, null);
    if (cfd < 0) return; // EAGAIN / transient — try again next poll
    var hello: std.ArrayList(u8) = .empty;
    defer hello.deinit(gpa);
    var g: [64]u8 = undefined;
    greeting(&g);
    try hello.appendSlice(gpa, &g);
    try appendReady(&hello, gpa, self.kind);
    writeAll(cfd, hello.items) catch { _ = libc.close(cfd); return; };
    try self.conns.append(gpa, .{ .fd = cfd });
  }
};

fn writeAll(fd: Fd, bytes: []const u8) !void {
  var off: usize = 0;
  while (off < bytes.len) {
    const n = libc.write(fd, bytes[off..].ptr, bytes.len - off);
    if (n < 0) {
      const e = posix.errno(n);
      if (e == .INTR or e == .AGAIN) continue;
      return error.WriteFailed;
    }
    if (n == 0) return error.Closed;
    off += @intCast(n);
  }
}

// ── parsed Jupyter message ──────────────────────────────────────────────────
const Msg = struct {
  // Raw frames (after the <IDS|MSG> delimiter): sig, header, parent, meta, content.
  header: []const u8,
  content: []const u8,
  msg_type: []const u8,
  session: []const u8,
};

// Locate the <IDS|MSG> delimiter and slice out the standard parts.
fn parseMsg(parts: [][]u8) ?Msg {
  var d: usize = 0;
  while (d < parts.len) : (d += 1) {
    if (std.mem.eql(u8, parts[d], "<IDS|MSG>")) break;
  }
  if (d + 5 >= parts.len) return null; // need sig, header, parent, meta, content
  return .{
    .header = parts[d + 2],
    .content = parts[d + 5],
    .msg_type = "",
    .session = "",
  };
}

// ── the kernel ──────────────────────────────────────────────────────────────
const Kernel = struct {
  gpa: Alloc,
  vm: *VM,
  loader: *modules.ModuleLoader,
  repl: Repl,
  key: []const u8,
  shell: Socket,
  control: Socket,
  stdin: Socket,
  hb: Socket,
  iopub: Socket,
  session: []const u8 = "",
  exec_count: i64 = 0,
  msg_seq: u64 = 0,
  running: bool = true,

  // Hex-encode an HMAC-SHA256 of the four message JSON blobs into out (64 chars),
  // or leave it empty when no signing key is configured.
  fn sign(self: *Kernel, out: *[64]u8, header: []const u8, parent: []const u8, meta: []const u8, content: []const u8) usize {
    if (self.key.len == 0) return 0;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    var h = HmacSha256.init(self.key);
    h.update(header);
    h.update(parent);
    h.update(meta);
    h.update(content);
    h.final(&mac);
    const hex = "0123456789abcdef";
    for (mac, 0..) |b, i| {
      out[i * 2] = hex[b >> 4];
      out[i * 2 + 1] = hex[b & 0xf];
    }
    return mac.len * 2;
  }

  // Send a Jupyter message: builds header, signs, and writes the multipart.
  // `topic` is non-null for PUB (iopub) sockets only.
  fn send(self: *Kernel, fd: posix.fd_t, msg_type: []const u8, parent_header: []const u8, content: []const u8, topic: ?[]const u8) !void {
    const gpa = self.gpa;
    const header = try self.buildHeader(msg_type);
    defer gpa.free(header);
    const meta = "{}";
    var sig: [64]u8 = undefined;
    const siglen = self.sign(&sig, header, parent_header, meta, content);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (topic) |t| try appendFrame(&out, gpa, t, true, false);
    try appendFrame(&out, gpa, "<IDS|MSG>", true, false);
    try appendFrame(&out, gpa, sig[0..siglen], true, false);
    try appendFrame(&out, gpa, header, true, false);
    try appendFrame(&out, gpa, parent_header, true, false);
    try appendFrame(&out, gpa, meta, true, false);
    try appendFrame(&out, gpa, content, false, false);
    try writeAll(fd, out.items);
  }

  fn buildHeader(self: *Kernel, msg_type: []const u8) ![]u8 {
    // msg_id only needs to be unique within the session, so a counter suffices.
    self.msg_seq += 1;
    var date: [32]u8 = undefined;
    const ds = isoDate(&date);
    return std.fmt.allocPrint(self.gpa,
      "{{\"msg_id\":\"{s}-{d}\",\"session\":\"{s}\",\"username\":\"kernel\",\"date\":\"{s}\",\"msg_type\":\"{s}\",\"version\":\"{s}\"}}",
      .{ self.session, self.msg_seq, self.session, ds, msg_type, PROTOCOL_VERSION });
  }

  // Broadcast an iopub message to every subscribed peer.
  fn iopubSend(self: *Kernel, msg_type: []const u8, parent_header: []const u8, content: []const u8) void {
    for (self.iopub.conns.items) |c| {
      if (!c.got_greeting) continue;
      self.send(c.fd, msg_type, parent_header, content, msg_type) catch {};
    }
  }

  // ── shell/control request dispatch ─────────────────────────────────────────
  fn handleRequest(self: *Kernel, fd: posix.fd_t, parts: [][]u8) void {
    const m = parseMsg(parts) orelse return;
    const gpa = self.gpa;

    // Pull msg_type + session out of the header JSON.
    var msg_type: []const u8 = "";
    var parsed = json.parseFromSlice(json.Value, gpa, m.header, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value == .object) {
      const o = parsed.value.object;
      if (o.get("msg_type")) |v| if (v == .string) { msg_type = v.string; };
      if (o.get("session")) |v| if (v == .string) {
        if (self.session.len == 0) self.session = gpa.dupe(u8, v.string) catch self.session;
      };
    }

    if (std.mem.eql(u8, msg_type, "kernel_info_request")) {
      self.kernelInfo(fd, m.header);
    } else if (std.mem.eql(u8, msg_type, "execute_request")) {
      self.execute(fd, m.header, m.content);
    } else if (std.mem.eql(u8, msg_type, "is_complete_request")) {
      self.isComplete(fd, m.header, m.content);
    } else if (std.mem.eql(u8, msg_type, "complete_request")) {
      self.complete(fd, m.header, m.content);
    } else if (std.mem.eql(u8, msg_type, "comm_info_request")) {
      self.send(fd, "comm_info_reply", m.header, "{\"status\":\"ok\",\"comms\":{}}", null) catch {};
    } else if (std.mem.eql(u8, msg_type, "shutdown_request")) {
      self.send(fd, "shutdown_reply", m.header, "{\"status\":\"ok\",\"restart\":false}", null) catch {};
      self.running = false;
    } else if (std.mem.eql(u8, msg_type, "interrupt_request")) {
      self.send(fd, "interrupt_reply", m.header, "{\"status\":\"ok\"}", null) catch {};
    } else if (std.mem.endsWith(u8, msg_type, "_request")) {
      // Unknown request: acknowledge minimally so the client isn't left hanging.
      const rt = std.fmt.allocPrint(gpa, "{s}_reply", .{msg_type[0 .. msg_type.len - "_request".len]}) catch return;
      defer gpa.free(rt);
      self.send(fd, rt, m.header, "{\"status\":\"ok\"}", null) catch {};
    }
  }

  fn kernelInfo(self: *Kernel, fd: posix.fd_t, parent: []const u8) void {
    self.iopubSend("status", parent, "{\"execution_state\":\"busy\"}");
    const content =
      "{\"status\":\"ok\",\"protocol_version\":\"" ++ PROTOCOL_VERSION ++ "\"," ++
      "\"implementation\":\"ink\",\"implementation_version\":\"0.1\"," ++
      "\"language_info\":{\"name\":\"ink\",\"version\":\"0.1\",\"mimetype\":\"text/x-ink\"," ++
      "\"file_extension\":\".k\",\"pygments_lexer\":\"q\"}," ++
      "\"banner\":\"ink array language kernel\",\"help_links\":[]}";
    self.send(fd, "kernel_info_reply", parent, content, null) catch {};
    self.iopubSend("status", parent, "{\"execution_state\":\"idle\"}");
  }

  fn execute(self: *Kernel, fd: posix.fd_t, parent: []const u8, content: []const u8) void {
    const gpa = self.gpa;
    var code: []const u8 = "";
    var silent = false;
    var store_history = true;
    var parsed = json.parseFromSlice(json.Value, gpa, content, .{}) catch {
      self.replyError(fd, parent, "ParseError", "bad execute_request");
      return;
    };
    defer parsed.deinit();
    if (parsed.value == .object) {
      const o = parsed.value.object;
      if (o.get("code")) |v| if (v == .string) { code = v.string; };
      if (o.get("silent")) |v| if (v == .bool) { silent = v.bool; };
      if (o.get("store_history")) |v| if (v == .bool) { store_history = v.bool; };
    }

    self.iopubSend("status", parent, "{\"execution_state\":\"busy\"}");

    if (!silent and store_history) self.exec_count += 1;

    // Broadcast execute_input so other front-ends echo the code.
    if (!silent) {
      const ein = std.fmt.allocPrint(gpa, "{{\"code\":{f},\"execution_count\":{d}}}",
        .{ jsonStr(code), self.exec_count }) catch null;
      if (ein) |s| { defer gpa.free(s); self.iopubSend("execute_input", parent, s); }
    }

    const trimmed = std.mem.trim(u8, code, " \t\r\n");
    if (trimmed.len == 0) {
      self.replyOk(fd, parent);
      self.iopubSend("status", parent, "{\"execution_state\":\"idle\"}");
      return;
    }

    // Capture io-verb side-effect output by pointing vm.out at a buffer.
    var capture = MockWriter.init(gpa) catch {
      self.replyError(fd, parent, "InternalError", "oom");
      return;
    };
    defer capture.deinit();
    var cap_writer = capture.writer();
    const saved_out = self.vm.out;
    self.vm.out = &cap_writer.interface;
    defer self.vm.out = saved_out;

    self.loader.autoLoad(self.vm, trimmed) catch {};
    const ev = self.repl.eval(trimmed, true) catch |err| {
      self.vm.out = saved_out;
      const ev_msg = std.fmt.allocPrint(gpa, "eval error: {s}", .{@errorName(err)}) catch "eval error";
      defer if (!std.mem.eql(u8, ev_msg, "eval error")) gpa.free(ev_msg);
      self.emitError(parent, "Error", ev_msg);
      self.replyError(fd, parent, "Error", ev_msg);
      self.iopubSend("status", parent, "{\"execution_state\":\"idle\"}");
      return;
    };
    defer ev.deinit(gpa);
    self.vm.out = saved_out;

    // Side-effect prints go out as a stdout stream.
    const side = capture.getText();
    if (!silent and side.len > 0) {
      const sc = std.fmt.allocPrint(gpa, "{{\"name\":\"stdout\",\"text\":{f}}}", .{jsonStr(side)}) catch null;
      if (sc) |s| { defer gpa.free(s); self.iopubSend("stream", parent, s); }
    }

    // Treat both eval exceptions (is_error) and ink error *values* (e.g. `!type`)
    // as Jupyter errors so the front-end renders them as errors, not results.
    var err_text: ?[]const u8 = null;
    if (ev.is_error) {
      for (ev.results) |r| if (r.output.len > 0) { err_text = r.output; };
      if (err_text == null) err_text = "error";
    } else {
      for (ev.results) |r| if (r.value.tag() == .err and r.output.len > 0) { err_text = r.output; };
    }
    if (err_text) |emsg| {
      self.emitError(parent, "Error", emsg);
      self.replyError(fd, parent, "Error", emsg);
      self.iopubSend("status", parent, "{\"execution_state\":\"idle\"}");
      return;
    }

    // Join the non-empty value renderings into one execute_result.
    if (!silent) {
      var joined: std.ArrayList(u8) = .empty;
      defer joined.deinit(gpa);
      for (ev.results) |r| {
        if (r.output.len == 0) continue;
        if (joined.items.len > 0) joined.append(gpa, '\n') catch {};
        joined.appendSlice(gpa, r.output) catch {};
      }
      if (joined.items.len > 0) {
        const rc = std.fmt.allocPrint(gpa,
          "{{\"execution_count\":{d},\"data\":{{\"text/plain\":{f}}},\"metadata\":{{}}}}",
          .{ self.exec_count, jsonStr(joined.items) }) catch null;
        if (rc) |s| { defer gpa.free(s); self.iopubSend("execute_result", parent, s); }
      }
    }

    self.replyOk(fd, parent);
    self.iopubSend("status", parent, "{\"execution_state\":\"idle\"}");
  }

  fn replyOk(self: *Kernel, fd: posix.fd_t, parent: []const u8) void {
    const c = std.fmt.allocPrint(self.gpa,
      "{{\"status\":\"ok\",\"execution_count\":{d},\"user_expressions\":{{}},\"payload\":[]}}",
      .{self.exec_count}) catch return;
    defer self.gpa.free(c);
    self.send(fd, "execute_reply", parent, c, null) catch {};
  }

  fn replyError(self: *Kernel, fd: posix.fd_t, parent: []const u8, ename: []const u8, evalue: []const u8) void {
    const c = std.fmt.allocPrint(self.gpa,
      "{{\"status\":\"error\",\"execution_count\":{d},\"ename\":{f},\"evalue\":{f},\"traceback\":[]}}",
      .{ self.exec_count, jsonStr(ename), jsonStr(evalue) }) catch return;
    defer self.gpa.free(c);
    self.send(fd, "execute_reply", parent, c, null) catch {};
  }

  fn emitError(self: *Kernel, parent: []const u8, ename: []const u8, evalue: []const u8) void {
    const c = std.fmt.allocPrint(self.gpa,
      "{{\"ename\":{f},\"evalue\":{f},\"traceback\":[{f}]}}",
      .{ jsonStr(ename), jsonStr(evalue), jsonStr(evalue) }) catch return;
    defer self.gpa.free(c);
    self.iopubSend("error", parent, c);
  }

  fn isComplete(self: *Kernel, fd: posix.fd_t, parent: []const u8, content: []const u8) void {
    const gpa = self.gpa;
    var code: []const u8 = "";
    var parsed = json.parseFromSlice(json.Value, gpa, content, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    if (parsed) |p| if (p.value == .object) {
      if (p.value.object.get("code")) |v| if (v == .string) { code = v.string; };
    };
    // An unterminated multi-line string means more input is expected.
    const status = if (Lexer.endsOpenString(code)) "incomplete" else "complete";
    const c = std.fmt.allocPrint(gpa, "{{\"status\":\"{s}\",\"indent\":\"\"}}", .{status}) catch return;
    defer gpa.free(c);
    self.send(fd, "is_complete_reply", parent, c, null) catch {};
  }

  fn complete(self: *Kernel, fd: posix.fd_t, parent: []const u8, content: []const u8) void {
    const gpa = self.gpa;
    var cursor: i64 = 0;
    var parsed = json.parseFromSlice(json.Value, gpa, content, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    if (parsed) |p| if (p.value == .object) {
      if (p.value.object.get("cursor_pos")) |v| if (v == .integer) { cursor = v.integer; };
    };
    const c = std.fmt.allocPrint(gpa,
      "{{\"status\":\"ok\",\"matches\":[],\"cursor_start\":{d},\"cursor_end\":{d},\"metadata\":{{}}}}",
      .{ cursor, cursor }) catch return;
    defer gpa.free(c);
    self.send(fd, "complete_reply", parent, c, null) catch {};
  }
};

// ── JSON string escaping (std.fmt {f} formatter) ────────────────────────────
const JsonStr = struct {
  s: []const u8,
  pub fn format(self: JsonStr, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (self.s) |c| switch (c) {
      '"' => try w.writeAll("\\\""),
      '\\' => try w.writeAll("\\\\"),
      '\n' => try w.writeAll("\\n"),
      '\r' => try w.writeAll("\\r"),
      '\t' => try w.writeAll("\\t"),
      else => if (c < 0x20) {
        try w.print("\\u{x:0>4}", .{c});
      } else try w.writeByte(c),
    };
    try w.writeByte('"');
  }
};
fn jsonStr(s: []const u8) JsonStr { return .{ .s = s }; }

// ── small helpers ───────────────────────────────────────────────────────────
fn epochSecs() i64 {
  var ts: std.c.timespec = undefined;
  if (std.c.clock_gettime(posix.CLOCK.REALTIME, &ts) != 0) return 0;
  return @intCast(ts.sec);
}

fn isoDate(buf: *[32]u8) []const u8 {
  const secs: u64 = @intCast(@max(@as(i64, 0), epochSecs()));
  const es = std.time.epoch.EpochSeconds{ .secs = secs };
  const eday = es.getEpochDay();
  const yd = eday.calculateYearDay();
  const md = yd.calculateMonthDay();
  const ds = es.getDaySeconds();
  return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000000Z", .{
    yd.year, md.month.numeric(), md.day_index + 1,
    ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
  }) catch "1970-01-01T00:00:00.000000Z";
}

// ── per-connection read + frame extraction ──────────────────────────────────
// Read whatever is available on a peer fd, then peel off complete ZMTP frames,
// assembling multipart messages and invoking `onMsg` for each complete one.
fn pumpConn(gpa: Alloc, sock: *Socket, ci: usize, onMsg: ?*const fn (*Kernel, posix.fd_t, [][]u8) void, kern: ?*Kernel) bool {
  const c = &sock.conns.items[ci];
  var tmp: [4096]u8 = undefined;
  const n = posix.read(c.fd, &tmp) catch |e| {
    if (e == error.WouldBlock) return true;
    return false; // treat as closed
  };
  if (n == 0) return false; // EOF
  c.in.appendSlice(gpa, tmp[0..n]) catch return false;

  while (true) {
    // Strip the 64-byte greeting prefix once.
    if (!c.got_greeting) {
      if (c.in.items.len < 64) break;
      consume(gpa, &c.in, 64);
      c.got_greeting = true;
      continue;
    }
    const frame = nextFrame(c.in.items) orelse break;
    const total = frame.consumed;
    if (frame.command) {
      // READY / SUBSCRIBE / PING — no message-layer meaning here.
      consume(gpa, &c.in, total);
      continue;
    }
    const part = gpa.dupe(u8, frame.body) catch { consume(gpa, &c.in, total); continue; };
    c.parts.append(gpa, part) catch { gpa.free(part); consume(gpa, &c.in, total); continue; };
    consume(gpa, &c.in, total);
    if (!frame.more) {
      // Complete multipart message.
      switch (sock.kind) {
        .rep => echoBack(c.fd, c.parts.items), // heartbeat
        else => if (onMsg) |f| if (kern) |k| f(k, c.fd, c.parts.items),
      }
      for (c.parts.items) |p| gpa.free(p);
      c.parts.clearRetainingCapacity();
    }
  }
  return true;
}

const Frame = struct { body: []const u8, more: bool, command: bool, consumed: usize };

fn nextFrame(buf: []const u8) ?Frame {
  if (buf.len < 1) return null;
  const flags = buf[0];
  const more = (flags & 0x01) != 0;
  const command = (flags & 0x04) != 0;
  const long = (flags & 0x02) != 0;
  var off: usize = 1;
  var len: usize = 0;
  if (long) {
    if (buf.len < off + 8) return null;
    len = @intCast(std.mem.readInt(u64, buf[off..][0..8], .big));
    off += 8;
  } else {
    if (buf.len < off + 1) return null;
    len = buf[off];
    off += 1;
  }
  if (buf.len < off + len) return null;
  return .{ .body = buf[off .. off + len], .more = more, .command = command, .consumed = off + len };
}

fn consume(gpa: Alloc, buf: *std.ArrayList(u8), n: usize) void {
  _ = gpa;
  const rest = buf.items[n..];
  std.mem.copyForwards(u8, buf.items[0..rest.len], rest);
  buf.shrinkRetainingCapacity(rest.len);
}

// Heartbeat: echo every received frame verbatim back to the REQ peer.
fn echoBack(fd: Fd, parts: [][]u8) void {
  // We dropped the frame flags; re-frame as a multipart (REQ delimiter+payload
  // both arrive as parts, so re-send each with MORE on all but the last).
  for (parts, 0..) |p, i| {
    const more = i + 1 < parts.len;
    var hdr: [10]u8 = undefined;
    var hlen: usize = 0;
    var flags: u8 = 0;
    if (more) flags |= 0x01;
    if (p.len < 256) {
      hdr[0] = flags; hdr[1] = @intCast(p.len); hlen = 2;
    } else {
      hdr[0] = flags | 0x02;
      std.mem.writeInt(u64, hdr[1..9], p.len, .big);
      hlen = 9;
    }
    writeAll(fd, hdr[0..hlen]) catch return;
    writeAll(fd, p) catch return;
  }
}

// ── entry point ─────────────────────────────────────────────────────────────
pub fn run(gpa: Alloc, conn_path: []const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  const text = try std.Io.Dir.cwd().readFileAlloc(io, conn_path, gpa, std.Io.Limit.limited(64 * 1024));
  defer gpa.free(text);

  var parsed = try json.parseFromSlice(json.Value, gpa, text, .{});
  defer parsed.deinit();
  if (parsed.value != .object) return error.BadConnectionFile;
  const o = parsed.value.object;
  const cfg = Config{
    .ip = cfgStr(o, "ip", "127.0.0.1"),
    .transport = cfgStr(o, "transport", "tcp"),
    .key = cfgStr(o, "key", ""),
    .shell_port = cfgPort(o, "shell_port"),
    .control_port = cfgPort(o, "control_port"),
    .stdin_port = cfgPort(o, "stdin_port"),
    .hb_port = cfgPort(o, "hb_port"),
    .iopub_port = cfgPort(o, "iopub_port"),
  };

  const vm = try VM.create(gpa);
  defer vm.deinit();
  var loader = modules.ModuleLoader.init(gpa);
  defer loader.deinit();
  loader.scan("lib") catch {};

  var k = Kernel{
    .gpa = gpa,
    .vm = vm,
    .loader = &loader,
    .repl = Repl.init(gpa, vm),
    .key = try gpa.dupe(u8, cfg.key),
    .shell = try Socket.bind(cfg, cfg.shell_port, .router),
    .control = try Socket.bind(cfg, cfg.control_port, .router),
    .stdin = try Socket.bind(cfg, cfg.stdin_port, .router),
    .hb = try Socket.bind(cfg, cfg.hb_port, .rep),
    .iopub = try Socket.bind(cfg, cfg.iopub_port, .pub_),
  };
  defer gpa.free(k.key);
  defer if (k.session.len > 0) gpa.free(k.session);

  std.log.scoped(.jupyter).info("ink kernel listening (shell={d} iopub={d})", .{ cfg.shell_port, cfg.iopub_port });

  const sockets = [_]*Socket{ &k.shell, &k.control, &k.stdin, &k.hb, &k.iopub };
  while (k.running) {
    // Build the pollfd set: one entry per listener + one per live connection.
    var fds: std.ArrayList(posix.pollfd) = .empty;
    defer fds.deinit(gpa);
    // Map each pollfd back to (socket, conn-index|-1 for listener).
    var owners: std.ArrayList(struct { s: *Socket, ci: isize }) = .empty;
    defer owners.deinit(gpa);
    for (sockets) |s| {
      try fds.append(gpa, .{ .fd = s.fd, .events = posix.POLL.IN, .revents = 0 });
      try owners.append(gpa, .{ .s = s, .ci = -1 });
      for (s.conns.items, 0..) |c, i| {
        try fds.append(gpa, .{ .fd = c.fd, .events = posix.POLL.IN, .revents = 0 });
        try owners.append(gpa, .{ .s = s, .ci = @intCast(i) });
      }
    }

    const ready = try posix.poll(fds.items, 1000);
    if (ready == 0) continue;

    // Track connections to drop after this pass (indices into each socket).
    for (fds.items, owners.items) |pfd, owner| {
      if ((pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) == 0) continue;
      if (owner.ci < 0) {
        owner.s.accept(gpa) catch {};
      } else {
        const ci: usize = @intCast(owner.ci);
        if (ci >= owner.s.conns.items.len) continue;
        const alive = pumpConn(gpa, owner.s, ci, handleRequestThunk, &k);
        if (!alive) closeConn(gpa, owner.s, ci);
      }
    }
  }
  std.log.scoped(.jupyter).info("ink kernel shutting down", .{});
}

fn handleRequestThunk(k: *Kernel, fd: posix.fd_t, parts: [][]u8) void {
  k.handleRequest(fd, parts);
}

fn closeConn(gpa: Alloc, sock: *Socket, ci: usize) void {
  const conn = &sock.conns.items[ci];
  _ = libc.close(conn.fd);
  conn.in.deinit(gpa);
  for (conn.parts.items) |p| gpa.free(p);
  conn.parts.deinit(gpa);
  _ = sock.conns.swapRemove(ci);
}

// ── kernelspec installation ─────────────────────────────────────────────────
// `ink jupyter install` writes a kernelspec under the user's Jupyter data dir
// so editors (Zed, JupyterLab, …) can discover the ink kernel.
fn selfExePath(buf: *[4096]u8) ![]const u8 {
  if (builtin.os.tag == .macos) {
    var size: u32 = buf.len;
    if (std.c._NSGetExecutablePath(buf, &size) != 0) return error.PathTooLong;
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf)), 0);
  }
  const n = std.c.readlink("/proc/self/exe", buf, buf.len);
  if (n <= 0) return error.NoExePath;
  return buf[0..@intCast(n)];
}

pub fn install(gpa: Alloc) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  var exebuf: [4096]u8 = undefined;
  const exe = try selfExePath(&exebuf);

  const home = std.c.getenv("HOME") orelse return error.NoHome;
  const home_s = std.mem.sliceTo(home, 0);
  const dir = switch (builtin.os.tag) {
    .macos => try std.fmt.allocPrint(gpa, "{s}/Library/Jupyter/kernels/ink", .{home_s}),
    else => try std.fmt.allocPrint(gpa, "{s}/.local/share/jupyter/kernels/ink", .{home_s}),
  };
  defer gpa.free(dir);

  makeDirsAbsolute(io, dir);
  const spec = try std.fmt.allocPrint(gpa,
    "{{\n  \"argv\": [{f}, \"jupyter\", \"-f\", \"{{connection_file}}\"],\n" ++
    "  \"display_name\": \"ink\",\n  \"language\": \"ink\",\n  \"interrupt_mode\": \"message\"\n}}\n",
    .{jsonStr(exe)});
  defer gpa.free(spec);

  const path = try std.fmt.allocPrint(gpa, "{s}/kernel.json", .{dir});
  defer gpa.free(path);
  var d = try std.Io.Dir.createFileAbsolute(io, path, .{});
  defer d.close(io);
  try d.writeStreamingAll(io, spec);

  var stdout_buf: [256]u8 = undefined;
  var w = std.Io.File.stdout().writer(io, &stdout_buf);
  try w.interface.print("Installed ink kernelspec to {s}\n", .{path});
  try w.interface.flush();
}

// Create every component of an absolute directory path, ignoring dirs that
// already exist (this std has no recursive absolute makePath).
fn makeDirsAbsolute(io: std.Io, dir: []const u8) void {
  var i: usize = 1; // skip leading '/'
  while (i <= dir.len) : (i += 1) {
    if (i == dir.len or dir[i] == '/') {
      std.Io.Dir.createDirAbsolute(io, dir[0..i], .default_dir) catch {};
    }
  }
}
