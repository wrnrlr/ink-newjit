const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../noun/value.zig");
const Pool = @import("../noun/symbol.zig").Pool;
const util = @import("../util.zig");
const promote = @import("../primitive/promote.zig").promote;

const V = value.V;
const N = value.N;

/// Shapefile Header (100 bytes)
pub const Header = struct {
  file_code: i32,
  file_length: i32,
  version: i32,
  shape_type: i32,
  xmin: f32,
  ymin: f32,
  xmax: f32,
  ymax: f32,
  zmin: f32,
  zmax: f32,
  mmin: f32,
  mmax: f32,

  pub fn parse(data: []const u8) !Header {
    if (data.len < 100) return error.IncompleteHeader;
    const file_code = std.mem.readInt(i32, data[0..4][0..4], .big);
    if (file_code != 9994) return error.InvalidFileCode;

    return Header{
      .file_code = file_code,
      .file_length = std.mem.readInt(i32, data[24..28][0..4], .big),
      .version = std.mem.readInt(i32, data[28..32][0..4], .little),
      .shape_type = std.mem.readInt(i32, data[32..36][0..4], .little),
      .xmin = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, data[36..44][0..8], .little))))),
      .ymin = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, data[44..52][0..8], .little))))),
      .xmax = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, data[52..60][0..8], .little))))),
      .ymax = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, data[60..68][0..8], .little))))),
      .zmin = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, data[68..76][0..8], .little))))),
      .zmax = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, data[76..84][0..8], .little))))),
      .mmin = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, data[84..92][0..8], .little))))),
      .mmax = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, data[92..100][0..8], .little))))),
    };
  }

  pub fn toV(self: Header, alloc: Alloc, pool: *Pool) !V {
    const keys = [_][]const u8{ "code", "len", "ver", "type", "xmin", "ymin", "xmax", "ymax", "zmin", "zmax", "mmin", "mmax" };
    const sk_n = try N(u32).init(alloc, keys.len);
    for (keys, 0..) |k, i| sk_n.slice()[i] = try pool.intern(k);

    const sv_n = try N(V).init(alloc, keys.len);
    @memset(sv_n.slice(), .blank);
    sv_n.slice()[0] = .{.i = @intCast(self.file_code)};
    sv_n.slice()[1] = .{.i = @intCast(self.file_length)};
    sv_n.slice()[2] = .{.i = @intCast(self.version)};
    sv_n.slice()[3] = .{.i = @intCast(self.shape_type)};
    sv_n.slice()[4] = .{.f = self.xmin};
    sv_n.slice()[5] = .{.f = self.ymin};
    sv_n.slice()[6] = .{.f = self.xmax};
    sv_n.slice()[7] = .{.f = self.ymax};
    sv_n.slice()[8] = .{.f = self.zmin};
    sv_n.slice()[9] = .{.f = self.zmax};
    sv_n.slice()[10] = .{.f = self.mmin};
    sv_n.slice()[11] = .{.f = self.mmax};

    return V{ .m = try value.Dict.init(alloc, .{ .S = sk_n }, .{ .L = sv_n }) };
  }
};

/// Parse .shp file data.
pub fn parseShp(alloc: Alloc, pool: *Pool, data: []const u8) !V {
  if (data.len < 100) return .{.err=.domain};
  const header = Header.parse(data) catch return .{.err=.domain};

  var records = try std.ArrayList(V).initCapacity(alloc, 16);
  defer {
    for (records.items) |v| v.deinit(alloc);
    records.deinit(alloc);
  }

  var pos: usize = 100;
  while (pos + 8 <= data.len) {
    const content_len_words = std.mem.readInt(i32, data[pos+4..pos+8][0..4], .big);
    const content_len = @as(usize, @intCast(content_len_words)) * 2;
    pos += 8;

    if (pos + content_len > data.len) break;
    const record_data = data[pos .. pos + content_len];
    pos += content_len;

    if (record_data.len < 4) {
      try records.append(alloc, .{.blank={}});
      continue;
    }

    const stype = std.mem.readInt(i32, record_data[0..4][0..4], .little);
    var v: V = .{.blank={}};

    switch (stype) {
      0 => v = .{.blank={}}, // Null
      1 => { // Point
        if (record_data.len >= 20) {
          const coords = try N(f32).init(alloc, 2);
          coords.slice()[0] = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, record_data[4..12][0..8], .little)))));
          coords.slice()[1] = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, record_data[12..20][0..8], .little)))));
          v = .{.F = coords};
        }
      },
      3, 5 => { // PolyLine, Polygon
        if (record_data.len >= 44) {
          const num_parts = std.mem.readInt(i32, record_data[36..40][0..4], .little);
          const num_points = std.mem.readInt(i32, record_data[40..44][0..4], .little);
          const parts_offset = 44;
          const points_offset = parts_offset + @as(usize, @intCast(num_parts)) * 4;

          if (record_data.len >= points_offset + @as(usize, @intCast(num_points)) * 16) {
            const parts_n = try N(V).init(alloc, @as(usize, @intCast(num_parts)));
            @memset(parts_n.slice(), .blank);
            v = .{.L = parts_n};

            var i: usize = 0;
            while (i < @as(usize, @intCast(num_parts))) : (i += 1) {
              const start_pt = std.mem.readInt(i32, record_data[parts_offset + i * 4 .. parts_offset + i * 4 + 4][0..4], .little);
              const end_pt = if (i + 1 < @as(usize, @intCast(num_parts))) 
                std.mem.readInt(i32, record_data[parts_offset + (i + 1) * 4 .. parts_offset + (i + 1) * 4 + 4][0..4], .little)
              else 
                num_points;
              
              const part_len = if (end_pt > start_pt) @as(usize, @intCast(end_pt - start_pt)) else 0;
              const coords = try N(f32).init(alloc, part_len * 2);
              var j: usize = 0;
              while (j < part_len) : (j += 1) {
                const pt_pos = points_offset + @as(usize, @intCast(start_pt + @as(i32, @intCast(j)))) * 16;
                coords.slice()[j*2] = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, record_data[pt_pos..pt_pos+8][0..8], .little)))));
                coords.slice()[j*2+1] = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, record_data[pt_pos+8..pt_pos+16][0..8], .little)))));
              }
              parts_n.slice()[i] = .{.F = coords};
            }
          }
        }
      },
      8 => { // MultiPoint
        if (record_data.len >= 40) {
          const num_points = std.mem.readInt(i32, record_data[36..40][0..4], .little);
          const points_offset = 40;
          if (record_data.len >= points_offset + @as(usize, @intCast(num_points)) * 16) {
            const coords = try N(f32).init(alloc, @as(usize, @intCast(num_points)) * 2);
            var i: usize = 0;
            while (i < @as(usize, @intCast(num_points))) : (i += 1) {
              const pt_pos = points_offset + i * 16;
              coords.slice()[i*2] = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, record_data[pt_pos..pt_pos+8][0..8], .little)))));
              coords.slice()[i*2+1] = @as(f32, @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, record_data[pt_pos+8..pt_pos+16][0..8], .little)))));
            }
            v = .{.F = coords};
          }
        }
      },
      else => {},
    }
    try records.append(alloc, v);
  }

  const res_data = try V.valuesFromSlice(alloc, records.items);
  const header_v = try header.toV(alloc, pool);

  const keys = [_][]const u8{ "header", "data" };
  const sk_n = try N(u32).init(alloc, keys.len);
  for (keys, 0..) |k, i| sk_n.slice()[i] = try pool.intern(k);

  const sv_n = try N(V).init(alloc, keys.len);
  @memset(sv_n.slice(), .blank);
  sv_n.slice()[0] = header_v;
  sv_n.slice()[1] = res_data;

  return V{ .m = try value.Dict.init(alloc, .{ .S = sk_n }, .{ .L = sv_n }) };
}

/// Parse .shx index file data.
pub fn parseShx(alloc: Alloc, pool: *Pool, data: []const u8) !V {
  if (data.len < 100) return .{.err=.domain};
  const header = Header.parse(data) catch return .{.err=.domain};

  var records = try std.ArrayListUnmanaged(V).initCapacity(alloc, 16);
  defer {
    for (records.items) |v| v.deinit(alloc);
    records.deinit(alloc);
  }

  var pos: usize = 100;
  while (pos + 8 <= data.len) {
    const offset_words = std.mem.readInt(i32, data[pos..pos+4][0..4], .big);
    const len_words = std.mem.readInt(i32, data[pos+4..pos+8][0..4], .big);
    pos += 8;

    const pair = try N(i32).init(alloc, 2);
    pair.slice()[0] = @as(i32, @intCast(offset_words)) * 2;
    pair.slice()[1] = @as(i32, @intCast(len_words)) * 2;
    try records.append(alloc, .{.I = pair});
  }

  const res_data = try V.valuesFromSlice(alloc, records.items);
  const header_v = try header.toV(alloc, pool);

  const keys = [_][]const u8{ "header", "index" };
  const sk_n = try N(u32).init(alloc, keys.len);
  for (keys, 0..) |k, i| sk_n.slice()[i] = try pool.intern(k);

  const sv_n = try N(V).init(alloc, keys.len);
  @memset(sv_n.slice(), .blank);
  sv_n.slice()[0] = header_v;
  sv_n.slice()[1] = res_data;

  return V{ .m = try value.Dict.init(alloc, .{ .S = sk_n }, .{ .L = sv_n }) };
}

/// Parse .dbf dBase III file data.
pub fn parseDbf(alloc: Alloc, pool: *Pool, data: []const u8) !V {
  if (data.len < 32) return .{.err=.domain};
  
  const num_records_i32 = std.mem.readInt(i32, data[4..8][0..4], .little);
  const num_records = if (num_records_i32 < 0) @as(usize, 0) else @as(usize, @intCast(num_records_i32));
  const header_len = std.mem.readInt(i16, data[8..10][0..2], .little);
  const record_len = std.mem.readInt(i16, data[10..12][0..2], .little);
  
  const num_fields = if (header_len > 33) (@as(usize, @intCast(header_len)) - 33) / 32 else 0;
  
  const Field = struct {
    name: u32,
    type: u8,
    length: u8,
    decimals: u8,
  };
  var fields = try std.ArrayList(Field).initCapacity(alloc, num_fields);
  defer fields.deinit(alloc);

  var field_names = try std.ArrayList(u32).initCapacity(alloc, num_fields);
  defer field_names.deinit(alloc);

  for (0..num_fields) |i| {
    const f_pos = 32 + i * 32;
    if (f_pos + 32 > data.len) break;
    const name_raw = data[f_pos..f_pos+11];
    
    // Trim trailing nulls and spaces
    var name_len: usize = 0;
    while (name_len < 11 and name_raw[name_len] != 0 and name_raw[name_len] != ' ') : (name_len += 1) {}
    
    const name = try pool.intern(name_raw[0..name_len]);
    const f_type = data[f_pos+11];
    const f_len = data[f_pos+16];
    const f_dec = data[f_pos+17];
    
    try field_names.append(alloc, name);
    try fields.append(alloc, .{ .name = name, .type = f_type, .length = f_len, .decimals = f_dec });
  }

  var col_lists = try alloc.alloc(std.ArrayList(V), num_fields);
  for (0..num_fields) |i| col_lists[i] = .empty;
  defer {
    for (0..num_fields) |i| {
      for (col_lists[i].items) |v| v.deinit(alloc);
      col_lists[i].deinit(alloc);
    }
    alloc.free(col_lists);
  }

  for (0..num_fields) |i| {
    col_lists[i] = try std.ArrayList(V).initCapacity(alloc, num_records);
  }

  var row_pos: usize = @as(usize, @intCast(header_len));
  for (0..num_records) |_| {
    if (row_pos + @as(usize, @intCast(record_len)) > data.len) break;
    var f_pos = row_pos + 1;
    for (0..num_fields) |i| {
      const f = fields.items[i];
      if (f_pos + f.length > data.len) break;
      const raw = std.mem.trim(u8, data[f_pos .. f_pos + f.length], " ");
      
      var val: V = .{.blank={}};
      switch (f.type) {
        'N', 'F' => {
          if (raw.len > 0) {
            if (std.fmt.parseFloat(f32, raw)) |fv| {
              if (f.decimals == 0) {
                if (std.fmt.parseInt(i32, raw, 10)) |iv| {
                  val = .{.i = iv};
                } else |_| {
                  val = .{.f = fv};
                }
              } else {
                val = .{.f = fv};
              }
            } else |_| {
              val = if (f.decimals == 0) .{.i = V.@"0N"} else .{.f = std.math.nan(f32)};
            }
          } else {
            val = if (f.decimals == 0) .{.i = V.@"0N"} else .{.f = std.math.nan(f32)};
          }
        },
        'C', 'D' => val = try V.charsFromSlice(alloc, raw),
        'L' => {
          if (raw.len > 0) {
            val = .{.i = if (raw[0] == 'T' or raw[0] == 't' or raw[0] == 'Y' or raw[0] == 'y') @as(i32, 1) else @as(i32, 0)};
          } else {
            val = .{.i = 0};
          }
        },
        else => val = try V.charsFromSlice(alloc, raw),
      }
      try col_lists[i].append(alloc, val);
      f_pos += f.length;
    }
    row_pos += @as(usize, @intCast(record_len));
  }

  const sk_n = try N(u32).init(alloc, num_fields);
  @memcpy(sk_n.slice(), field_names.items);

  const sv_n = try N(V).init(alloc, num_fields);
  for (0..num_fields) |i| {
    const col_raw = try V.valuesFromSlice(alloc, col_lists[i].items);
    sv_n.slice()[i] = try promote(alloc, col_raw.L);
  }

  return V{ .M = try value.Dict.init(alloc, .{ .S = sk_n }, .{.L = sv_n}) };
}

/// Parse .prj projection file data.
pub fn parsePrj(alloc: Alloc, pool: *Pool, data: []const u8) !V {
  _ = pool;
  return try V.charsFromSlice(alloc, data);
}

/// Parse .cpg code page file data.
pub fn parseCpg(alloc: Alloc, pool: *Pool, data: []const u8) !V {
  _ = pool;
  return try V.charsFromSlice(alloc, std.mem.trim(u8, data, " \n\t"));
}
