const std = @import("std");
const Alloc = std.mem.Allocator;

/// Minimum run length for TimSort. Arrays smaller than this use insertion sort directly.
const MIN_RUN: usize = 32;

/// Stable TimSort for index arrays (bottom-up merge sort with insertion sort runs).
/// cmp(ctx, lhs, rhs) returns true if lhs should come before rhs
/// (for stability: also returns true when lhs == rhs in value).
pub fn sort(
    alloc: Alloc,
    arr: []usize,
    context: anytype,
    comptime cmp: fn (@TypeOf(context), usize, usize) bool,
) !void {
    const n = arr.len;
    if (n <= 1) return;

    // Phase 1: sort each MIN_RUN-sized chunk with insertion sort
    var i: usize = 0;
    while (i < n) : (i += MIN_RUN) {
        insertionSort(arr[i..@min(i + MIN_RUN, n)], context, cmp);
    }

    // Phase 2: merge runs bottom-up, doubling the width each round
    var width: usize = MIN_RUN;
    while (width < n) : (width *= 2) {
        var left: usize = 0;
        while (left < n) : (left += 2 * width) {
            const mid = @min(left + width, n);
            const right = @min(left + 2 * width, n);
            if (mid < right) {
                try mergeRanges(alloc, arr, left, mid, right, context, cmp);
            }
        }
    }
}

fn insertionSort(
    arr: []usize,
    context: anytype,
    comptime cmp: fn (@TypeOf(context), usize, usize) bool,
) void {
    var i: usize = 1;
    while (i < arr.len) : (i += 1) {
        const key = arr[i];
        var j: usize = i;
        // Shift right while previous element should come after key
        while (j > 0 and !cmp(context, arr[j - 1], key)) : (j -= 1) {
            arr[j] = arr[j - 1];
        }
        arr[j] = key;
    }
}

fn mergeRanges(
    alloc: Alloc,
    arr: []usize,
    left: usize,
    mid: usize,
    right: usize,
    context: anytype,
    comptime cmp: fn (@TypeOf(context), usize, usize) bool,
) !void {
    const n1 = mid - left;
    const n2 = right - mid;
    const L = try alloc.alloc(usize, n1);
    const R = try alloc.alloc(usize, n2);
    defer {
        alloc.free(L);
        alloc.free(R);
    }
    @memcpy(L, arr[left..mid]);
    @memcpy(R, arr[mid..right]);

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
