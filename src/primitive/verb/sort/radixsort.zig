const std = @import("std");
const Alloc = std.mem.Allocator;
const keying = @import("../keying.zig");

const BITS: u5 = 8;
const RADIX: usize = 1 << BITS;
const MASK: u32 = RADIX - 1;

pub fn sortI32(alloc: Alloc, indices: []usize, data: []const i32, desc: bool) !void {
    if (keying.denseRange(i32, data)) |r| return countingSort(i32, alloc, indices, data, r, desc);
    try sortByKey(u32, alloc, indices, desc, struct {
        d: []const i32,
        fn key(self: @This(), idx: usize) u32 {
            return @as(u32, @bitCast(self.d[idx])) ^ (@as(u32, 1) << 31);
        }
    }{ .d = data });
}

pub fn sortU32(alloc: Alloc, indices: []usize, data: []const u32, desc: bool) !void {
    if (keying.denseRange(u32, data)) |r| return countingSort(u32, alloc, indices, data, r, desc);
    try sortByKey(u32, alloc, indices, desc, struct {
        d: []const u32,
        fn key(self: @This(), idx: usize) u32 { return self.d[idx]; }
    }{ .d = data });
}

// One counting pass instead of four radix passes, when the value range is small
// enough to address directly (see keying.denseRange). Stable in both directions:
// ascending walks the buckets up, descending walks them down, and each fill runs
// in source order.
fn countingSort(comptime T: type, alloc: Alloc, indices: []usize, data: []const T, r: keying.Dense, desc: bool) !void {
    const n = indices.len;
    if (n <= 1) return;
    const counts = try alloc.alloc(usize, r.span);
    defer alloc.free(counts);
    @memset(counts, 0);
    for (indices) |idx| counts[keying.bucketOf(data[idx], r.min)] += 1;

    var sum: usize = 0;
    if (desc) {
        var b = r.span;
        while (b > 0) { b -= 1; const c = counts[b]; counts[b] = sum; sum += c; }
    } else {
        for (counts) |*c| { const v = c.*; c.* = sum; sum += v; }
    }

    const aux = try alloc.alloc(usize, n);
    defer alloc.free(aux);
    for (indices) |idx| {
        const b = keying.bucketOf(data[idx], r.min);
        aux[counts[b]] = idx;
        counts[b] += 1;
    }
    @memcpy(indices, aux);
}

pub fn sortU8(alloc: Alloc, indices: []usize, data: []const u8, desc: bool) !void {
    try sortByKey(u8, alloc, indices, desc, struct {
        d: []const u8,
        fn key(self: @This(), idx: usize) u8 { return self.d[idx]; }
    }{ .d = data });
}

fn sortByKey(comptime KeyT: type, alloc: Alloc, indices: []usize, desc: bool, ctx: anytype) !void {
    const passes = @sizeOf(KeyT);
    const n = indices.len;
    if (n <= 1) return;

    const aux = try alloc.alloc(usize, n);
    defer alloc.free(aux);

    var src: []usize = indices;
    var dst: []usize = aux;

    for (0..passes) |pass| {
        const shift: u5 = @intCast(pass * BITS);
        var counts = [_]usize{0} ** RADIX;
        for (src) |idx| {
            const raw = ctx.key(idx);
            const k: u32 = if (desc) ~@as(u32, raw) else @as(u32, raw);
            counts[(k >> shift) & MASK] += 1;
        }
        var offsets = [_]usize{0} ** RADIX;
        var sum: usize = 0;
        for (0..RADIX) |b| { offsets[b] = sum; sum += counts[b]; }
        for (src) |idx| {
            const raw = ctx.key(idx);
            const k: u32 = if (desc) ~@as(u32, raw) else @as(u32, raw);
            const bucket = (k >> shift) & MASK;
            dst[offsets[bucket]] = idx;
            offsets[bucket] += 1;
        }
        std.mem.swap([]usize, &src, &dst);
    }
    if (passes % 2 == 1) @memcpy(indices, src);
}
