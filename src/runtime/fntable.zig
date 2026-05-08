const std = @import("std");
const Alloc = std.mem.Allocator;
const Chunk = @import("tape.zig").Chunk;
const V = @import("../noun/value.zig").V;
const Fn = @import("../noun/operator.zig").Fn;
const opmod = @import("../noun/operator.zig");

pub const LambdaEntry = struct {
  arity:  u8,
  locals: u8,
  chunk:  *Chunk,
  range:  u32,
};

pub const DerivedEntry = struct {
  base:   V,
  adverb: opmod.Adverb,
};

pub const FnTables = struct {
  alloc:   Alloc,
  lambdas: std.ArrayList(LambdaEntry) = .empty,
  derived: std.ArrayList(DerivedEntry) = .empty,

  pub fn init(alloc: Alloc) FnTables {
    return .{ .alloc = alloc };
  }

  pub fn deinit(self: *FnTables) void {
    for (self.lambdas.items) |e| { e.chunk.deinit(); self.alloc.destroy(e.chunk); }
    self.lambdas.deinit(self.alloc);
    for (self.derived.items) |e| e.base.deinit(self.alloc);
    self.derived.deinit(self.alloc);
  }

  pub fn addLambda(self: *FnTables, entry: LambdaEntry) !u24 {
    const idx = self.lambdas.items.len;
    try self.lambdas.append(self.alloc, entry);
    return @intCast(idx);
  }

  pub fn addDerived(self: *FnTables, entry: DerivedEntry) !u24 {
    const idx = self.derived.items.len;
    try self.derived.append(self.alloc, entry);
    return @intCast(idx);
  }

  pub fn lambdaAt(self: *const FnTables, idx: u24) LambdaEntry { return self.lambdas.items[idx]; }
  pub fn derivedAt(self: *const FnTables, idx: u24) DerivedEntry { return self.derived.items[idx]; }
};
