const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("../noun/value.zig").V;
const Pool = @import("../noun/symbol.zig").Pool;

pub fn parse(alloc: Alloc, pool: *Pool, text: []const u8) !V {
    _ = alloc; _ = pool; _ = text;
    return error.NotImplemented;
}
