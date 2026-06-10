/// JSON extension for ink — loaded via lib/json/json.k.
///
/// K API (after loading):
///   ReadJson "path/to/file.json"  → K value matching JSON structure
///
/// JSON mapping:
///   null                     → 0i
///   bool                     → 0b / 1b
///   integer                  → i (i32, clamped)
///   float                    → f (f32)
///   string                   → C (char vector)
///   array of ints            → I
///   array of nums            → F
///   array of same-key dicts  → dict of column arrays (table)
///   array (other)            → L (mixed list)
///   object                   → dict

const std = @import("std");
const K = *anyopaque;

const KRegistry = extern struct {
    ki:          *const fn (i32)                                        callconv(.c) ?K,
    kf:          *const fn (f32)                                        callconv(.c) ?K,
    kc:          *const fn (u8)                                         callconv(.c) ?K,
    kb:          *const fn (c_int)                                      callconv(.c) ?K,
    ks:          *const fn ([*:0]const u8)                              callconv(.c) ?K,
    kerr:        *const fn ()                                           callconv(.c) ?K,
    KC:          *const fn (i32)                                        callconv(.c) ?K,
    KI:          *const fn (i32)                                        callconv(.c) ?K,
    KF:          *const fn (i32)                                        callconv(.c) ?K,
    KL:          *const fn (i32)                                        callconv(.c) ?K,
    kt:          *const fn (?K)                                         callconv(.c) i8,
    kn:          *const fn (?K)                                         callconv(.c) i32,
    ki_val:      *const fn (?K)                                         callconv(.c) i32,
    kf_val:      *const fn (?K)                                         callconv(.c) f32,
    kc_val:      *const fn (?K)                                         callconv(.c) u8,
    kb_val:      *const fn (?K)                                         callconv(.c) c_int,
    kip:         *const fn (?K)                                         callconv(.c) ?[*]i32,
    kfp:         *const fn (?K)                                         callconv(.c) ?[*]f32,
    kcp:         *const fn (?K)                                         callconv(.c) ?[*]u8,
    klp:         *const fn (?K)                                         callconv(.c) ?[*]?K,
    ku:          *const fn (?K)                                         callconv(.c) void,
    k_list_set:  *const fn (?K, i32, ?K)                               callconv(.c) i32,
    k_call:      *const fn (?K, ?K)                                     callconv(.c) ?K,
    k_call2:     *const fn (?K, ?K, ?K)                                 callconv(.c) ?K,
    k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K)  callconv(.c) ?K,
};

const KApi = struct {
    ki:          *const fn (i32)                                        callconv(.c) ?K,
    kf:          *const fn (f32)                                        callconv(.c) ?K,
    kb:          *const fn (c_int)                                      callconv(.c) ?K,
    KC:          *const fn (i32)                                        callconv(.c) ?K,
    KI:          *const fn (i32)                                        callconv(.c) ?K,
    KF:          *const fn (i32)                                        callconv(.c) ?K,
    KL:          *const fn (i32)                                        callconv(.c) ?K,
    kn:          *const fn (?K)                                         callconv(.c) i32,
    kcp:         *const fn (?K)                                         callconv(.c) ?[*]u8,
    kip:         *const fn (?K)                                         callconv(.c) ?[*]i32,
    kfp:         *const fn (?K)                                         callconv(.c) ?[*]f32,
    ku:          *const fn (?K)                                         callconv(.c) void,
    k_list_set:  *const fn (?K, i32, ?K)                               callconv(.c) i32,
    k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K)  callconv(.c) ?K,
};
var g_api: ?KApi = null;

fn ki(n: i32) ?K                                  { return g_api.?.ki(n); }
fn kf(v: f32) ?K                                  { return g_api.?.kf(v); }
fn kb(b: c_int) ?K                                { return g_api.?.kb(b); }
fn KC(n: i32) ?K                                  { return g_api.?.KC(n); }
fn KI(n: i32) ?K                                  { return g_api.?.KI(n); }
fn KF(n: i32) ?K                                  { return g_api.?.KF(n); }
fn KL(n: i32) ?K                                  { return g_api.?.KL(n); }
fn kn(x: ?K) i32                                  { return g_api.?.kn(x); }
fn kcp(x: ?K) ?[*]u8                              { return g_api.?.kcp(x); }
fn kip(x: ?K) ?[*]i32                             { return g_api.?.kip(x); }
fn kfp(x: ?K) ?[*]f32                             { return g_api.?.kfp(x); }
fn ku(x: ?K) void                                 { g_api.?.ku(x); }
fn kls(l: ?K, i: i32, v: ?K) i32                 { return g_api.?.k_list_set(l, i, v); }
fn mkdict(n: i32, ks: [*]const [*:0]const u8, vs: [*]const ?K) ?K {
    return g_api.?.k_make_dict(n, ks, vs);
}

const Alloc = std.mem.Allocator;
const OOM = error{OutOfMemory};

export fn ReadJson(path_k: ?K) callconv(.c) ?K {
    const alloc = std.heap.c_allocator;
    const p = kcp(path_k) orelse return null;
    const n = kn(path_k);
    if (n <= 0) return null;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = std.Io.Dir.cwd().readFileAlloc(io, p[0..@intCast(n)], alloc, std.Io.Limit.limited(256 << 20)) catch return null;
    defer alloc.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return null;
    defer parsed.deinit();
    return convertVal(alloc, parsed.value) catch null;
}

fn convertVal(alloc: Alloc, jv: std.json.Value) OOM!K {
    return switch (jv) {
        .null          => ki(0) orelse error.OutOfMemory,
        .bool          => |b| kb(if (b) 1 else 0) orelse error.OutOfMemory,
        .integer       => |i| ki(@intCast(std.math.clamp(i, -2147483648, 2147483647))) orelse error.OutOfMemory,
        .float         => |f| kf(@floatCast(f)) orelse error.OutOfMemory,
        .number_string => |s| try numStr(s),
        .string        => |s| try makeStr(s),
        .array         => |a| try convertArr(alloc, a.items),
        .object        => |o| try convertObj(alloc, &o),
    };
}

fn makeStr(s: []const u8) OOM!K {
    const out = KC(@intCast(s.len)) orelse return error.OutOfMemory;
    if (s.len > 0) @memcpy(kcp(out).?[0..s.len], s);
    return out;
}

fn numStr(s: []const u8) OOM!K {
    if (std.fmt.parseInt(i32, s, 10)) |iv| return ki(iv) orelse error.OutOfMemory else |_| {}
    if (std.fmt.parseFloat(f32, s))   |fv| return kf(fv) orelse error.OutOfMemory else |_| {}
    return makeStr(s);
}

fn isJInt(jv: std.json.Value) bool {
    return switch (jv) {
        .integer       => true,
        .number_string => |s| if (std.fmt.parseInt(i32, s, 10)) |_| true else |_| false,
        else           => false,
    };
}
fn isJNum(jv: std.json.Value) bool {
    return switch (jv) {
        .integer, .float => true,
        .number_string   => |s| if (std.fmt.parseFloat(f32, s)) |_| true else |_| false,
        else             => false,
    };
}
fn toI32(jv: std.json.Value) i32 {
    return switch (jv) {
        .integer       => |v| @intCast(std.math.clamp(v, -2147483648, 2147483647)),
        .number_string => |s| std.fmt.parseInt(i32, s, 10) catch 0,
        else           => 0,
    };
}
fn toF32(jv: std.json.Value) f32 {
    return switch (jv) {
        .integer       => |v| @floatFromInt(v),
        .float         => |v| @floatCast(v),
        .number_string => |s| std.fmt.parseFloat(f32, s) catch 0.0,
        else           => 0.0,
    };
}

fn convertArr(alloc: Alloc, items: []const std.json.Value) OOM!K {
    if (items.len == 0) return KL(0) orelse error.OutOfMemory;

    var all_int = true;
    var all_num = true;
    for (items) |item| {
        if (!isJInt(item)) all_int = false;
        if (!isJNum(item)) { all_int = false; all_num = false; }
    }

    if (all_int) {
        const out = KI(@intCast(items.len)) orelse return error.OutOfMemory;
        const p = kip(out).?;
        for (items, 0..) |item, i| p[i] = toI32(item);
        return out;
    }
    if (all_num) {
        const out = KF(@intCast(items.len)) orelse return error.OutOfMemory;
        const p = kfp(out).?;
        for (items, 0..) |item, i| p[i] = toF32(item);
        return out;
    }

    // Array of same-key dicts → promote to column-oriented table
    const first_is_obj = switch (items[0]) { .object => true, else => false };
    if (first_is_obj) {
        if (try tryTable(alloc, items)) |t| return t;
    }

    // Generic mixed list
    const list = KL(@intCast(items.len)) orelse return error.OutOfMemory;
    errdefer ku(list);
    for (items, 0..) |item, i| {
        const v = try convertVal(alloc, item);
        _ = kls(list, @intCast(i), v);  // kls consumes v
    }
    return list;
}

// Try to build a column-oriented dict from a uniform array of objects.
// Returns null if the array can't be promoted (non-uniform keys/types).
fn tryTable(alloc: Alloc, items: []const std.json.Value) OOM!?K {
    const first = switch (items[0]) { .object => |o| o, else => return null };
    const ncols = first.count();
    if (ncols == 0) return null;

    // All objects must have the same keys in the same order.
    const ref_keys = first.keys();
    for (items[1..]) |item| {
        const obj = switch (item) { .object => |o| o, else => return null };
        if (obj.count() != ncols) return null;
        for (obj.keys(), 0..) |k, i| if (!std.mem.eql(u8, k, ref_keys[i])) return null;
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const key_ptrs = try aa.alloc([*:0]const u8, ncols);
    for (ref_keys, 0..) |k, i| key_ptrs[i] = (try aa.dupeZ(u8, k)).ptr;

    const col_ks = try alloc.alloc(?K, ncols);
    defer alloc.free(col_ks);

    var n: usize = 0;
    errdefer for (col_ks[0..n]) |ck| ku(ck);
    for (0..ncols) |ci| {
        col_ks[ci] = try buildCol(alloc, items, ci);
        n += 1;
    }
    n = 0;  // disarm errdefer — mkdict takes ownership via ref()

    const result = mkdict(@intCast(ncols), key_ptrs.ptr, col_ks.ptr);
    for (col_ks[0..ncols]) |ck| ku(ck);  // release our refs
    return result orelse error.OutOfMemory;
}

// Build one column (ci) from a verified-uniform array of object rows.
fn buildCol(alloc: Alloc, items: []const std.json.Value, ci: usize) OOM!K {
    var all_int = true;
    var all_num = true;
    for (items) |item| {
        const obj = switch (item) { .object => |o| o, else => return error.OutOfMemory };
        if (obj.values().len <= ci) return error.OutOfMemory;
        const v = obj.values()[ci];
        if (!isJInt(v)) all_int = false;
        if (!isJNum(v)) { all_int = false; all_num = false; }
    }

    if (all_int) {
        const out = KI(@intCast(items.len)) orelse return error.OutOfMemory;
        const p = kip(out).?;
        for (items, 0..) |item, ri| {
            const obj = switch (item) { .object => |o| o, else => return error.OutOfMemory };
            p[ri] = toI32(obj.values()[ci]);
        }
        return out;
    }
    if (all_num) {
        const out = KF(@intCast(items.len)) orelse return error.OutOfMemory;
        const p = kfp(out).?;
        for (items, 0..) |item, ri| {
            const obj = switch (item) { .object => |o| o, else => return error.OutOfMemory };
            p[ri] = toF32(obj.values()[ci]);
        }
        return out;
    }

    const col = KL(@intCast(items.len)) orelse return error.OutOfMemory;
    errdefer ku(col);
    for (items, 0..) |item, ri| {
        const obj = switch (item) { .object => |o| o, else => return error.OutOfMemory };
        const kv = try convertVal(alloc, obj.values()[ci]);
        _ = kls(col, @intCast(ri), kv);  // consumes kv
    }
    return col;
}

fn convertObj(alloc: Alloc, obj: *const std.json.ObjectMap) OOM!K {
    const count = obj.count();
    if (count == 0) return KL(0) orelse error.OutOfMemory;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const key_ptrs = try aa.alloc([*:0]const u8, count);
    for (obj.keys(), 0..) |k, i| key_ptrs[i] = (try aa.dupeZ(u8, k)).ptr;

    const vals = try alloc.alloc(?K, count);
    defer alloc.free(vals);

    var n: usize = 0;
    errdefer for (vals[0..n]) |v| ku(v);
    for (obj.values(), 0..) |v, i| {
        vals[i] = try convertVal(alloc, v);
        n += 1;
    }
    n = 0;  // disarm errdefer

    const result = mkdict(@intCast(count), key_ptrs.ptr, vals.ptr);
    for (vals[0..count]) |v| ku(v);  // release our refs
    return result orelse error.OutOfMemory;
}

export fn terse_init(reg: *anyopaque) callconv(.c) void {
    const r: *const KRegistry = @ptrCast(@alignCast(reg));
    g_api = .{
        .ki          = r.ki,
        .kf          = r.kf,
        .kb          = r.kb,
        .KC          = r.KC,
        .KI          = r.KI,
        .KF          = r.KF,
        .KL          = r.KL,
        .kn          = r.kn,
        .kcp         = r.kcp,
        .kip         = r.kip,
        .kfp         = r.kfp,
        .ku          = r.ku,
        .k_list_set  = r.k_list_set,
        .k_make_dict = r.k_make_dict,
    };
}
