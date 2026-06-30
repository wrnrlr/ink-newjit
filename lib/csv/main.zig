/// CSV extension for ink — loaded via lib/csv/csv.k.
///
/// K API (after loading):
///   ReadCsv "path/to/file.csv"  → table whose columns are named by the header
///
/// Column type inference (per column):
///   all cells parse as i32  → I
///   all cells parse as f32  → F
///   otherwise               → L of C (list of char vectors)
///
/// Header detection: if every cell in the first row is non-numeric, it is
/// treated as a header row.  Otherwise column names are generated: c0, c1, …
///
/// Note: simple comma splitting only — no RFC-4180 quoted-field support.

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
    k_list_get:   *const fn (?K, i32)                                   callconv(.c) ?K,
    k_make_table: *const fn (i32, [*]const [*:0]const u8, [*]const ?K)  callconv(.c) ?K,
};

const KApi = struct {
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
    k_make_table: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
};
var g_api: ?KApi = null;

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
fn mktable(n: i32, ks: [*]const [*:0]const u8, vs: [*]const ?K) ?K {
    return g_api.?.k_make_table(n, ks, vs);
}

const Alloc = std.mem.Allocator;
const OOM = error{OutOfMemory};

export fn ReadCsv(path_k: ?K) callconv(.c) ?K {
    const alloc = std.heap.c_allocator;
    const p = kcp(path_k) orelse return null;
    const n = kn(path_k);
    if (n <= 0) return null;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = std.Io.Dir.cwd().readFileAlloc(io, p[0..@intCast(n)], alloc, std.Io.Limit.limited(256 << 20)) catch return null;
    defer alloc.free(text);
    return parseCsv(alloc, text) catch null;
}

fn parseCsv(alloc: Alloc, text: []const u8) OOM!K {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var lines = std.mem.splitScalar(u8, text, '\n');

    // Read first line to determine column count and header presence.
    const first_raw = lines.next() orelse return error.OutOfMemory;
    const first_line = std.mem.trimEnd(u8, first_raw, "\r");
    if (first_line.len == 0) return error.OutOfMemory;

    var ncols: usize = 0;
    {
        var it = std.mem.splitScalar(u8, first_line, ',');
        while (it.next()) |_| ncols += 1;
    }
    if (ncols == 0) return error.OutOfMemory;

    // Detect header: first row is a header only if NO cell is numeric.
    var has_header = true;
    {
        var it = std.mem.splitScalar(u8, first_line, ',');
        while (it.next()) |field| {
            const cell = std.mem.trim(u8, field, " \"\t\r");
            if (std.fmt.parseInt(i32, cell, 10)) |_| { has_header = false; break; } else |_| {}
            if (std.fmt.parseFloat(f32, cell))   |_| { has_header = false; break; } else |_| {}
        }
    }

    // Build null-terminated column header strings.
    const col_names = try aa.alloc([*:0]const u8, ncols);
    if (has_header) {
        var it = std.mem.splitScalar(u8, first_line, ',');
        for (0..ncols) |i| {
            const field = it.next() orelse "";
            const name = std.mem.trim(u8, field, " \"\t\r");
            col_names[i] = (try aa.dupeZ(u8, name)).ptr;
        }
    } else {
        for (0..ncols) |i| {
            var buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "c{d}", .{i}) catch unreachable;
            col_names[i] = (try aa.dupeZ(u8, name)).ptr;
        }
    }

    // Collect all data rows as slices of trimmed cell strings.
    var rows: std.ArrayList([]const []const u8) = .empty;

    // If no header, the first line is also a data row.
    if (!has_header) {
        const row = try parseRow(aa, first_line, ncols);
        try rows.append(aa, row);
    }

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        const row = try parseRow(aa, line, ncols);
        try rows.append(aa, row);
    }

    const nrows = rows.items.len;

    // Build typed column K values.
    const col_ks = try alloc.alloc(?K, ncols);
    defer alloc.free(col_ks);

    var n: usize = 0;
    errdefer for (col_ks[0..n]) |ck| ku(ck);

    for (0..ncols) |ci| {
        col_ks[ci] = try buildCsvCol(alloc, rows.items, ci, nrows);
        n += 1;
    }
    n = 0;  // disarm errdefer

    const result = mktable(@intCast(ncols), col_names.ptr, col_ks.ptr);
    for (col_ks[0..ncols]) |ck| ku(ck);  // release our refs
    return result orelse error.OutOfMemory;
}

// Split one CSV line into ncols trimmed cell strings (arena-allocated).
fn parseRow(aa: Alloc, line: []const u8, ncols: usize) OOM![]const []const u8 {
    const cells = try aa.alloc([]const u8, ncols);
    var it = std.mem.splitScalar(u8, line, ',');
    for (0..ncols) |i| {
        const field = it.next() orelse "";
        cells[i] = std.mem.trim(u8, field, " \"\t\r");
    }
    return cells;
}

// Build one K column array from row data at column index ci.
fn buildCsvCol(alloc: Alloc, rows: []const []const []const u8, ci: usize, nrows: usize) OOM!K {
    if (nrows == 0) return KL(0) orelse error.OutOfMemory;

    var all_int = true;
    var all_float = true;
    for (rows) |row| {
        const cell = if (ci < row.len) row[ci] else "";
        if (std.fmt.parseInt(i32, cell, 10)) |_| {} else |_| all_int = false;
        if (std.fmt.parseFloat(f32, cell))   |_| {} else |_| { all_int = false; all_float = false; }
    }

    if (all_int) {
        const out = KI(@intCast(nrows)) orelse return error.OutOfMemory;
        const p = kip(out).?;
        for (rows, 0..) |row, ri| {
            const cell = if (ci < row.len) row[ci] else "";
            p[ri] = std.fmt.parseInt(i32, cell, 10) catch 0;
        }
        return out;
    }
    if (all_float) {
        const out = KF(@intCast(nrows)) orelse return error.OutOfMemory;
        const p = kfp(out).?;
        for (rows, 0..) |row, ri| {
            const cell = if (ci < row.len) row[ci] else "";
            p[ri] = std.fmt.parseFloat(f32, cell) catch 0.0;
        }
        return out;
    }

    // String column: list of char vectors
    const col = KL(@intCast(nrows)) orelse return error.OutOfMemory;
    errdefer ku(col);
    for (rows, 0..) |row, ri| {
        const cell = if (ci < row.len) row[ci] else "";
        const str_k = KC(@intCast(cell.len)) orelse return error.OutOfMemory;
        if (cell.len > 0) @memcpy(kcp(str_k).?[0..cell.len], cell);
        // kls may fail if alloc ran out; str_k leaks in that case (acceptable)
        _ = kls(col, @intCast(ri), str_k);  // consumes str_k
        _ = alloc;  // suppress unused warning — alloc used indirectly via KC
    }
    return col;
}

fn inkInit(reg: *anyopaque) void {
    const r: *const KRegistry = @ptrCast(@alignCast(reg));
    g_api = .{
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
        .k_make_table = r.k_make_table,
    };
    // Register callable functions by name (loader-independent resolution).
    const kr: *const @import("kabi").KRegistry(K) = @ptrCast(@alignCast(reg));
    kr.k_register("ReadCsv", @ptrCast(&ReadCsv), 1);
}

export fn terse_init(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
export fn ink_ext_init_csv(reg: *anyopaque) callconv(.c) void { inkInit(reg); }
