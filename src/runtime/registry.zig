const std = @import("std");
const A = std.ArrayList;
const Alloc = std.mem.Allocator;

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
