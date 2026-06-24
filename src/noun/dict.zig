const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("value.zig").V;
const Rc = @import("rc.zig").Rc;

pub const Dict = struct {
  ptr: *Rc,
  pub fn init(alloc: Alloc, keys: V, vals: V) !Dict {
    const p = try allocRc(alloc, V, 2); p.len = @intCast(keys.len());
    p.data(V)[0] = keys; p.data(V)[1] = vals;
    return .{ .ptr = p };
  }
  pub fn deinit(self: Dict, alloc: Alloc) void {
    self.ptr.rc -= 1; if (self.ptr.rc > 0) return;
    const d = self.ptr.data(V); d[0].deinit(alloc); d[1].deinit(alloc);
    freeRc(alloc, self.ptr, V, 2);
  }
  pub fn av(self: Dict) V { return self.ptr.data(V)[0]; }
  pub fn bv(self: Dict) V { return self.ptr.data(V)[1]; }
  pub fn avPtr(self: Dict) *V { return &self.ptr.data(V)[0]; }
  pub fn bvPtr(self: Dict) *V { return &self.ptr.data(V)[1]; }
  pub fn eq(self: Dict, other: Dict) bool { return self.av().eq(other.av()) and self.bv().eq(other.bv()); }
  pub fn clone(self: Dict, alloc: Alloc) !Dict { return try Dict.init(alloc, self.av().ref(), self.bv().ref()); }
};

fn allocRc(alloc: Alloc, comptime T: type, n: usize) !*Rc {
  const header_size = std.mem.alignForward(usize, @sizeOf(Rc), @alignOf(T));
  const raw = try alloc.alloc(u8, header_size + (n * @sizeOf(T)));
  const h = @as(*Rc, @ptrCast(@alignCast(raw.ptr)));
  h.* = .{ .rc = 1, .len = @intCast(n), .cap = @intCast(n), .meta = Rc.freshMeta() };
  return h;
}

fn freeRc(alloc: Alloc, r: *Rc, comptime T: type, n: usize) void {
  const header_size = std.mem.alignForward(usize, @sizeOf(Rc), @alignOf(T));
  alloc.free(@as([*]u8, @ptrCast(r))[0..header_size + (n * @sizeOf(T))]);
}
