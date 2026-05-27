const std = @import("std");
const Alloc = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const MIN_LOG2: u6 = 4;  // 16 bytes minimum block size
const MAX_LOG2: u6 = 10; // 1024 bytes maximum block size
pub const NCLASS = MAX_LOG2 - MIN_LOG2 + 1; // 7 classes

// Canonical alignment used for ALL blocks allocated from the backing allocator.
// Must satisfy the highest alignment we accept (8 bytes / log2=3).
const SLAB_ALIGN = Alignment.@"8";

// Round n up to the nearest power-of-2 slab size (min 16, max 1024).
// Values > 1024 or 0 are returned unchanged (they won't go through the slab).
pub fn round(n: usize) usize {
    if (n == 0 or n > (1 << MAX_LOG2)) return n;
    return @max(std.math.ceilPowerOfTwoAssert(usize, n), @as(usize, 1) << MIN_LOG2);
}

// A power-of-2 freelist slab that wraps any backing allocator.
//
// Intercepts allocations that are:
//   - power-of-2 in size (guaranteed by callers using round() first)
//   - 16..1024 bytes
//   - alignment 4 or 8 (alignment 1/2 strings and alignment > 8 bypass the slab)
//
// All slab blocks are backed with SLAB_ALIGN (8 bytes) regardless of the
// requested alignment, ensuring the backing allocator never sees alignment
// mismatches on free.
//
// Free-block layout (min 16 bytes, pointer written with @memcpy to avoid
// alignment faults on 4-byte aligned blocks):
//   bytes 0-7: next-pointer encoded as usize (0 = end of list)
pub const SlabAlloc = struct {
    backing: Alloc,
    lists: [NCLASS]?[*]u8 = .{null} ** NCLASS,

    pub fn init(backing: Alloc) SlabAlloc {
        return .{ .backing = backing };
    }

    pub fn allocator(s: *SlabAlloc) Alloc {
        return .{ .ptr = s, .vtable = &vtable };
    }

    pub fn deinit(s: *SlabAlloc) void {
        for (s.lists, 0..) |head, ci| {
            const sz: usize = @as(usize, 1) << @intCast(ci + MIN_LOG2);
            var cur = head;
            while (cur) |p| {
                var next_int: usize = 0;
                @memcpy(std.mem.asBytes(&next_int), p[0..8]);
                s.backing.rawFree(p[0..sz], SLAB_ALIGN, 0);
                cur = if (next_int == 0) null else @ptrFromInt(next_int);
            }
            s.lists[ci] = null;
        }
    }

    // Returns the freelist index for a (len, alignment) pair, or null if not slabbable.
    inline fn classOf(len: usize, alignment: Alignment) ?usize {
        const log2_align = @intFromEnum(alignment);
        // Accept only alignment 4 (log2=2) or 8 (log2=3)
        if (log2_align < 2 or log2_align > 3) return null;
        if (!std.math.isPowerOfTwo(len)) return null;
        const lg = @ctz(len);
        if (lg < MIN_LOG2 or lg > MAX_LOG2) return null;
        return lg - MIN_LOG2;
    }

    fn rawAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const s: *SlabAlloc = @ptrCast(@alignCast(ctx));
        if (classOf(len, alignment)) |ci| {
            if (s.lists[ci]) |p| {
                var next_int: usize = 0;
                @memcpy(std.mem.asBytes(&next_int), p[0..8]);
                s.lists[ci] = if (next_int == 0) null else @ptrFromInt(next_int);
                return p;
            }
            // Fresh block: always SLAB_ALIGN so deinit can free with consistent alignment.
            return s.backing.rawAlloc(len, SLAB_ALIGN, ret_addr);
        }
        return s.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn rawResize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool  { return false; }
    fn rawRemap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 { return null; }

    fn rawFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const s: *SlabAlloc = @ptrCast(@alignCast(ctx));
        if (classOf(memory.len, alignment)) |ci| {
            const next_int: usize = if (s.lists[ci]) |p| @intFromPtr(p) else 0;
            @memcpy(memory.ptr[0..8], std.mem.asBytes(&next_int));
            s.lists[ci] = memory.ptr;
            return;
        }
        s.backing.rawFree(memory, alignment, ret_addr);
    }

    const vtable = Alloc.VTable{
        .alloc  = rawAlloc,
        .resize = rawResize,
        .remap  = rawRemap,
        .free   = rawFree,
    };
};
