const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("value.zig").V;

// Per-type vtable for extension objects.  Extensions fill this in and pass it
// to ExtRegistry.register(); the VM then uses it for RC, format, and dispatch.
pub const ExtVTable = struct {
  name:       []const u8,
  ref_fn:     ?*const fn (data: *anyopaque) void       = null,
  deinit_fn:  *const fn (data: *anyopaque) void,
  format_fn:  ?*const fn (data: *anyopaque, buf: *[256]u8) usize = null,
  // Optional: make the ExtObj callable from K.
  // call1_fn(data, x)    — monad: f x
  // call2_fn(data, x, y) — dyad:  x f y
  // Returning V{.err = .nyi} falls back to a type error.
  call1_fn:   ?*const fn (data: *anyopaque, x: V) V  = null,
  call2_fn:   ?*const fn (data: *anyopaque, x: V, y: V) V = null,
};

// Heap-allocated wrapper owned by V.x.  The VM manages this struct's lifetime
// via ref()/deinit(); the extension manages `data` through the vtable.
pub const ExtObj = struct {
  rc:      u32,
  type_id: u32,
  vtable:  *const ExtVTable,
  data:    *anyopaque,

  pub fn ref(obj: *ExtObj) *ExtObj {
    if (obj.vtable.ref_fn) |f| f(obj.data);
    obj.rc += 1;
    return obj;
  }

  pub fn deinit(obj: *ExtObj, alloc: Alloc) void {
    obj.rc -= 1;
    if (obj.rc == 0) {
      obj.vtable.deinit_fn(obj.data);
      alloc.destroy(obj);
    }
  }
};

// Holds registered vtables and open library handles.
// Kept alive for the lifetime of the VM; libraries are closed on deinit.
pub const ExtRegistry = struct {
  alloc: Alloc,
  types: std.ArrayListUnmanaged(ExtVTable) = .empty,
  libs:  std.ArrayListUnmanaged(std.DynLib) = .empty,

  pub fn init(alloc: Alloc) ExtRegistry {
    return .{ .alloc = alloc };
  }

  pub fn deinit(reg: *ExtRegistry) void {
    reg.types.deinit(reg.alloc);
    for (reg.libs.items) |*lib| lib.close();
    reg.libs.deinit(reg.alloc);
  }

  // Register a type and return its type_id.
  pub fn register(reg: *ExtRegistry, vt: ExtVTable) !u32 {
    const id: u32 = @intCast(reg.types.items.len);
    try reg.types.append(reg.alloc, vt);
    return id;
  }

  pub fn vtableFor(reg: *const ExtRegistry, type_id: u32) ?*const ExtVTable {
    if (type_id >= reg.types.items.len) return null;
    return &reg.types.items[type_id];
  }

  // dlopen `path` and call its `terse_init(*anyopaque)` entry point.
  // The extension receives a *ExtRegistry cast to *anyopaque to avoid
  // requiring the extension to import ext.zig types.
  pub fn load(reg: *ExtRegistry, path: []const u8) !void {
    var lib = try std.DynLib.open(path);
    errdefer lib.close();
    const InitFn = *const fn (reg: *anyopaque) void;
    if (lib.lookup(InitFn, "terse_init")) |init_fn| init_fn(reg);
    try reg.libs.append(reg.alloc, lib);
  }
};
