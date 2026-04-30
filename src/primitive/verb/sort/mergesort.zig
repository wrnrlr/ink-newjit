const std = @import("std");
const Alloc = std.mem.Allocator;

/// Stable top-down merge sort for index arrays.
/// cmp(ctx, lhs, rhs) returns true if lhs should come before rhs
/// (for stability: also returns true when lhs == rhs in value).
pub fn sort(
    alloc: Alloc,
    arr: []usize,
    context: anytype,
    comptime cmp: fn (@TypeOf(context), usize, usize) bool,
) !void {
    if (arr.len <= 1) return;
    try sortRange(alloc, arr, 0, arr.len - 1, context, cmp);
}

fn sortRange(
    alloc: Alloc,
    arr: []usize,
    left: usize,
    right: usize,
    context: anytype,
    comptime cmp: fn (@TypeOf(context), usize, usize) bool,
) !void {
    if (left >= right) return;
    const mid = left + (right - left) / 2;
    try sortRange(alloc, arr, left, mid, context, cmp);
    try sortRange(alloc, arr, mid + 1, right, context, cmp);
    try merge(alloc, arr, left, mid, right, context, cmp);
}

fn merge(
    alloc: Alloc,
    arr: []usize,
    left: usize,
    mid: usize,
    right: usize,
    context: anytype,
    comptime cmp: fn (@TypeOf(context), usize, usize) bool,
) !void {
    const n1 = mid - left + 1;
    const n2 = right - mid;
    const L = try alloc.alloc(usize, n1);
    const R = try alloc.alloc(usize, n2);
    defer {
        alloc.free(L);
        alloc.free(R);
    }
    @memcpy(L, arr[left .. left + n1]);
    @memcpy(R, arr[mid + 1 .. mid + 1 + n2]);

    var i: usize = 0;
    var j: usize = 0;
    var k = left;
    while (i < n1 and j < n2) : (k += 1) {
        if (cmp(context, L[i], R[j])) {
            arr[k] = L[i];
            i += 1;
        } else {
            arr[k] = R[j];
            j += 1;
        }
    }
    while (i < n1) : ({ k += 1; i += 1; }) arr[k] = L[i];
    while (j < n2) : ({ k += 1; j += 1; }) arr[k] = R[j];
}
