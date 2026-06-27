/// MD5 extension for ink — loaded via lib/md5/md5.k.
///
/// K API (after loading):
///   md5Hash "hello"   → C[32]  (lowercase hex digest, e.g. "5d41402abc4b2a76b9719d911017c592")
///
/// Host K API imported via dynamic linker: kcp, kn, KC, ku

const std = @import("std");

const K = *anyopaque;

// Mirror of KRegistry in ffi.zig / include/k.h — field order must match exactly.
const KRegistry = extern struct {
    ki:          *const fn (i32)                         callconv(.c) ?K,
    kf:          *const fn (f32)                         callconv(.c) ?K,
    kc:          *const fn (u8)                          callconv(.c) ?K,
    kb:          *const fn (c_int)                       callconv(.c) ?K,
    ks:          *const fn ([*:0]const u8)               callconv(.c) ?K,
    kerr:        *const fn ()                            callconv(.c) ?K,
    KC:          *const fn (i32)                         callconv(.c) ?K,
    KI:          *const fn (i32)                         callconv(.c) ?K,
    KF:          *const fn (i32)                         callconv(.c) ?K,
    KL:          *const fn (i32)                         callconv(.c) ?K,
    kt:          *const fn (?K)                          callconv(.c) i8,
    kn:          *const fn (?K)                          callconv(.c) i32,
    ki_val:      *const fn (?K)                          callconv(.c) i32,
    kf_val:      *const fn (?K)                          callconv(.c) f32,
    kc_val:      *const fn (?K)                          callconv(.c) u8,
    kb_val:      *const fn (?K)                          callconv(.c) c_int,
    kip:         *const fn (?K)                          callconv(.c) ?[*]i32,
    kfp:         *const fn (?K)                          callconv(.c) ?[*]f32,
    kcp:         *const fn (?K)                          callconv(.c) ?[*]u8,
    klp:         *const fn (?K)                          callconv(.c) ?[*]?K,
    ku:          *const fn (?K)                          callconv(.c) void,
    k_list_set:  *const fn (?K, i32, ?K)                callconv(.c) i32,
    k_call:      *const fn (?K, ?K)                     callconv(.c) ?K,
    k_call2:     *const fn (?K, ?K, ?K)                 callconv(.c) ?K,
    k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
};

const KApi = struct {
    kcp: *const fn (?K) callconv(.c) ?[*]u8,
    kn:  *const fn (?K) callconv(.c) i32,
    KC:  *const fn (i32) callconv(.c) ?K,
    ku:  *const fn (?K) callconv(.c) void,
};
var g_api: ?KApi = null;

fn kcp(x: ?K) ?[*]u8 { return g_api.?.kcp(x); }
fn kn(x: ?K) i32     { return g_api.?.kn(x); }
fn KC(n: i32) ?K     { return g_api.?.KC(n); }
fn ku(x: ?K) void    { g_api.?.ku(x); }

// md5Hash x   — x is a C (byte/char vector); returns C[32] hex digest or null on error.
export fn md5Hash(x: ?K) callconv(.c) ?K {
    const p = kcp(x) orelse return null;
    const n = kn(x);
    if (n < 0) return null;

    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(p[0..@intCast(n)], &digest, .{});

    const out = KC(32) orelse return null;
    const op = kcp(out) orelse { ku(out); return null; };

    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        op[i * 2 + 0] = hex[b >> 4];
        op[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}

export fn terse_init(reg: *anyopaque) callconv(.c) void {
    const r: *const KRegistry = @ptrCast(@alignCast(reg));
    g_api = .{
        .kcp = r.kcp,
        .kn  = r.kn,
        .KC  = r.KC,
        .ku  = r.ku,
    };
}
