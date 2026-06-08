/// MD5 extension for ink — loaded via lib/md5/md5.k.
///
/// K API (after loading):
///   md5Hash "hello"   → C[32]  (lowercase hex digest, e.g. "5d41402abc4b2a76b9719d911017c592")
///
/// Host K API imported via dynamic linker: kcp, kn, KC, ku

const std = @import("std");

const K = *anyopaque;

const RTLD_DEFAULT = @as(?*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))));
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

const KApi = struct {
    kcp: *const fn (?K) callconv(.c) ?[*]u8,
    kn:  *const fn (?K) callconv(.c) i32,
    KC:  *const fn (i32) callconv(.c) ?K,
    ku:  *const fn (?K) callconv(.c) void,
};
var g_api: ?KApi = null;

fn lookupFn(comptime T: type, name: [*:0]const u8) ?T {
    const ptr = dlsym(RTLD_DEFAULT, name) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

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
    _ = reg;
    g_api = .{
        .kcp = lookupFn(*const fn (?K) callconv(.c) ?[*]u8, "kcp") orelse return,
        .kn  = lookupFn(*const fn (?K) callconv(.c) i32,    "kn")  orelse return,
        .KC  = lookupFn(*const fn (i32) callconv(.c) ?K,    "KC")  orelse return,
        .ku  = lookupFn(*const fn (?K) callconv(.c) void,   "ku")  orelse return,
    };
}
