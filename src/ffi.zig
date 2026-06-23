/// FFI module: bridges ink K values to C shared-library functions.
///
/// Usage in K:
///   f: "lib.so" 2: (`sym; 1)   / load 1-arg C function
///   f @ x                      / call it
///   f[x; y]                    / 2-arg variant
///
/// C side (see include/k.h):
///   K my_fn(K x) { return ki(ki_val(x) + 1); }

const std = @import("std");
const Alloc = std.mem.Allocator;
const V    = @import("noun/value.zig").V;
const N    = @import("noun/array.zig").N;
const K    = @import("noun/class.zig").K;
const Dict = @import("noun/dict.zig").Dict;
const plugin = @import("noun/plugin.zig");
const ExtObj   = plugin.ExtObj;
const ExtVTable = plugin.ExtVTable;

// ── KBox: the C-facing K value ────────────────────────────────────────────────

pub const KBox = struct {
  rc:  u32,
  tag: i8,   // matches K serial code (KT_* in k.h)
  n:   i32,  // array length or -1 for atoms
  v:   V,
};

// ── KRegistry: function-pointer table passed to terse_init ────────────────────
// Extensions receive this as their `reg` argument in terse_init and use it to
// resolve host k_* symbols without relying on dlsym, which fails when the
// linker dead-strips unreferenced export functions in release builds.
// Field order MUST match KRegistry in include/k.h and all extension sources.
pub const KRegistry = extern struct {
    ki:          *const fn (i32)                         callconv(.c) ?*KBox,
    kf:          *const fn (f32)                         callconv(.c) ?*KBox,
    kc:          *const fn (u8)                          callconv(.c) ?*KBox,
    kb:          *const fn (c_int)                       callconv(.c) ?*KBox,
    ks:          *const fn ([*:0]const u8)               callconv(.c) ?*KBox,
    kerr:        *const fn ()                            callconv(.c) ?*KBox,
    KC:          *const fn (i32)                         callconv(.c) ?*KBox,
    KI:          *const fn (i32)                         callconv(.c) ?*KBox,
    KF:          *const fn (i32)                         callconv(.c) ?*KBox,
    KL:          *const fn (i32)                         callconv(.c) ?*KBox,
    kt:          *const fn (?*KBox)                      callconv(.c) i8,
    kn:          *const fn (?*KBox)                      callconv(.c) i32,
    ki_val:      *const fn (?*KBox)                      callconv(.c) i32,
    kf_val:      *const fn (?*KBox)                      callconv(.c) f32,
    kc_val:      *const fn (?*KBox)                      callconv(.c) u8,
    kb_val:      *const fn (?*KBox)                      callconv(.c) c_int,
    kip:         *const fn (?*KBox)                      callconv(.c) ?[*]i32,
    kfp:         *const fn (?*KBox)                      callconv(.c) ?[*]f32,
    kcp:         *const fn (?*KBox)                      callconv(.c) ?[*]u8,
    klp:         *const fn (?*KBox)                      callconv(.c) ?[*]?*KBox,
    ku:          *const fn (?*KBox)                      callconv(.c) void,
    k_list_set:  *const fn (?*KBox, i32, ?*KBox)         callconv(.c) i32,
    k_call:      *const fn (?*KBox, ?*KBox)              callconv(.c) ?*KBox,
    k_call2:     *const fn (?*KBox, ?*KBox, ?*KBox)      callconv(.c) ?*KBox,
    k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?*KBox) callconv(.c) ?*KBox,
    // Appended after k_make_dict so existing extensions' (shorter) mirrors stay
    // aligned — they read a prefix and ignore this field.
    k_list_get: *const fn (?*KBox, i32) callconv(.c) ?*KBox,
};

export const k_registry: KRegistry = .{
    .ki          = &ki,
    .kf          = &kf,
    .kc          = &kc,
    .kb          = &kb,
    .ks          = &ks,
    .kerr        = &kerr,
    .KC          = &KC,
    .KI          = &KI,
    .KF          = &KF,
    .KL          = &KL,
    .kt          = &kt,
    .kn          = &kn,
    .ki_val      = &ki_val,
    .kf_val      = &kf_val,
    .kc_val      = &kc_val,
    .kb_val      = &kb_val,
    .kip         = &kip,
    .kfp         = &kfp,
    .kcp         = &kcp,
    .klp         = &klp,
    .ku          = &ku,
    .k_list_set  = &k_list_set,
    .k_call      = &k_call,
    .k_call2     = &k_call2,
    .k_make_dict = &k_make_dict,
    .k_list_get  = &k_list_get,
};

const c_alloc = std.heap.c_allocator;

// ── Thread-local VM pointer (set around every C call) ─────────────────────────

threadlocal var current_vm: ?*anyopaque = null;

pub fn setCurrentVm(vm: *anyopaque) void  { current_vm = vm; }
pub fn clearCurrentVm() void             { current_vm = null; }
pub fn getCurrentVm() ?*anyopaque        { return current_vm; }
pub fn restoreVm(prev: ?*anyopaque) void { current_vm = prev; }

// ── Boxing / Unboxing ─────────────────────────────────────────────────────────

fn box(v: V) !*KBox {
  const b = try c_alloc.create(KBox);
  b.* = .{ .rc = 1, .tag = tagOfV(v), .n = lenOfV(v), .v = v };
  return b;
}

fn unbox(b: *KBox, _: Alloc) V {
  const v = b.v;
  b.v = .blank;
  c_alloc.destroy(b);
  return v;
}

fn tagOfV(v: V) i8 { return @intCast(v.tag().serCode()); }

fn lenOfV(v: V) i32 {
  return switch (v.tag()) {
    .B, .I, .F, .S, .C, .L => @intCast(v.len()),
    else => -1,
  };
}

// ── k_* C API ────────────────────────────────────────────────────────────────

export fn ki(n: i32) ?*KBox { return box(.{ .i = n }) catch null; }
export fn kf(f: f32) ?*KBox { return box(.{ .f = f }) catch null; }
export fn kc(c: u8)  ?*KBox { return box(.{ .c = c }) catch null; }
export fn kb(b: c_int) ?*KBox { return box(.{ .b = b != 0 }) catch null; }
export fn kerr() ?*KBox { return box(.{ .err = .domain }) catch null; }

export fn ks(name: [*:0]const u8) ?*KBox {
  const vm_ptr = current_vm orelse return null;
  const VM = @import("runtime/vm.zig").VM;
  const vm: *VM = @ptrCast(@alignCast(vm_ptr));
  const id = vm.intern(std.mem.span(name)) catch return null;
  return box(.{ .s = id }) catch null;
}

export fn KC(n: i32) ?*KBox {
  if (n < 0) return null;
  const arr = N(u8).init(c_alloc, @intCast(n)) catch return null;
  return box(.{ .C = arr }) catch { arr.deinit(c_alloc); return null; };
}
export fn KI(n: i32) ?*KBox {
  if (n < 0) return null;
  const arr = N(i32).init(c_alloc, @intCast(n)) catch return null;
  @memset(arr.slice(), 0);
  return box(.{ .I = arr }) catch { arr.deinit(c_alloc); return null; };
}
export fn KF(n: i32) ?*KBox {
  if (n < 0) return null;
  const arr = N(f32).init(c_alloc, @intCast(n)) catch return null;
  @memset(arr.slice(), 0);
  return box(.{ .F = arr }) catch { arr.deinit(c_alloc); return null; };
}
export fn KL(n: i32) ?*KBox {
  if (n < 0) return null;
  const arr = N(V).init(c_alloc, @intCast(n)) catch return null;
  @memset(arr.slice(), .blank);
  return box(.{ .L = arr }) catch { arr.deinit(c_alloc); return null; };
}

export fn kt(x: ?*KBox) i8  { return if (x) |b| b.tag else -1; }
export fn kn(x: ?*KBox) i32 { return if (x) |b| b.n  else -1; }

export fn ki_val(x: ?*KBox) i32 {
  const b = x orelse return 0;
  return switch (b.v.tag()) {
    .i => b.v.i, .f => @intFromFloat(b.v.f),
    .b => if (b.v.b) 1 else 0, .c => b.v.c, else => 0,
  };
}
export fn kf_val(x: ?*KBox) f32 {
  const b = x orelse return 0;
  return switch (b.v.tag()) {
    .f => b.v.f, .i => @floatFromInt(b.v.i),
    .b => if (b.v.b) 1.0 else 0.0, else => 0,
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
export fn klp(x: ?*KBox) ?[*]?*KBox {
  _ = x;
  return null; // list element access through KBox* not supported; use k_list_get
}

// Get list element at index as a fresh ref'd box (caller must ku() it).
// Returns null on error / out of range.
export fn k_list_get(list_k: ?*KBox, index: i32) ?*KBox {
  const lb = list_k orelse return null;
  if (lb.v.tag() != .L) return null;
  const sl = lb.v.L.slice();
  if (index < 0 or index >= @as(i32, @intCast(sl.len))) return null;
  return box(sl[@intCast(index)].ref()) catch null;
}

// Set list element at index to val (val is consumed — caller must not ku() it).
// Returns 0 on success, -1 on error.
export fn k_list_set(list_k: ?*KBox, index: i32, val_k: ?*KBox) callconv(.c) i32 {
  const lb = list_k orelse return -1;
  if (lb.v.tag() != .L) return -1;
  const sl = lb.v.L.slice();
  if (index < 0 or index >= @as(i32, @intCast(sl.len))) return -1;
  sl[@intCast(index)].deinit(c_alloc);
  sl[@intCast(index)] = if (val_k) |vb| vb.v else .blank;
  if (val_k) |vb| { vb.v = .blank; c_alloc.destroy(vb); }
  return 0;
}
export fn ku(x: ?*KBox) void {
  const b = x orelse return;
  b.rc -= 1;
  if (b.rc == 0) { b.v.deinit(c_alloc); c_alloc.destroy(b); }
}

// ── k_call / k_call2 — call a K function from C ───────────────────────────────
//
// current_vm must be set (it is, for any C function called via FFI).

export fn k_call(func_k: ?*KBox, arg_k: ?*KBox) callconv(.c) ?*KBox {
  const vm_ptr = current_vm orelse return null;
  const VM = @import("runtime/vm.zig").VM;
  const vm: *VM = @ptrCast(@alignCast(vm_ptr));
  const Call = @import("runtime/call.zig").Call;

  const fb = func_k orelse return null;
  const ab = arg_k  orelse return null;
  const func_v = fb.v.ref();
  const arg_v  = ab.v.ref();

  var c = Call{ .vm = vm };
  const result = c.apply(func_v, &.{arg_v}, false);
  func_v.deinit(vm.alloc);
  arg_v.deinit(vm.alloc);
  return box(result) catch null;
}

export fn k_call2(func_k: ?*KBox, x_k: ?*KBox, y_k: ?*KBox) callconv(.c) ?*KBox {
  const vm_ptr = current_vm orelse return null;
  const VM = @import("runtime/vm.zig").VM;
  const vm: *VM = @ptrCast(@alignCast(vm_ptr));
  const Call = @import("runtime/call.zig").Call;

  const fb = func_k orelse return null;
  const xb = x_k orelse return null;
  const yb = y_k orelse return null;
  const func_v = fb.v.ref();
  const x_v    = xb.v.ref();
  const y_v    = yb.v.ref();

  var c = Call{ .vm = vm };
  const result = c.apply(func_v, &.{x_v, y_v}, false);
  func_v.deinit(vm.alloc);
  x_v.deinit(vm.alloc);
  y_v.deinit(vm.alloc);
  return box(result) catch null;
}

// ── k_make_dict — build a symbol-keyed dict ───────────────────────────────────
//
// n: number of entries
// keys: null-terminated strings (will be interned as symbols)
// vals: K value handles (borrowed; values are ref-counted before storing)

export fn k_make_dict(n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?*KBox) callconv(.c) ?*KBox {
  const vm_ptr = current_vm orelse return null;
  const VM = @import("runtime/vm.zig").VM;
  const vm: *VM = @ptrCast(@alignCast(vm_ptr));

  if (n <= 0) return null;
  const count: usize = @intCast(n);

  const sym_arr = N(u32).init(c_alloc, count) catch return null;
  for (0..count) |i| {
    sym_arr.slice()[i] = vm.intern(std.mem.span(keys[i])) catch {
      sym_arr.deinit(c_alloc);
      return null;
    };
  }

  const val_arr = N(V).init(c_alloc, count) catch {
    sym_arr.deinit(c_alloc);
    return null;
  };
  for (0..count) |i| {
    val_arr.slice()[i] = if (vals[i]) |b| b.v.ref() else .blank;
  }

  const keys_v = V{ .S = sym_arr };
  const vals_v = V{ .L = val_arr };
  const d = Dict.init(c_alloc, keys_v, vals_v) catch {
    keys_v.deinit(c_alloc);
    vals_v.deinit(c_alloc);
    return null;
  };
  return box(V{ .m = d }) catch { d.deinit(c_alloc); return null; };
}

// ── FFI function wrapper ──────────────────────────────────────────────────────

const FfiFn1 = *const fn (?*KBox) callconv(.c) ?*KBox;
const FfiFn2 = *const fn (?*KBox, ?*KBox) callconv(.c) ?*KBox;

const FfiData = struct {
  lib:    std.DynLib,
  fn_ptr: *anyopaque,
  arity:  u8,
  vm:     *anyopaque,  // VM pointer so k_call works from inside the C function
};

fn ffiDeinit(data: *anyopaque) void {
  const d: *FfiData = @ptrCast(@alignCast(data));
  d.lib.close();
  c_alloc.destroy(d);
}

// Clone flat-array Vs returned by C extensions (allocated with c_alloc) into
// the VM allocator so the VM can deinit them with the correct allocator.
// Scalars and non-array values pass through unchanged.
fn reallocV(v: V, dest: Alloc) V {
  switch (v) {
    inline .B, .I, .F, .S, .C => |n, tag| {
      const cloned = n.clone(dest) catch return .{ .err = .memory };
      n.deinit(c_alloc);
      return @unionInit(V, @tagName(tag), cloned);
    },
    // Deep-realloc a list: move the N(V) shell and recursively each element.
    .L => |n| {
      const len = n.ptr.len;
      const new_n = N(V).init(dest, len) catch return .{ .err = .memory };
      for (new_n.slice()) |*s| s.* = .blank;  // safe baseline for errdefer path
      for (n.slice(), 0..) |elem, i| {
        const copy = elem;
        n.slice()[i] = .blank;    // prevent n.deinit from double-freeing
        new_n.slice()[i] = reallocV(copy, dest);
      }
      n.deinit(c_alloc);          // all slots blanked; frees only the Rc shell
      return .{ .L = new_n };
    },
    // Deep-realloc a dict (both .m and .M share the same Dict payload).
    inline .m, .M => |d, tag| {
      const keys_v = d.av();
      const vals_v = d.bv();
      d.avPtr().* = .blank;       // prevent d.deinit from double-freeing
      d.bvPtr().* = .blank;
      d.deinit(c_alloc);          // frees only the Rc shell
      const new_keys = reallocV(keys_v, dest);
      const new_vals = reallocV(vals_v, dest);
      const new_dict = Dict.init(dest, new_keys, new_vals) catch {
        new_keys.deinit(dest);
        new_vals.deinit(dest);
        return .{ .err = .memory };
      };
      return @unionInit(V, @tagName(tag), new_dict);
    },
    else => return v,
  }
}

fn ffiCall1(data: *anyopaque, x: V) V {
  const d: *FfiData = @ptrCast(@alignCast(data));
  const VM = @import("runtime/vm.zig").VM;
  const vm: *VM = @ptrCast(@alignCast(d.vm));
  const prev_vm = current_vm;
  setCurrentVm(d.vm);
  defer current_vm = prev_vm;
  const f: FfiFn1 = @ptrCast(@alignCast(d.fn_ptr));
  // No x.ref(): args are borrowed; the .blank defer skips rc decrement so ref() would leak.
  const bx = box(x) catch return .{ .err = .memory };
  defer { bx.v = .blank; c_alloc.destroy(bx); }
  const result = f(bx) orelse return .{ .err = .domain };
  return reallocV(unbox(result, c_alloc), vm.alloc);
}

fn ffiCall2(data: *anyopaque, x: V, y: V) V {
  const d: *FfiData = @ptrCast(@alignCast(data));
  const VM = @import("runtime/vm.zig").VM;
  const vm: *VM = @ptrCast(@alignCast(d.vm));
  const prev_vm = current_vm;
  setCurrentVm(d.vm);
  defer current_vm = prev_vm;
  const f: FfiFn2 = @ptrCast(@alignCast(d.fn_ptr));
  const bx = box(x) catch return .{ .err = .memory };
  defer { bx.v = .blank; c_alloc.destroy(bx); }
  const by = box(y) catch return .{ .err = .memory };
  defer { by.v = .blank; c_alloc.destroy(by); }
  const result = f(bx, by) orelse return .{ .err = .domain };
  return reallocV(unbox(result, c_alloc), vm.alloc);
}

const ffi_vtable_1 = ExtVTable{ .name = "ffi1", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1 };
const ffi_vtable_2 = ExtVTable{ .name = "ffi2", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1, .call2_fn = ffiCall2 };

// ── 2: FFI load ───────────────────────────────────────────────────────────────

pub fn ffiLoad(vm: *anyopaque, lib_path: []const u8, sym_name: []const u8, arity: u8) V {
  const VM = @import("runtime/vm.zig").VM;
  const the_vm: *VM = @ptrCast(@alignCast(vm));

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

  // Pass the full k_* function-pointer table to the extension's terse_init so
  // it can resolve host symbols without relying on dlsym(RTLD_DEFAULT, ...).
  const TerseInit = *const fn (*anyopaque) callconv(.c) void;
  if (lib.lookup(TerseInit, "terse_init")) |init_fn| {
    init_fn(@constCast(@ptrCast(&k_registry)));
  }

  const data = c_alloc.create(FfiData) catch { lib.close(); return .{ .err = .memory }; };
  data.* = .{ .lib = lib, .fn_ptr = fn_ptr, .arity = arity, .vm = vm };

  const obj = the_vm.alloc.create(ExtObj) catch { ffiDeinit(data); return .{ .err = .memory }; };
  const vtable = if (arity >= 2) &ffi_vtable_2 else &ffi_vtable_1;
  obj.* = .{ .rc = 1, .type_id = 0, .vtable = vtable, .data = data };
  return .{ .x = obj };
}
