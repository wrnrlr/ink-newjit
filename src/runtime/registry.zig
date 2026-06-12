const std = @import("std");
const A = std.ArrayList;
const Alloc = std.mem.Allocator;
const net = std.Io.net;

pub const Span = struct { id: u32, start: u32, end: u32 };

pub const Fs = struct {
  alloc: Alloc,
  texts: A([]const u8) = .empty,
  paths: A(?[]const u8) = .empty,
  ranges: A(Span) = .empty,

  pub fn init(alloc: Alloc) !Fs { return .{ .alloc = alloc }; }

  pub fn deinit(self: *Fs) void {
    for (self.texts.items) |t| self.alloc.free(t);
    for (self.paths.items) |p| if (p) |path| self.alloc.free(path);
    self.texts.deinit(self.alloc);
    self.paths.deinit(self.alloc);
    self.ranges.deinit(self.alloc);
  }

  pub fn addText(self: *Fs, text: []const u8) !u32 {
    const dupe = try self.alloc.dupe(u8, text);
    try self.texts.append(self.alloc, dupe);
    try self.paths.append(self.alloc, null);
    return @intCast(self.texts.items.len - 1);
  }

  pub fn addFile(self: *Fs, path: []const u8, text: []const u8) !u32 {
    try self.texts.append(self.alloc, text);
    try self.paths.append(self.alloc, try self.alloc.dupe(u8, path));
    return @intCast(self.texts.items.len - 1);
  }

  pub fn findFile(self: Fs, path: []const u8) ?u32 {
    for (self.paths.items, 0..) |p, i| {
      if (p) |pp| {
        if (std.mem.eql(u8, pp, path)) return @intCast(i);
      }
    }
    return null;
  }

  pub fn getFileText(self: Fs, id: u32) []const u8 {
    return self.texts.items[id];
  }

  pub fn getPath(self: Fs, id: u32) ?[]const u8 {
    if (id >= self.paths.items.len) return null;
    return self.paths.items[id];
  }

  pub fn updateFile(self: *Fs, id: u32, content: []const u8) !void {
    const old = self.texts.items[id];
    self.texts.items[id] = try self.alloc.dupe(u8, content);
    self.alloc.free(old);
  }

  pub fn addRange(self: *Fs, id: u32, start: u32, end: u32) !u32 {
    try self.ranges.append(self.alloc, .{ .id = id, .start = start, .end = end });
    return @intCast(self.ranges.items.len - 1);
  }

  pub fn getSource(self: Fs, id: u32) []const u8 {
    const r = self.ranges.items[id];
    return self.texts.items[r.id][r.start..r.end];
  }
};

// ---------------------------------------------------------------------------
// TCP/IPC connection registry
// ---------------------------------------------------------------------------

/// A live TCP connection — either client-initiated, server-accepted, or a pure listener.
/// Pure listeners (created by `netListenOnly`) have server!=null, stream==null.
pub const Conn = struct {
  server: ?net.Server = null,  // non-null when this side is the listener
  stream: ?net.Stream = null,  // null only for pure-listening handles

  /// Returns true if this handle is a listening socket that has not yet accepted a client.
  pub fn isListening(self: Conn) bool { return self.stream == null; }

  /// The underlying file descriptor (server listen fd for listeners, stream fd for connections).
  pub fn fd(self: *const Conn) std.posix.fd_t {
    if (self.stream) |s| return s.socket.handle;
    return self.server.?.socket.handle;
  }

  pub fn deinit(self: *Conn) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (self.stream) |*s| s.close(io);
    if (self.server) |*s| s.deinit(io);
  }
};

/// Registry of open TCP connections.  Handles start at `BASE` to avoid
/// collision with file handles (which are plain array indices starting at 0).
pub const Conns = struct {
  pub const BASE: u32 = 0x8000;

  alloc: Alloc,
  map:   std.AutoHashMap(u32, Conn),
  next:  u32,

  pub fn init(alloc: Alloc) Conns {
    return .{
      .alloc = alloc,
      .map   = std.AutoHashMap(u32, Conn).init(alloc),
      .next  = BASE,
    };
  }

  pub fn deinit(self: *Conns) void {
    var it = self.map.valueIterator();
    while (it.next()) |c| c.deinit();
    self.map.deinit();
  }

  pub fn add(self: *Conns, conn: Conn) !u32 {
    const id = self.next;
    self.next += 1;
    try self.map.put(id, conn);
    return id;
  }

  pub fn get(self: *Conns, id: u32) ?*Conn {
    return self.map.getPtr(id);
  }

  pub fn remove(self: *Conns, id: u32) void {
    if (self.map.fetchRemove(id)) |entry| {
      var c = entry.value;
      c.deinit();
    }
  }

  pub fn isConn(id: u32) bool { return id >= BASE; }
};
