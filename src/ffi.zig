/// FFI module: bridges ink K values to C shared-library functions.
///
/// Usage in K:
///   f: "lib.so" 2: (`sym; 1)   / load 1-arg C function
///   f @ x                      / call it
///   f[x; y]                    / 2-arg variant
///
/// C side (see include/k.h):
///   K my_fn(K x) { return ki(k_i(x) + 1); }

const std = @import("std");
const Alloc = std.mem.Allocator;
const V    = @import("noun/value.zig").V;
const N    = @import("noun/array.zig").N;
const K    = @import("noun/class.zig").K;
const plugin = @import("noun/plugin.zig");
const ExtObj   = plugin.ExtObj;
const ExtVTable = plugin.ExtVTable;

// ── KBox: the C-facing K value ────────────────────────────────────────────────
//
// C code never sees V directly — it works with opaque `void*` pointers to KBox.
// All k_* constructor functions allocate a KBox from the C allocator;
// ku() decrements the refcount and frees when it reaches zero.

pub const KBox = struct {
  rc:  u32,
  tag: i8,   // matches K serial code (KT_* in k.h)
  n:   i32,  // array length or -1 for atoms
  v:   V,
};

const c_alloc = std.heap.c_allocator;

// ── Thread-local VM pointer for C callbacks (k_sym etc.) ─────────────────────

threadlocal var current_vm: ?*anyopaque = null;

pub fn setCurrentVm(vm: *anyopaque) void { current_vm = vm; }
pub fn clearCurrentVm() void            { current_vm = null; }

// ── Boxing / Unboxing ─────────────────────────────────────────────────────────

fn box(v: V) !*KBox {
  const b = try c_alloc.create(KBox);
  b.* = .{
    .rc  = 1,
    .tag = tagOfV(v),
    .n   = lenOfV(v),
    .v   = v,
  };
  return b;
}

fn unbox(b: *KBox, alloc: Alloc) V {
  const v = b.v;
  _ = alloc;
  b.v = .blank; // prevent double-free when KBox is released
  c_alloc.destroy(b);
  return v;
}

fn tagOfV(v: V) i8 {
  return @intCast(v.tag().serCode());
}

fn lenOfV(v: V) i32 {
  return switch (v.tag()) {
    .B, .I, .F, .S, .C => @intCast(v.len()),
    .L => @intCast(v.len()),
    else => -1,
  };
}

// ── k_* C API (exported for use in extension .so files) ──────────────────────
//
// These match the declarations in include/k.h.

export fn ki(n: i32) ?*KBox {
  return box(.{ .i = n }) catch null;
}
export fn kf(f: f32) ?*KBox {
  return box(.{ .f = f }) catch null;
}
export fn kc(c: u8) ?*KBox {
  return box(.{ .c = c }) catch null;
}
export fn kb(b: c_int) ?*KBox {
  return box(.{ .b = b != 0 }) catch null;
}
export fn kerr() ?*KBox {
  return box(.{ .err = .domain }) catch null;
}
export fn ks(name: [*:0]const u8) ?*KBox {
  const vm_ptr = current_vm orelse return null;
  const VM = @import("runtime/vm.zig").VM;
  const vm: *VM = @ptrCast(@alignCast(vm_ptr));
  const id = vm.intern(std.mem.span(name)) catch return null;
  return box(.{ .s = id }) catch null;
}

// Char array of length n (uninitialized)
export fn KC(n: i32) ?*KBox {
  if (n < 0) return null;
  const arr = N(u8).init(c_alloc, @intCast(n)) catch return null;
  return box(.{ .C = arr }) catch { arr.deinit(c_alloc); return null; };
}
// Int array of length n (zero-initialized)
export fn KI(n: i32) ?*KBox {
  if (n < 0) return null;
  const arr = N(i32).init(c_alloc, @intCast(n)) catch return null;
  @memset(arr.slice(), 0);
  return box(.{ .I = arr }) catch { arr.deinit(c_alloc); return null; };
}
// Float array of length n (zero-initialized)
export fn KF(n: i32) ?*KBox {
  if (n < 0) return null;
  const arr = N(f32).init(c_alloc, @intCast(n)) catch return null;
  @memset(arr.slice(), 0);
  return box(.{ .F = arr }) catch { arr.deinit(c_alloc); return null; };
}
// Mixed list of n blank elements
export fn KL(n: i32) ?*KBox {
  if (n < 0) return null;
  const arr = N(V).init(c_alloc, @intCast(n)) catch return null;
  @memset(arr.slice(), .blank);
  return box(.{ .L = arr }) catch { arr.deinit(c_alloc); return null; };
}

// Inspection
export fn kt(x: ?*KBox) i8 {
  const b = x orelse return -1;
  return b.tag;
}
export fn kn(x: ?*KBox) i32 {
  const b = x orelse return -1;
  return b.n;
}
export fn ki_val(x: ?*KBox) i32 {
  const b = x orelse return 0;
  return switch (b.v.tag()) {
    .i => b.v.i,
    .f => @intFromFloat(b.v.f),
    .b => if (b.v.b) 1 else 0,
    .c => b.v.c,
    else => 0,
  };
}
export fn kf_val(x: ?*KBox) f32 {
  const b = x orelse return 0;
  return switch (b.v.tag()) {
    .f => b.v.f,
    .i => @floatFromInt(b.v.i),
    .b => if (b.v.b) 1.0 else 0.0,
    else => 0,
  };
}
export fn kc_val(x: ?*KBox) u8 {
  const b = x orelse return 0;
  return if (b.v.tag() == .c) b.v.c else 0;
}
export fn kb_val(x: ?*KBox) c_int {
  const b = x orelse return 0;
  return if (b.v.tag() == .b and b.v.b) 1 else 0;
}
export fn kip(x: ?*KBox) ?[*]i32 {
  const b = x orelse return null;
  return if (b.v.tag() == .I) b.v.I.slice().ptr else null;
}
export fn kfp(x: ?*KBox) ?[*]f32 {
  const b = x orelse return null;
  return if (b.v.tag() == .F) b.v.F.slice().ptr else null;
}
export fn kcp(x: ?*KBox) ?[*]u8 {
  const b = x orelse return null;
  return if (b.v.tag() == .C) b.v.C.slice().ptr else null;
}
export fn klp(x: ?*KBox) ?[*]*KBox {
  _ = x;
  return null; // list element access not yet implemented
}
export fn ku(x: ?*KBox) void {
  const b = x orelse return;
  b.rc -= 1;
  if (b.rc == 0) {
    b.v.deinit(c_alloc);
    c_alloc.destroy(b);
  }
}

// ── FFI function wrapper ──────────────────────────────────────────────────────

const FfiFn1 = *const fn (?*KBox) callconv(.c) ?*KBox;
const FfiFn2 = *const fn (?*KBox, ?*KBox) callconv(.c) ?*KBox;

const FfiData = struct {
  lib:   std.DynLib,
  fn_ptr: *anyopaque,
  arity:  u8,
};

fn ffiDeinit(data: *anyopaque) void {
  const d: *FfiData = @ptrCast(@alignCast(data));
  d.lib.close();
  std.heap.c_allocator.destroy(d);
}

fn ffiCall1(data: *anyopaque, x: V) V {
  const d: *FfiData = @ptrCast(@alignCast(data));
  const f: FfiFn1 = @ptrCast(@alignCast(d.fn_ptr));
  const bx = box(x.ref()) catch return .{ .err = .memory };
  defer { bx.v = .blank; c_alloc.destroy(bx); } // we loaned x, don't double-free
  const result = f(bx) orelse return .{ .err = .domain };
  return unbox(result, c_alloc);
}

fn ffiCall2(data: *anyopaque, x: V, y: V) V {
  const d: *FfiData = @ptrCast(@alignCast(data));
  const f: FfiFn2 = @ptrCast(@alignCast(d.fn_ptr));
  const bx = box(x.ref()) catch return .{ .err = .memory };
  defer { bx.v = .blank; c_alloc.destroy(bx); }
  const by = box(y.ref()) catch return .{ .err = .memory };
  defer { by.v = .blank; c_alloc.destroy(by); }
  const result = f(bx, by) orelse return .{ .err = .domain };
  return unbox(result, c_alloc);
}

const ffi_vtable_1 = ExtVTable{
  .name      = "ffi1",
  .deinit_fn = ffiDeinit,
  .call1_fn  = ffiCall1,
};
const ffi_vtable_2 = ExtVTable{
  .name      = "ffi2",
  .deinit_fn = ffiDeinit,
  .call1_fn  = ffiCall1,
  .call2_fn  = ffiCall2,
};

// ── 2: FFI load ───────────────────────────────────────────────────────────────
//
// Called from io.zig's WriteData handler when the pattern matches:
//   x = char array (library path)
//   y = list of [symbol, int arity]

pub fn ffiLoad(vm: *anyopaque, lib_path: []const u8, sym_name: []const u8, arity: u8) V {
  const VM = @import("runtime/vm.zig").VM;
  const the_vm: *VM = @ptrCast(@alignCast(vm));

  // Null-terminate path and symbol for DynLib / lookup
  var path_buf: [512]u8 = undefined;
  if (lib_path.len >= path_buf.len) return .{ .err = .domain };
  @memcpy(path_buf[0..lib_path.len], lib_path);
  path_buf[lib_path.len] = 0;

  var sym_buf: [256]u8 = undefined;
  if (sym_name.len >= sym_buf.len) return .{ .err = .domain };
  @memcpy(sym_buf[0..sym_name.len], sym_name);
  sym_buf[sym_name.len] = 0;

  var lib = std.DynLib.open(path_buf[0..lib_path.len :0]) catch return .{ .err = .io };
  const fn_ptr = lib.lookup(*anyopaque, sym_buf[0..sym_name.len :0]) orelse {
    lib.close();
    return .{ .err = .domain };
  };

  const data = c_alloc.create(FfiData) catch {
    lib.close();
    return .{ .err = .memory };
  };
  data.* = .{ .lib = lib, .fn_ptr = fn_ptr, .arity = arity };

  const obj = the_vm.alloc.create(ExtObj) catch {
    ffiDeinit(data);
    return .{ .err = .memory };
  };
  const vtable = if (arity >= 2) &ffi_vtable_2 else &ffi_vtable_1;
  obj.* = .{ .rc = 1, .type_id = 0, .vtable = vtable, .data = data };
  return .{ .x = obj };
}
