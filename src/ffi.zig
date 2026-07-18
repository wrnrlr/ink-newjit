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
const builtin = @import("builtin");
const Alloc = std.mem.Allocator;
const V    = @import("noun/value.zig").V;
const N    = @import("noun/array.zig").N;
const K    = @import("noun/class.zig").K;
const Dict = @import("noun/dict.zig").Dict;
const plugin = @import("noun/plugin.zig");
const home = @import("home.zig");
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
// The layout lives in src/kabi.zig — the single source of truth shared by the
// host and every extension (instantiated here with our concrete *KBox handle).
// include/k.h is the matching mirror for C-language extensions.
pub const KRegistry = @import("kabi.zig").KRegistry(*KBox);

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
    .k_make_table = &k_make_table,
    .KS          = &KS,
    .ksp         = &ksp,
    .kintern     = &kintern,
    .k_register  = &k_register,
};

const c_alloc = std.heap.c_allocator;

// Pointer to the host k_* table, for statically-linked bundles to hand each
// extension's ink_ext_init_<name> at startup (the dlopen path passes this same
// pointer to terse_init).
pub fn registryPtr() *anyopaque { return @constCast(@ptrCast(&k_registry)); }

// ── Extension function registry (name → callable) ─────────────────────────────
// Populated by extensions at terse_init (dlopen) or by the bundle's static init
// table (static link).  `ffiLoad` resolves `2:(`Name;arity)` from here first, so
// the call path never depends on the dynamic loader — that's what lets the same
// ABI bind at runtime (dlopen), at bundle time (static link), or, later, at
// patch time (copy-and-patch).
const ExtFn = struct { ptr: *const anyopaque, arity: u8 };
var ext_fns: std.StringHashMapUnmanaged(ExtFn) = .empty;

// Libraries kept open for the process lifetime once dlopen'd, so the function
// pointers and name strings they registered stay valid.  Keyed by request path
// to avoid re-opening (and re-running terse_init) on each `2:` load.
var loaded_libs: std.StringHashMapUnmanaged(std.DynLib) = .empty;

export fn k_register(name: [*:0]const u8, fnptr: *const anyopaque, arity: u8) callconv(.c) void {
  const s = std.mem.span(name);
  const gop = ext_fns.getOrPut(c_alloc, s) catch return;
  if (!gop.found_existing) {
    gop.key_ptr.* = c_alloc.dupe(u8, s) catch {
      _ = ext_fns.remove(s);
      return;
    };
  }
  gop.value_ptr.* = .{ .ptr = fnptr, .arity = arity };
}

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
export fn KS(n: i32) ?*KBox {
  if (n < 0) return null;
  const arr = N(u32).init(c_alloc, @intCast(n)) catch return null;
  @memset(arr.slice(), 0);  // 0 = null/blank symbol
  return box(.{ .S = arr }) catch { arr.deinit(c_alloc); return null; };
}
export fn ksp(x: ?*KBox) ?[*]u32 {
  const b = x orelse return null;
  return if (b.v.tag() == .S) b.v.S.slice().ptr else null;
}
export fn kintern(name: [*:0]const u8) u32 {
  const vm_ptr = current_vm orelse return 0;
  const VM = @import("runtime/vm.zig").VM;
  const vm: *VM = @ptrCast(@alignCast(vm_ptr));
  return vm.intern(std.mem.span(name)) catch 0;
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

// ── k_make_dict / k_make_table — build a symbol-keyed dict or table ───────────
//
// n: number of entries
// keys: null-terminated strings (will be interned as symbols)
// vals: K value handles (borrowed; values are ref-counted before storing)
//
// k_make_table tags the result as a table (.M) rather than a plain dict (.m).
// The two share an identical keys/columns payload — the caller is responsible
// for passing equal-length column arrays (vectors or lists).

fn makeMap(comptime tag: K, n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?*KBox) ?*KBox {
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
  return box(@unionInit(V, @tagName(tag), d)) catch { d.deinit(c_alloc); return null; };
}

export fn k_make_dict(n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?*KBox) callconv(.c) ?*KBox {
  return makeMap(.m, n, keys, vals);
}

export fn k_make_table(n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?*KBox) callconv(.c) ?*KBox {
  return makeMap(.M, n, keys, vals);
}

// ── FFI function wrapper ──────────────────────────────────────────────────────

const FfiFn1 = *const fn (?*KBox) callconv(.c) ?*KBox;
const FfiFn2 = *const fn (?*KBox, ?*KBox) callconv(.c) ?*KBox;
const FfiFn3 = *const fn (?*KBox, ?*KBox, ?*KBox) callconv(.c) ?*KBox;
const FfiFn4 = *const fn (?*KBox, ?*KBox, ?*KBox, ?*KBox) callconv(.c) ?*KBox;
const FfiFn5 = *const fn (?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox) callconv(.c) ?*KBox;
const FfiFn6 = *const fn (?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox) callconv(.c) ?*KBox;
const FfiFn7 = *const fn (?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox) callconv(.c) ?*KBox;
const FfiFn8 = *const fn (?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox, ?*KBox) callconv(.c) ?*KBox;

pub const MAX_FFI_ARITY = 8;

const FfiData = struct {
  fn_ptr: *const anyopaque,
  arity:  u8,
  vm:     *anyopaque,  // VM pointer so k_call works from inside the C function
};

fn ffiDeinit(data: *anyopaque) void {
  // The owning library lives in `loaded_libs` for the process lifetime, so
  // there is nothing to close here.
  const d: *FfiData = @ptrCast(@alignCast(data));
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

// Box each borrowed arg (no ref(): the .blank defer skips the rc decrement so a
// ref() would leak), call the C function of matching arity, then clone the result
// out of c_alloc into the VM allocator. Shared by every arity (1..8).
fn ffiCallImpl(data: *anyopaque, args: []const V) V {
  const d: *FfiData = @ptrCast(@alignCast(data));
  const VM = @import("runtime/vm.zig").VM;
  const vm: *VM = @ptrCast(@alignCast(d.vm));
  const prev_vm = current_vm;
  setCurrentVm(d.vm);
  defer current_vm = prev_vm;
  var boxes: [MAX_FFI_ARITY]?*KBox = .{null} ** MAX_FFI_ARITY;
  defer for (&boxes) |*b| if (b.*) |bb| { bb.v = .blank; c_alloc.destroy(bb); };
  for (args, 0..) |a, i| boxes[i] = box(a) catch return .{ .err = .memory };
  const p = d.fn_ptr;
  const b = &boxes;
  const result = switch (args.len) {
    1 => @as(FfiFn1, @ptrCast(@alignCast(p)))(b[0]),
    2 => @as(FfiFn2, @ptrCast(@alignCast(p)))(b[0], b[1]),
    3 => @as(FfiFn3, @ptrCast(@alignCast(p)))(b[0], b[1], b[2]),
    4 => @as(FfiFn4, @ptrCast(@alignCast(p)))(b[0], b[1], b[2], b[3]),
    5 => @as(FfiFn5, @ptrCast(@alignCast(p)))(b[0], b[1], b[2], b[3], b[4]),
    6 => @as(FfiFn6, @ptrCast(@alignCast(p)))(b[0], b[1], b[2], b[3], b[4], b[5]),
    7 => @as(FfiFn7, @ptrCast(@alignCast(p)))(b[0], b[1], b[2], b[3], b[4], b[5], b[6]),
    8 => @as(FfiFn8, @ptrCast(@alignCast(p)))(b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]),
    else => return .{ .err = .rank },
  } orelse return .{ .err = .domain };
  return reallocV(unbox(result, c_alloc), vm.alloc);
}

fn ffiCall1(d: *anyopaque, a: V) V { return ffiCallImpl(d, &.{a}); }
fn ffiCall2(d: *anyopaque, a: V, b: V) V { return ffiCallImpl(d, &.{ a, b }); }
fn ffiCall3(d: *anyopaque, a: V, b: V, c: V) V { return ffiCallImpl(d, &.{ a, b, c }); }
fn ffiCall4(d: *anyopaque, a: V, b: V, c: V, e: V) V { return ffiCallImpl(d, &.{ a, b, c, e }); }
fn ffiCall5(d: *anyopaque, a: V, b: V, c: V, e: V, f: V) V { return ffiCallImpl(d, &.{ a, b, c, e, f }); }
fn ffiCall6(d: *anyopaque, a: V, b: V, c: V, e: V, f: V, g: V) V { return ffiCallImpl(d, &.{ a, b, c, e, f, g }); }
fn ffiCall7(d: *anyopaque, a: V, b: V, c: V, e: V, f: V, g: V, h: V) V { return ffiCallImpl(d, &.{ a, b, c, e, f, g, h }); }
fn ffiCall8(d: *anyopaque, a: V, b: V, c: V, e: V, f: V, g: V, h: V, i: V) V { return ffiCallImpl(d, &.{ a, b, c, e, f, g, h, i }); }

// A vtable exposing calls 1..N (a call with fewer args than the function's arity
// still dispatches; the extension sees only what it was given).
const ffi_vtable_1 = ExtVTable{ .name = "ffi1", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1 };
const ffi_vtable_2 = ExtVTable{ .name = "ffi2", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1, .call2_fn = ffiCall2 };
const ffi_vtable_3 = ExtVTable{ .name = "ffi3", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1, .call2_fn = ffiCall2, .call3_fn = ffiCall3 };
const ffi_vtable_4 = ExtVTable{ .name = "ffi4", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1, .call2_fn = ffiCall2, .call3_fn = ffiCall3, .call4_fn = ffiCall4 };
const ffi_vtable_5 = ExtVTable{ .name = "ffi5", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1, .call2_fn = ffiCall2, .call3_fn = ffiCall3, .call4_fn = ffiCall4, .call5_fn = ffiCall5 };
const ffi_vtable_6 = ExtVTable{ .name = "ffi6", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1, .call2_fn = ffiCall2, .call3_fn = ffiCall3, .call4_fn = ffiCall4, .call5_fn = ffiCall5, .call6_fn = ffiCall6 };
const ffi_vtable_7 = ExtVTable{ .name = "ffi7", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1, .call2_fn = ffiCall2, .call3_fn = ffiCall3, .call4_fn = ffiCall4, .call5_fn = ffiCall5, .call6_fn = ffiCall6, .call7_fn = ffiCall7 };
const ffi_vtable_8 = ExtVTable{ .name = "ffi8", .deinit_fn = ffiDeinit, .call1_fn = ffiCall1, .call2_fn = ffiCall2, .call3_fn = ffiCall3, .call4_fn = ffiCall4, .call5_fn = ffiCall5, .call6_fn = ffiCall6, .call7_fn = ffiCall7, .call8_fn = ffiCall8 };
const ffi_vtables = [8]*const ExtVTable{ &ffi_vtable_1, &ffi_vtable_2, &ffi_vtable_3, &ffi_vtable_4, &ffi_vtable_5, &ffi_vtable_6, &ffi_vtable_7, &ffi_vtable_8 };

// ── 2: FFI load ───────────────────────────────────────────────────────────────

// The library stem of a path: `./zig-out/lib/libgpu.dylib` → `libgpu`.
fn libStem(path: []const u8) []const u8 {
  const start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
  const name = path[start..];
  const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
  return name[0..dot];
}

// Fallback when a dylib path (which the .k files give relative to the source
// tree) doesn't exist: an installed ink resolves the library from its home dir,
// trying `$INK_HOME/share/<platform>/<stem>.<ext>` then `$INK_HOME/lib/<stem>.<ext>`
// with the host's native extension.
fn openHome(lib_path: []const u8) ?std.DynLib {
  var hbuf: [512]u8 = undefined;
  const hdir = home.dir(&hbuf) orelse return null;
  const stem = libStem(lib_path);
  for ([_][]const u8{ "share/" ++ home.platform, "lib" }) |sub| {
    var cbuf: [1024]u8 = undefined;
    const full = std.fmt.bufPrintZ(&cbuf, "{s}/{s}/{s}.{s}", .{ hdir, sub, stem, home.lib_ext }) catch continue;
    if (std.DynLib.open(full)) |l| return l else |_| {}
  }
  return null;
}

pub fn ffiLoad(vm: *anyopaque, lib_path: []const u8, sym_name: []const u8, arity: u8) V {
  const VM = @import("runtime/vm.zig").VM;
  const the_vm: *VM = @ptrCast(@alignCast(vm));

  // Name-first resolution works on every platform with no dynamic loader: a
  // statically-linked extension (in a bundle) registered its functions at
  // startup, and a dlopen'd one registered them on first load.  This is what
  // makes FFI work in static Windows bundles too.
  if (ext_fns.get(sym_name)) |e| return wrapFn(the_vm.alloc, vm, e.ptr, arity);

  // Otherwise the providing library must be dlopen'd — and Zig 0.16's
  // std.DynLib has no Windows backend, so that path is a comptime-dead branch
  // there (a Windows host can only use statically-linked extensions).
  if (builtin.os.tag != .windows) return ffiLoadDlopen(the_vm.alloc, vm, lib_path, sym_name, arity);
  return .{ .err = .nyi };
}

fn ffiLoadDlopen(vm_alloc: Alloc, vm: *anyopaque, lib_path: []const u8, sym_name: []const u8, arity: u8) V {
  // dlopen the lib; its terse_init registers its functions by name via
  // k_register, which the second lookup then resolves.
  ensureLoaded(lib_path);
  if (ext_fns.get(sym_name)) |e| return wrapFn(vm_alloc, vm, e.ptr, arity);
  return .{ .err = .domain };
}

// dlopen `lib_path` once (deduped by request path), run its terse_init so it can
// register its functions, and keep the handle open for the process lifetime.
fn ensureLoaded(lib_path: []const u8) void {
  if (loaded_libs.contains(lib_path)) return;

  var path_buf: [512]u8 = undefined;
  if (lib_path.len >= path_buf.len) return;
  @memcpy(path_buf[0..lib_path.len], lib_path);
  path_buf[lib_path.len] = 0;

  var lib = std.DynLib.open(path_buf[0..lib_path.len :0]) catch
    openHome(lib_path) orelse return;

  // Hand the extension the full host k_* table (and k_register) so it can both
  // call back into the host and register its own functions by name.
  const TerseInit = *const fn (*anyopaque) callconv(.c) void;
  if (lib.lookup(TerseInit, "terse_init")) |init_fn| {
    init_fn(@constCast(@ptrCast(&k_registry)));
  }

  const key = c_alloc.dupe(u8, lib_path) catch { lib.close(); return; };
  loaded_libs.put(c_alloc, key, lib) catch { c_alloc.free(key); lib.close(); };
}

// Wrap a resolved extension function pointer in a callable ExtObj.
fn wrapFn(vm_alloc: Alloc, vm: *anyopaque, fn_ptr: *const anyopaque, arity: u8) V {
  const data = c_alloc.create(FfiData) catch return .{ .err = .memory };
  data.* = .{ .fn_ptr = fn_ptr, .arity = arity, .vm = vm };
  const obj = vm_alloc.create(ExtObj) catch { c_alloc.destroy(data); return .{ .err = .memory }; };
  const n = @min(@max(arity, 1), MAX_FFI_ARITY);
  const vtable = ffi_vtables[n - 1];
  obj.* = .{ .rc = 1, .type_id = 0, .vtable = vtable, .data = data };
  return .{ .x = obj };
}
