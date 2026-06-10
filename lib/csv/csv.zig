const std = @import("std");
const Alloc = std.mem.Allocator;
const util = @import("../util.zig");
const promote = @import("../primitive/promote.zig").promote;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const Dict = @import("../noun/dict.zig").Dict;
const Pool = @import("../noun/symbol.zig").Pool;

fn isNumeric(s: []const u8) bool {
  if (s.len == 0) return false;
  _ = std.fmt.parseInt(i32, s, 10) catch {
    _ = std.fmt.parseFloat(f32, s) catch return false;
  };
  return true;
}

fn parseCell(alloc: Alloc, s: []const u8) !V {
  if (std.fmt.parseInt(i32, s, 10)) |iv| return V{ .i = iv } else |_| {}
  if (std.fmt.parseFloat(f32, s)) |fv| return V{ .f = fv } else |_| {}
  return V.Chars(alloc, s);
}

/// Parse CSV text into a Table value.
/// `pool` is the symbol intern pool (from vm.registry.symbols).
pub fn parse(alloc: Alloc, pool: *Pool, text: []const u8) !V {
  if (text.len == 0) return .{ .err = .domain };

  var rows = std.mem.splitScalar(u8, text, '\n');
  const first_line = rows.next() orelse return .{ .err = .domain };

  // Count columns from the first line.
  var num_cols: usize = 0;
  {
    var it = std.mem.splitScalar(u8, first_line, ',');
    while (it.next()) |_| num_cols += 1;
  }
  if (num_cols == 0) return .{ .err = .domain };

  // Detect header row: if any field in the first row is numeric, treat it as data.
  var has_header = true;
  {
    var it = std.mem.splitScalar(u8, first_line, ',');
    while (it.next()) |field| {
      if (isNumeric(std.mem.trim(u8, field, " \"\r\t"))) {
        has_header = false;
        break;
      }
    }
  }

  // Estimate row count by counting newlines (used to pre-size column arrays).
  var est_rows: usize = 0;
  for (text) |c| if (c == '\n') { est_rows += 1; };
  if (has_header and est_rows > 0) est_rows -= 1;
  if (est_rows == 0) est_rows = 4; // minimum sensible default

  // Build keys array.
  var keys_list = try std.ArrayList(u32).initCapacity(alloc, num_cols);
  defer keys_list.deinit(alloc);

  if (has_header) {
    var it = std.mem.splitScalar(u8, first_line, ',');
    while (it.next()) |field| {
      try keys_list.append(alloc, try pool.intern(std.mem.trim(u8, field, " \"\r\t")));
    }
  } else {
    for (0..num_cols) |i| {
      var buf: [1]u8 = .{@as(u8, @intCast('a' + (i % 26)))};
      try keys_list.append(alloc, try pool.intern(&buf));
    }
  }

  // Allocate per-column storage with estimated capacity.
  var col_lists = try alloc.alloc(std.ArrayList(V), num_cols);
  for (0..num_cols) |i| col_lists[i] = try std.ArrayList(V).initCapacity(alloc, est_rows);
  defer {
    for (0..num_cols) |i| {
      for (col_lists[i].items) |v| v.deinit(alloc);
      col_lists[i].deinit(alloc);
    }
    alloc.free(col_lists);
  }

  // If no header, parse first line as a data row.
  if (!has_header) {
    var it = std.mem.splitScalar(u8, first_line, ',');
    for (0..num_cols) |i| {
      const raw = it.next() orelse "";
      try col_lists[i].append(alloc, try parseCell(alloc, std.mem.trim(u8, raw, " \"\t")));
    }
  }

  // Parse remaining rows.
  while (rows.next()) |line| {
    const trimmed_line = std.mem.trim(u8, line, " \r\t");
    if (trimmed_line.len == 0) continue;

    var it = std.mem.splitScalar(u8, trimmed_line, ',');
    for (0..num_cols) |i| {
      const raw = it.next() orelse "";
      try col_lists[i].append(alloc, try parseCell(alloc, std.mem.trim(u8, raw, " \"\t")));
    }
  }

  // Build key vector (S) and value vector (L) then promote each column.
  const sk_n = try N(u32).init(alloc, num_cols);
  @memcpy(sk_n.slice(), keys_list.items);

  const sv_n = try N(V).init(alloc, num_cols);
  const sv = V{ .L = sv_n };
  for (0..num_cols) |i| {
    const col_raw = try V.Values(alloc, col_lists[i].items);
    sv_n.slice()[i] = promote(alloc, col_raw.L);
  }

  return V{ .M = try Dict.init(alloc, .{ .S = sk_n }, sv) };
}
