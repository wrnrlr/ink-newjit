const std = @import("std");
const Alloc = std.mem.Allocator;

const BITS: u5 = 8;
const RADIX: usize = 1 << BITS; // 256
const MASK: u32 = RADIX - 1;

/// LSD radix sort for index arrays backed by i32 data.
/// Stable: equal elements maintain their original relative order.
/// For descending: uses bitwise complement of the sort key so equal elements
/// still maintain ascending index order.
pub fn sortI64(alloc: Alloc, indices: []usize, data: []const i32, desc: bool) !void {
    try sortByKey(u32, alloc, indices, desc, struct {
        d: []const i32,
        fn key(self: @This(), idx: usize) u32 {
            // XOR sign bit: maps i32 ordering onto u32 ordering correctly
            return @as(u32, @bitCast(self.d[idx])) ^ (@as(u32, 1) << 31);
        }
    }{ .d = data });
}

/// LSD radix sort for index arrays backed by u32 data (symbol hash values).
pub fn sortU64(alloc: Alloc, indices: []usize, data: []const u32, desc: bool) !void {
    try sortByKey(u32, alloc, indices, desc, struct {
        d: []const u32,
        fn key(self: @This(), idx: usize) u32 {
            return self.d[idx];
        }
    }{ .d = data });
}

/// LSD radix sort for index arrays backed by u8 data (chars).
pub fn sortU8(alloc: Alloc, indices: []usize, data: []const u8, desc: bool) !void {
    try sortByKey(u8, alloc, indices, desc, struct {
        d: []const u8,
        fn key(self: @This(), idx: usize) u8 {
            return self.d[idx];
        }
    }{ .d = data });
}

/// Generic LSD radix sort over any unsigned integer key type.
/// KeyT must be u8, u16, u32, or u32.
/// desc=true: sorts keys descending using ~key trick (stable).
fn sortByKey(
    comptime KeyT: type,
    alloc: Alloc,
    indices: []usize,
    desc: bool,
    ctx: anytype,
) !void {
    const passes = @sizeOf(KeyT); // bytes = number of 8-bit passes
    const n = indices.len;
    if (n <= 1) return;

    const aux = try alloc.alloc(usize, n);
    defer alloc.free(aux);

    // We ping-pong between indices and aux.
    // src holds the input for each pass, dst holds the output.
    var src: []usize = indices;
    var dst: []usize = aux;

    for (0..passes) |pass| {
        const shift: u5 = @intCast(pass * BITS);

        var counts = [_]usize{0} ** RADIX;
        for (src) |idx| {
            const raw = ctx.key(idx);
            // For descending: complement all bits → same bucket ordering as ascending ~key
            const k: u32 = if (desc) ~@as(u32, raw) else @as(u32, raw);
            const bucket = (k >> shift) & MASK;
            counts[bucket] += 1;
        }

        // Build exclusive prefix-sum offsets
        var offsets = [_]usize{0} ** RADIX;
        var sum: usize = 0;
        for (0..RADIX) |b| {
            offsets[b] = sum;
            sum += counts[b];
        }

        // Scatter into dst in stable order (process src left-to-right)
        for (src) |idx| {
            const raw = ctx.key(idx);
            const k: u32 = if (desc) ~@as(u32, raw) else @as(u32, raw);
            const bucket = (k >> shift) & MASK;
            dst[offsets[bucket]] = idx;
            offsets[bucket] += 1;
        }

        std.mem.swap([]usize, &src, &dst);
    }

    // After `passes` swaps:
    //   passes=1 (u8):  src=aux → copy back
    //   passes=8 (u32): src=indices (even swaps) → already in place
    if (passes % 2 == 1) {
        // Result is in aux (now pointed to by src after the last swap)
        @memcpy(indices, src);
    }
    // else: result is already in indices
}

test "radixsort i32 ascending" {
    const alloc = std.testing.allocator;
    const data = [_]i32{ 3, 1, 4, 1, 5, 9, 2 };
    var indices = [_]usize{ 0, 1, 2, 3, 4, 5, 6 };
    try sortI64(alloc, &indices, &data, false);
    // Sorted ascending: 1,1,2,3,4,5,9 → original indices 1,3,6,0,2,4,5
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 6, 0, 2, 4, 5 }, &indices);
}

test "radixsort i32 descending" {
    const alloc = std.testing.allocator;
    const data = [_]i32{ 3, 1, 4, 2 };
    var indices = [_]usize{ 0, 1, 2, 3 };
    try sortI64(alloc, &indices, &data, true);
    // Sorted descending: 4,3,2,1 → indices 2,0,3,1
    try std.testing.expectEqualSlices(usize, &.{ 2, 0, 3, 1 }, &indices);
}

test "radixsort i32 negatives" {
    const alloc = std.testing.allocator;
    const data = [_]i32{ -1, -3, 0, 2 };
    var indices = [_]usize{ 0, 1, 2, 3 };
    try sortI64(alloc, &indices, &data, false);
    // Sorted: -3,-1,0,2 → indices 1,0,2,3
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2, 3 }, &indices);
}

test "radixsort u8 ascending" {
    const alloc = std.testing.allocator;
    const data = [_]u8{ 'c', 'a', 'b' };
    var indices = [_]usize{ 0, 1, 2 };
    try sortU8(alloc, &indices, &data, false);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &indices);
}
