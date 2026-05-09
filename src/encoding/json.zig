const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../noun/value.zig");
const util = @import("../util.zig");
const promote = @import("../primitive/promote.zig").promote;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const Dict = @import("../noun/dict.zig").Dict;
const Pool = @import("../noun/symbol.zig").Pool;

// --- Recursive JSON → Terse conversion ---
//
//  null             → .blank
//  bool             → .b
//  integer          → .i
//  float            → .f
//  string           → .C
//  array (uniform)  → promoted vector (.I / .F / .B / .S / ...)
//  array of dicts with identical keys → Table (.A)
//  array (mixed)    → list (.L)
//  object           → dict (.m)

fn convertVal(alloc: Alloc, pool: *Pool, jv: std.json.Value) anyerror!V {
  return switch (jv) {
    .null            => .blank,
    .bool            => |b| V{ .b = b },
    .integer         => |i| V{ .i = std.math.cast(i32, i) orelse V.@"0N" },
    .float           => |f| V{ .f = @floatCast(f) },
    .number_string   => |s| blk: {
      if (std.fmt.parseInt(i32, s, 10)) |iv| break :blk V{ .i = iv } else |_| {}
      if (std.fmt.parseFloat(f32, s))  |fv| break :blk V{ .f = fv } else |_| {}
      break :blk try V.Chars(alloc, s);
    },
    .string          => |s| try V.Chars(alloc, s),
    .array           => |arr| try convertArr(alloc, pool, arr.items),
    .object          => |obj| try convertObj(alloc, pool, &obj),
  };
}

fn convertArr(alloc: Alloc, pool: *Pool, items: []const std.json.Value) anyerror!V {
  if (items.len == 0) return V{ .L = try N(V).init(alloc, 0) };

  var list = try std.ArrayList(V).initCapacity(alloc, items.len);
  defer {
    for (list.items) |v| v.deinit(alloc);
    list.deinit(alloc);
  }

  for (items) |item| {
    const v = try convertVal(alloc, pool, item);
    list.append(alloc, v) catch |err| { v.deinit(alloc); return err; };
  }

  // Promote array-of-same-schema-dicts to a Table.
  if (list.items[0].tag() == .m) {
    if (tryTable(alloc, list.items)) |t| return t else |_| {}
  }

  const lv = try V.Values(alloc, list.items);
  return promote(alloc, lv.L);
}

/// Try to build a Table from a slice of dicts that all share the same symbol keys.
fn tryTable(alloc: Alloc, items: []const V) !V {
  if (items[0].tag() != .m) return error.CannotPromote;
  const ref_keys = items[0].m.av();
  if (ref_keys.tag() != .S) return error.CannotPromote;
  const num_cols = ref_keys.S.ptr.len;

  // All items must be dicts with the same key vector.
  for (items[1..]) |item| {
    if (item.tag() != .m) return error.CannotPromote;
    const ks = item.m.av();
    if (ks.tag() != .S or ks.S.ptr.len != num_cols) return error.CannotPromote;
    if (!std.mem.eql(u32, ks.S.slice(), ref_keys.S.slice())) return error.CannotPromote;
  }
  // Values side must be an L vector (standard dict layout).
  if (items[0].m.bv().tag() != .L) return error.CannotPromote;

  // Collect per-column lists.
  var cols = try alloc.alloc(std.ArrayList(V), num_cols);
  for (0..num_cols) |i| cols[i] = try std.ArrayList(V).initCapacity(alloc, items.len);
  defer {
    for (cols) |*cl| { for (cl.items) |v| v.deinit(alloc); cl.deinit(alloc); }
    alloc.free(cols);
  }

  for (items) |item| {
    const vslice = item.m.bv().L.slice();
    if (vslice.len != num_cols) return error.CannotPromote;
    for (vslice, 0..) |v, i| {
      cols[i].append(alloc, v.ref()) catch |err| return err;
    }
  }

  const sk_n = try N(u32).init(alloc, num_cols);
  @memcpy(sk_n.slice(), ref_keys.S.slice());

  const sv_n = try N(V).init(alloc, num_cols);
  errdefer sv_n.deinit(alloc);
  const sv = V{ .L = sv_n };
  for (0..num_cols) |i| {
    const col_raw = try V.Values(alloc, cols[i].items);
    sv_n.slice()[i] = promote(alloc, col_raw.L);
  }

  return V{ .M = try Dict.init(alloc, .{ .S = sk_n }, sv) };
}

fn convertObj(alloc: Alloc, pool: *Pool, obj: *const std.json.ObjectMap) anyerror!V {
  const count = obj.count();
  var keys = try std.ArrayList(u32).initCapacity(alloc, count);
  defer keys.deinit(alloc);
  var vals = try std.ArrayList(V).initCapacity(alloc, count);
  defer { for (vals.items) |v| v.deinit(alloc); vals.deinit(alloc); }

  var it = obj.iterator();
  while (it.next()) |entry| {
    try keys.append(alloc, try pool.intern(entry.key_ptr.*));
    const v = try convertVal(alloc, pool, entry.value_ptr.*);
    vals.append(alloc, v) catch |err| { v.deinit(alloc); return err; };
  }

  const kv = try V.Symbols(alloc, keys.items);
  errdefer kv.deinit(alloc);
  const vv = try V.Values(alloc, vals.items);
  errdefer vv.deinit(alloc);
  return V{ .m = try Dict.init(alloc, kv, vv) };
}

pub fn parse(alloc: Alloc, pool: *Pool, text: []const u8) !V {
  if (text.len == 0) return .{ .err = .domain };
  const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch
    return .{ .err = .domain };
  defer parsed.deinit();
  return convertVal(alloc, pool, parsed.value) catch .{ .err = .domain };
}
