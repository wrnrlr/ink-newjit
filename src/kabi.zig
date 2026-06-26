//! Canonical k-ABI: the ONE definition of the function-pointer table the host
//! passes to every extension's `terse_init`. The host (src/ffi.zig) and each
//! native extension import this instead of hand-maintaining a mirror struct, so
//! the field order and signatures can never drift apart.
//!
//! It is generic over the K handle type so the host can instantiate it with its
//! concrete `*KBox` while extensions use an opaque `*anyopaque` — both are a
//! single nullable pointer, so the `extern` layout (and the C ABI) is identical
//! either way; the only difference is how much each side knows about the pointee.
//!
//! ABI stability rule: APPEND new fields at the end only. Extensions built
//! against an older (shorter) layout read a prefix of the table and ignore the
//! trailing fields, so appending is safe but reordering/removing is not. This is
//! also why `klp` stays even though it is a null stub superseded by
//! `k_list_get` — dropping it would shift every following field's offset.

pub fn KRegistry(comptime KH: type) type {
  return extern struct {
    ki:          *const fn (i32)                         callconv(.c) ?KH,
    kf:          *const fn (f32)                         callconv(.c) ?KH,
    kc:          *const fn (u8)                          callconv(.c) ?KH,
    kb:          *const fn (c_int)                       callconv(.c) ?KH,
    ks:          *const fn ([*:0]const u8)               callconv(.c) ?KH,
    kerr:        *const fn ()                            callconv(.c) ?KH,
    KC:          *const fn (i32)                         callconv(.c) ?KH,
    KI:          *const fn (i32)                         callconv(.c) ?KH,
    KF:          *const fn (i32)                         callconv(.c) ?KH,
    KL:          *const fn (i32)                         callconv(.c) ?KH,
    kt:          *const fn (?KH)                         callconv(.c) i8,
    kn:          *const fn (?KH)                         callconv(.c) i32,
    ki_val:      *const fn (?KH)                         callconv(.c) i32,
    kf_val:      *const fn (?KH)                         callconv(.c) f32,
    kc_val:      *const fn (?KH)                         callconv(.c) u8,
    kb_val:      *const fn (?KH)                         callconv(.c) c_int,
    kip:         *const fn (?KH)                         callconv(.c) ?[*]i32,
    kfp:         *const fn (?KH)                         callconv(.c) ?[*]f32,
    kcp:         *const fn (?KH)                         callconv(.c) ?[*]u8,
    klp:         *const fn (?KH)                         callconv(.c) ?[*]?KH, // stub; use k_list_get
    ku:          *const fn (?KH)                         callconv(.c) void,
    k_list_set:  *const fn (?KH, i32, ?KH)               callconv(.c) i32,
    k_call:      *const fn (?KH, ?KH)                    callconv(.c) ?KH,
    k_call2:     *const fn (?KH, ?KH, ?KH)               callconv(.c) ?KH,
    k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?KH) callconv(.c) ?KH,
    k_list_get:  *const fn (?KH, i32)                    callconv(.c) ?KH,
    k_make_table: *const fn (i32, [*]const [*:0]const u8, [*]const ?KH) callconv(.c) ?KH,
  };
}
