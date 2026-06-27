//! Parquet file reader: parses `FileMetaData`, walks row groups / column chunks,
//! and decodes data pages into typed columns. Scope is the common flat-schema
//! case produced by mainstream writers (DuckDB, Arrow, Spark):
//!
//!   * physical types BOOLEAN, INT32, INT64, FLOAT, DOUBLE, BYTE_ARRAY,
//!     FIXED_LEN_BYTE_ARRAY
//!   * REQUIRED and OPTIONAL columns (definition levels, max def level 1)
//!   * encodings PLAIN, PLAIN_DICTIONARY, RLE_DICTIONARY (+ RLE bool / def levels)
//!   * codecs UNCOMPRESSED, SNAPPY, GZIP, ZSTD
//!   * data pages v1 and v2
//!
//! Nested / repeated columns (max rep level > 0) are not supported and cause the
//! whole read to fail with `error.Unsupported`.

const std = @import("std");
const thrift = @import("thrift.zig");
const snappy = @import("snappy.zig");

pub const Error = error{ Corrupt, Unsupported, EndOfStream, BadProtocol, OutOfMemory } || thrift.Error;

const NULL_I: i32 = std.math.minInt(i32); // ink 0N

// Parquet physical types.
const T_BOOLEAN = 0;
const T_INT32 = 1;
const T_INT64 = 2;
const T_INT96 = 3;
const T_FLOAT = 4;
const T_DOUBLE = 5;
const T_BYTE_ARRAY = 6;
const T_FLBA = 7;

// Compression codecs.
const C_UNCOMPRESSED = 0;
const C_SNAPPY = 1;
const C_GZIP = 2;
const C_ZSTD = 6;

// Encodings.
const E_PLAIN = 0;
const E_PLAIN_DICTIONARY = 2;
const E_RLE = 3;
const E_RLE_DICTIONARY = 8;

// Page types.
const P_DATA = 0;
const P_DICTIONARY = 2;
const P_DATA_V2 = 3;

pub const Kind = enum { ints, floats, strings };

pub const Column = struct {
  name: []const u8,
  kind: Kind,
  ints: std.ArrayList(i32) = .empty,
  floats: std.ArrayList(f32) = .empty,
  strings: std.ArrayList([]const u8) = .empty,
};

const SchemaElement = struct {
  ptype: i32 = -1, // -1 → group node (no physical type)
  repetition: i32 = 0, // 0 req, 1 opt, 2 repeated
  name: []const u8 = "",
  num_children: i32 = 0,
};

const ColumnMeta = struct {
  ptype: i32 = -1,
  codec: i32 = 0,
  num_values: i64 = 0,
  data_page_offset: i64 = 0,
  dictionary_page_offset: i64 = -1,
};

/// Decode the whole file into a list of typed columns. All column data and
/// names are allocated from `aa` (an arena) so the caller frees them at once.
/// `scratch` is used for transient decompression buffers and freed internally.
pub fn read(aa: std.mem.Allocator, scratch: std.mem.Allocator, file: []const u8) Error![]Column {
  if (file.len < 12) return error.Corrupt;
  if (!std.mem.eql(u8, file[0..4], "PAR1")) return error.Corrupt;
  if (!std.mem.eql(u8, file[file.len - 4 ..], "PAR1")) return error.Corrupt;

  const footer_len: usize = std.mem.readInt(u32, file[file.len - 8 ..][0..4], .little);
  if (footer_len > file.len - 8) return error.Corrupt;
  const meta_start = file.len - 8 - footer_len;
  const meta_bytes = file[meta_start .. file.len - 8];

  // --- Parse FileMetaData ---------------------------------------------------
  var r = thrift.Reader.init(meta_bytes);
  var schema: std.ArrayList(SchemaElement) = .empty;
  defer schema.deinit(scratch);
  var row_groups: std.ArrayList([]ColumnMeta) = .empty;
  defer {
    for (row_groups.items) |rg| scratch.free(rg);
    row_groups.deinit(scratch);
  }

  r.structBegin();
  while (true) {
    const f = try r.fieldBegin();
    if (f.type == .stop) break;
    switch (f.id) {
      2 => { // schema: list<SchemaElement>
        const h = try r.listBegin();
        try schema.ensureTotalCapacity(scratch, h.size);
        var i: usize = 0;
        while (i < h.size) : (i += 1) schema.appendAssumeCapacity(try parseSchemaElement(&r));
      },
      4 => { // row_groups: list<RowGroup>
        const h = try r.listBegin();
        var i: usize = 0;
        while (i < h.size) : (i += 1) {
          const cols = try parseRowGroup(&r, scratch);
          try row_groups.append(scratch, cols);
        }
      },
      else => try r.skip(f.type),
    }
  }
  r.structEnd();

  // --- Build leaf-column list from the (flat) schema ------------------------
  // schema[0] is the root group; leaves are the physical-typed elements.
  var leaves: std.ArrayList(SchemaElement) = .empty;
  defer leaves.deinit(scratch);
  for (schema.items, 0..) |se, idx| {
    if (idx == 0) continue;
    if (se.repetition == 2) return error.Unsupported; // repeated → nested
    if (se.num_children != 0) return error.Unsupported; // group node → nested
    try leaves.append(scratch, se);
  }
  const ncols = leaves.items.len;
  if (ncols == 0) return error.Corrupt;

  const cols = try aa.alloc(Column, ncols);
  for (cols, 0..) |*c, i| {
    const se = leaves.items[i];
    c.* = .{ .name = try aa.dupe(u8, se.name), .kind = kindOf(se.ptype) };
  }

  // --- Decode every column chunk of every row group -------------------------
  for (row_groups.items) |rg| {
    if (rg.len != ncols) return error.Corrupt;
    for (rg, 0..) |cm, ci| {
      const max_def: u32 = if (leaves.items[ci].repetition == 1) 1 else 0;
      try decodeColumnChunk(aa, scratch, file, cm, &cols[ci], max_def);
    }
  }

  return cols;
}

fn kindOf(ptype: i32) Kind {
  return switch (ptype) {
    T_FLOAT, T_DOUBLE => .floats,
    T_BYTE_ARRAY, T_FLBA => .strings,
    else => .ints,
  };
}

fn parseSchemaElement(r: *thrift.Reader) Error!SchemaElement {
  var se: SchemaElement = .{};
  r.structBegin();
  while (true) {
    const f = try r.fieldBegin();
    if (f.type == .stop) break;
    switch (f.id) {
      1 => se.ptype = try r.readI32(),
      3 => se.repetition = try r.readI32(),
      4 => se.name = try r.readBinary(),
      5 => se.num_children = try r.readI32(),
      else => try r.skip(f.type),
    }
  }
  r.structEnd();
  return se;
}

fn parseRowGroup(r: *thrift.Reader, alloc: std.mem.Allocator) Error![]ColumnMeta {
  var cols: std.ArrayList(ColumnMeta) = .empty;
  errdefer cols.deinit(alloc);
  r.structBegin();
  while (true) {
    const f = try r.fieldBegin();
    if (f.type == .stop) break;
    switch (f.id) {
      1 => { // columns: list<ColumnChunk>
        const h = try r.listBegin();
        var i: usize = 0;
        while (i < h.size) : (i += 1) try cols.append(alloc, try parseColumnChunk(r));
      },
      else => try r.skip(f.type),
    }
  }
  r.structEnd();
  return cols.toOwnedSlice(alloc);
}

fn parseColumnChunk(r: *thrift.Reader) Error!ColumnMeta {
  var cm: ColumnMeta = .{};
  r.structBegin();
  while (true) {
    const f = try r.fieldBegin();
    if (f.type == .stop) break;
    switch (f.id) {
      3 => try parseColumnMeta(r, &cm), // meta_data
      else => try r.skip(f.type),
    }
  }
  r.structEnd();
  return cm;
}

fn parseColumnMeta(r: *thrift.Reader, cm: *ColumnMeta) Error!void {
  r.structBegin();
  while (true) {
    const f = try r.fieldBegin();
    if (f.type == .stop) break;
    switch (f.id) {
      1 => cm.ptype = try r.readI32(),
      4 => cm.codec = try r.readI32(),
      5 => cm.num_values = try r.readI64(),
      9 => cm.data_page_offset = try r.readI64(),
      11 => cm.dictionary_page_offset = try r.readI64(),
      else => try r.skip(f.type),
    }
  }
  r.structEnd();
}

// --- Page-header parsing -----------------------------------------------------

const PageHeader = struct {
  ptype: i32 = -1,
  uncompressed_size: i32 = 0,
  compressed_size: i32 = 0,
  // data page (v1/v2)
  num_values: i32 = 0,
  encoding: i32 = 0,
  // v2 only
  num_nulls: i32 = 0,
  def_levels_len: i32 = 0,
  rep_levels_len: i32 = 0,
  v2_compressed: bool = true,
  // dictionary page
  dict_num_values: i32 = 0,
};

fn parsePageHeader(r: *thrift.Reader) Error!PageHeader {
  var ph: PageHeader = .{};
  r.structBegin();
  while (true) {
    const f = try r.fieldBegin();
    if (f.type == .stop) break;
    switch (f.id) {
      1 => ph.ptype = try r.readI32(),
      2 => ph.uncompressed_size = try r.readI32(),
      3 => ph.compressed_size = try r.readI32(),
      5 => try parseDataPageHeader(r, &ph), // DataPageHeader
      7 => try parseDictPageHeader(r, &ph), // DictionaryPageHeader
      8 => try parseDataPageHeaderV2(r, &ph), // DataPageHeaderV2
      else => try r.skip(f.type),
    }
  }
  r.structEnd();
  return ph;
}

fn parseDataPageHeader(r: *thrift.Reader, ph: *PageHeader) Error!void {
  r.structBegin();
  while (true) {
    const f = try r.fieldBegin();
    if (f.type == .stop) break;
    switch (f.id) {
      1 => ph.num_values = try r.readI32(),
      2 => ph.encoding = try r.readI32(),
      else => try r.skip(f.type),
    }
  }
  r.structEnd();
}

fn parseDataPageHeaderV2(r: *thrift.Reader, ph: *PageHeader) Error!void {
  ph.v2_compressed = true;
  r.structBegin();
  while (true) {
    const f = try r.fieldBegin();
    if (f.type == .stop) break;
    switch (f.id) {
      1 => ph.num_values = try r.readI32(),
      2 => ph.num_nulls = try r.readI32(),
      4 => ph.encoding = try r.readI32(),
      5 => ph.def_levels_len = try r.readI32(),
      6 => ph.rep_levels_len = try r.readI32(),
      7 => ph.v2_compressed = try r.readBool(),
      else => try r.skip(f.type),
    }
  }
  r.structEnd();
}

fn parseDictPageHeader(r: *thrift.Reader, ph: *PageHeader) Error!void {
  r.structBegin();
  while (true) {
    const f = try r.fieldBegin();
    if (f.type == .stop) break;
    switch (f.id) {
      1 => ph.dict_num_values = try r.readI32(),
      else => try r.skip(f.type),
    }
  }
  r.structEnd();
}

// --- Column-chunk decoding ---------------------------------------------------

// Per-chunk dictionary (one variant populated, matching the column kind).
const Dictionary = struct {
  ints: []i32 = &.{},
  floats: []f32 = &.{},
  strings: [][]const u8 = &.{},
};

fn decodeColumnChunk(
  aa: std.mem.Allocator,
  scratch: std.mem.Allocator,
  file: []const u8,
  cm: ColumnMeta,
  col: *Column,
  max_def: u32,
) Error!void {
  var start: usize = @intCast(cm.data_page_offset);
  if (cm.dictionary_page_offset >= 0) {
    const d: usize = @intCast(cm.dictionary_page_offset);
    if (d < start) start = d;
  }
  if (start >= file.len) return error.Corrupt;

  var dict: Dictionary = .{};
  var pos = start;
  var values_seen: i64 = 0;

  while (values_seen < cm.num_values) {
    if (pos >= file.len) return error.Corrupt;
    var hr = thrift.Reader.init(file[pos..]);
    const ph = try parsePageHeader(&hr);
    const header_len = hr.pos;
    const body_start = pos + header_len;
    const csize: usize = @intCast(ph.compressed_size);
    if (body_start + csize > file.len) return error.Corrupt;
    const body = file[body_start .. body_start + csize];
    pos = body_start + csize;

    switch (ph.ptype) {
      P_DICTIONARY => {
        const buf = try decompress(scratch, cm.codec, body, @intCast(ph.uncompressed_size));
        defer freeIfOwned(scratch, buf, body);
        dict = try buildDictionary(aa, col.kind, cm.ptype, buf, @intCast(ph.dict_num_values));
      },
      P_DATA => {
        try decodeDataPageV1(aa, scratch, col, cm, ph, body, max_def, dict);
        values_seen += ph.num_values;
      },
      P_DATA_V2 => {
        try decodeDataPageV2(aa, scratch, col, cm, ph, body, max_def, dict);
        values_seen += ph.num_values;
      },
      else => {}, // index page etc. — skip
    }
  }
}

// Returns either the original `body` (uncompressed) or a freshly allocated
// buffer. Use freeIfOwned to release.
fn decompress(alloc: std.mem.Allocator, codec: i32, body: []const u8, ulen: usize) Error![]const u8 {
  switch (codec) {
    C_UNCOMPRESSED => return body,
    C_SNAPPY => return snappy.decompress(alloc, body) catch return error.Corrupt,
    C_GZIP => return inflate(alloc, body, ulen, .gzip),
    C_ZSTD => return zstdDecompress(alloc, body, ulen),
    else => return error.Unsupported,
  }
}

fn freeIfOwned(alloc: std.mem.Allocator, buf: []const u8, body: []const u8) void {
  if (buf.ptr != body.ptr) alloc.free(buf);
}

fn inflate(alloc: std.mem.Allocator, body: []const u8, ulen: usize, container: std.compress.flate.Container) Error![]const u8 {
  const out = alloc.alloc(u8, ulen) catch return error.OutOfMemory;
  errdefer alloc.free(out);
  var in: std.Io.Reader = .fixed(body);
  var window: [std.compress.flate.max_window_len]u8 = undefined;
  var d = std.compress.flate.Decompress.init(&in, container, &window);
  var w: std.Io.Writer = .fixed(out);
  _ = d.reader.streamRemaining(&w) catch return error.Corrupt;
  if (w.end != ulen) return error.Corrupt;
  return out;
}

fn zstdDecompress(alloc: std.mem.Allocator, body: []const u8, ulen: usize) Error![]const u8 {
  const out = alloc.alloc(u8, ulen) catch return error.OutOfMemory;
  errdefer alloc.free(out);
  // The window buffer must hold window_len + block_size_max bytes; it is large
  // (~8 MiB) so it is heap-allocated rather than placed on the stack.
  const zstd = std.compress.zstd;
  const window = alloc.alloc(u8, zstd.default_window_len + zstd.block_size_max) catch return error.OutOfMemory;
  defer alloc.free(window);
  var in: std.Io.Reader = .fixed(body);
  var d = zstd.Decompress.init(&in, window, .{ .verify_checksum = false });
  var w: std.Io.Writer = .fixed(out);
  _ = d.reader.streamRemaining(&w) catch return error.Corrupt;
  if (w.end != ulen) return error.Corrupt;
  return out;
}

fn decodeDataPageV1(
  aa: std.mem.Allocator,
  scratch: std.mem.Allocator,
  col: *Column,
  cm: ColumnMeta,
  ph: PageHeader,
  body: []const u8,
  max_def: u32,
  dict: Dictionary,
) Error!void {
  const buf = try decompress(scratch, cm.codec, body, @intCast(ph.uncompressed_size));
  defer freeIfOwned(scratch, buf, body);

  const n: usize = @intCast(ph.num_values);
  var off: usize = 0;

  // Definition levels (RLE, length-prefixed in v1). max_def is 0 or 1.
  const defs = try scratch.alloc(u32, n);
  defer scratch.free(defs);
  if (max_def > 0) {
    if (off + 4 > buf.len) return error.Corrupt;
    const dl = std.mem.readInt(u32, buf[off..][0..4], .little);
    off += 4;
    if (off + dl > buf.len) return error.Corrupt;
    try decodeRle(buf[off .. off + dl], bitWidth(max_def), n, defs);
    off += dl;
  } else {
    @memset(defs, 0);
  }

  const present = countPresent(defs, max_def);
  try appendValues(aa, col, cm.ptype, ph.encoding, buf[off..], defs, max_def, present, dict);
}

fn decodeDataPageV2(
  aa: std.mem.Allocator,
  scratch: std.mem.Allocator,
  col: *Column,
  cm: ColumnMeta,
  ph: PageHeader,
  body: []const u8,
  max_def: u32,
  dict: Dictionary,
) Error!void {
  const n: usize = @intCast(ph.num_values);
  const rl: usize = @intCast(ph.rep_levels_len);
  const dl: usize = @intCast(ph.def_levels_len);
  if (rl + dl > body.len) return error.Corrupt;

  // In v2, rep/def levels are stored uncompressed before the (maybe compressed)
  // data section; def levels are RLE WITHOUT a 4-byte length prefix.
  const defs = try scratch.alloc(u32, n);
  defer scratch.free(defs);
  if (max_def > 0) {
    try decodeRle(body[rl .. rl + dl], bitWidth(max_def), n, defs);
  } else {
    @memset(defs, 0);
  }

  const data_in = body[rl + dl ..];
  const data = if (ph.v2_compressed)
    try decompress(scratch, cm.codec, data_in, @as(usize, @intCast(ph.uncompressed_size)) - rl - dl)
  else
    data_in;
  defer if (ph.v2_compressed) freeIfOwned(scratch, data, data_in);

  const present = countPresent(defs, max_def);
  try appendValues(aa, col, cm.ptype, ph.encoding, data, defs, max_def, present, dict);
}

fn countPresent(defs: []const u32, max_def: u32) usize {
  if (max_def == 0) return defs.len;
  var c: usize = 0;
  for (defs) |d| if (d == max_def) {
    c += 1;
  };
  return c;
}

// Append a page's worth of values, honouring definition levels for nulls.
fn appendValues(
  aa: std.mem.Allocator,
  col: *Column,
  ptype: i32,
  encoding: i32,
  values: []const u8,
  defs: []const u32,
  max_def: u32,
  present: usize,
  dict: Dictionary,
) Error!void {
  switch (encoding) {
    E_PLAIN => try appendPlain(aa, col, ptype, values, defs, max_def),
    E_PLAIN_DICTIONARY, E_RLE_DICTIONARY => try appendDict(aa, col, values, defs, max_def, present, dict),
    // RLE data encoding only applies to BOOLEAN values (writers such as Arrow
    // prefer it over PLAIN bit-packing). The run stream is length-prefixed.
    E_RLE => if (ptype == T_BOOLEAN)
      try appendRleBool(aa, col, values, defs, max_def, present)
    else
      return error.Unsupported,
    else => return error.Unsupported,
  }
}

fn appendRleBool(
  aa: std.mem.Allocator,
  col: *Column,
  values: []const u8,
  defs: []const u32,
  max_def: u32,
  present: usize,
) Error!void {
  if (values.len < 4) return error.Corrupt;
  const len = std.mem.readInt(u32, values[0..4], .little);
  if (4 + @as(usize, len) > values.len) return error.Corrupt;
  const bits = try aa.alloc(u32, present);
  defer aa.free(bits);
  try decodeRle(values[4 .. 4 + len], 1, present, bits);

  var k: usize = 0;
  for (defs) |d| {
    if (max_def > 0 and d != max_def) {
      try col.ints.append(aa, NULL_I);
      continue;
    }
    try col.ints.append(aa, @intCast(bits[k]));
    k += 1;
  }
}

// --- PLAIN value reader ------------------------------------------------------

const Cursor = struct {
  buf: []const u8,
  pos: usize = 0,

  fn i32le(c: *Cursor) Error!i32 {
    if (c.pos + 4 > c.buf.len) return error.Corrupt;
    const v = std.mem.readInt(i32, c.buf[c.pos..][0..4], .little);
    c.pos += 4;
    return v;
  }
  fn i64le(c: *Cursor) Error!i64 {
    if (c.pos + 8 > c.buf.len) return error.Corrupt;
    const v = std.mem.readInt(i64, c.buf[c.pos..][0..8], .little);
    c.pos += 8;
    return v;
  }
  fn f32le(c: *Cursor) Error!f32 {
    if (c.pos + 4 > c.buf.len) return error.Corrupt;
    const v = std.mem.readInt(u32, c.buf[c.pos..][0..4], .little);
    c.pos += 4;
    return @bitCast(v);
  }
  fn f64le(c: *Cursor) Error!f64 {
    if (c.pos + 8 > c.buf.len) return error.Corrupt;
    const v = std.mem.readInt(u64, c.buf[c.pos..][0..8], .little);
    c.pos += 8;
    return @bitCast(v);
  }
  fn bytes(c: *Cursor, n: usize) Error![]const u8 {
    if (c.pos + n > c.buf.len) return error.Corrupt;
    const out = c.buf[c.pos .. c.pos + n];
    c.pos += n;
    return out;
  }
};

fn iClamp(v: i64) i32 {
  return std.math.cast(i32, v) orelse NULL_I;
}

fn appendPlain(
  aa: std.mem.Allocator,
  col: *Column,
  ptype: i32,
  values: []const u8,
  defs: []const u32,
  max_def: u32,
) Error!void {
  var cur: Cursor = .{ .buf = values };

  // BOOLEAN PLAIN is bit-packed (1 bit/value, LSB first); handle separately.
  if (ptype == T_BOOLEAN) {
    var bitpos: usize = 0;
    for (defs) |d| {
      if (max_def > 0 and d != max_def) {
        try col.ints.append(aa, NULL_I);
        continue;
      }
      const byte = bitpos >> 3;
      if (byte >= values.len) return error.Corrupt;
      const bit: u3 = @intCast(bitpos & 7);
      const v: i32 = (values[byte] >> bit) & 1;
      try col.ints.append(aa, v);
      bitpos += 1;
    }
    return;
  }

  for (defs) |d| {
    const null_here = max_def > 0 and d != max_def;
    switch (col.kind) {
      .ints => {
        if (null_here) {
          try col.ints.append(aa, NULL_I);
        } else switch (ptype) {
          T_INT32 => try col.ints.append(aa, try cur.i32le()),
          T_INT64 => try col.ints.append(aa, iClamp(try cur.i64le())),
          T_INT96 => {
            _ = try cur.bytes(12);
            try col.ints.append(aa, NULL_I); // INT96 timestamps unsupported
          },
          else => return error.Unsupported,
        }
      },
      .floats => {
        if (null_here) {
          try col.floats.append(aa, std.math.nan(f32));
        } else switch (ptype) {
          T_FLOAT => try col.floats.append(aa, try cur.f32le()),
          T_DOUBLE => try col.floats.append(aa, @floatCast(try cur.f64le())),
          else => return error.Unsupported,
        }
      },
      .strings => {
        if (null_here) {
          try col.strings.append(aa, "");
        } else {
          const len: usize = @intCast(try cur.i32le());
          const s = try cur.bytes(len);
          try col.strings.append(aa, try aa.dupe(u8, s));
        }
      },
    }
  }
}

// --- Dictionary decode -------------------------------------------------------

fn buildDictionary(
  aa: std.mem.Allocator,
  kind: Kind,
  ptype: i32,
  buf: []const u8,
  count: usize,
) Error!Dictionary {
  var cur: Cursor = .{ .buf = buf };
  switch (kind) {
    .ints => {
      const out = try aa.alloc(i32, count);
      for (out) |*v| v.* = switch (ptype) {
        T_BOOLEAN, T_INT32 => try cur.i32le(),
        T_INT64 => iClamp(try cur.i64le()),
        else => return error.Unsupported,
      };
      return .{ .ints = out };
    },
    .floats => {
      const out = try aa.alloc(f32, count);
      for (out) |*v| v.* = switch (ptype) {
        T_FLOAT => try cur.f32le(),
        T_DOUBLE => @floatCast(try cur.f64le()),
        else => return error.Unsupported,
      };
      return .{ .floats = out };
    },
    .strings => {
      const out = try aa.alloc([]const u8, count);
      for (out) |*v| {
        const len: usize = @intCast(try cur.i32le());
        v.* = try aa.dupe(u8, try cur.bytes(len));
      }
      return .{ .strings = out };
    },
  }
}

fn appendDict(
  aa: std.mem.Allocator,
  col: *Column,
  values: []const u8,
  defs: []const u32,
  max_def: u32,
  present: usize,
  dict: Dictionary,
) Error!void {
  // Data page dictionary section: 1-byte bit width, then RLE/bit-packed indices.
  if (values.len == 0) {
    // All values null is possible; just emit nulls.
    for (defs) |d| {
      _ = d;
      try appendNull(aa, col);
    }
    return;
  }
  const bw = values[0];
  const idx = try aa.alloc(u32, present);
  defer aa.free(idx);
  try decodeRle(values[1..], bw, present, idx);

  var k: usize = 0;
  for (defs) |d| {
    if (max_def > 0 and d != max_def) {
      try appendNull(aa, col);
      continue;
    }
    const i = idx[k];
    k += 1;
    switch (col.kind) {
      .ints => {
        if (i >= dict.ints.len) return error.Corrupt;
        try col.ints.append(aa, dict.ints[i]);
      },
      .floats => {
        if (i >= dict.floats.len) return error.Corrupt;
        try col.floats.append(aa, dict.floats[i]);
      },
      .strings => {
        if (i >= dict.strings.len) return error.Corrupt;
        try col.strings.append(aa, dict.strings[i]);
      },
    }
  }
}

fn appendNull(aa: std.mem.Allocator, col: *Column) Error!void {
  switch (col.kind) {
    .ints => try col.ints.append(aa, NULL_I),
    .floats => try col.floats.append(aa, std.math.nan(f32)),
    .strings => try col.strings.append(aa, ""),
  }
}

// --- RLE / bit-packing hybrid ------------------------------------------------

fn bitWidth(max_val: u32) u8 {
  if (max_val == 0) return 0;
  return @intCast(32 - @clz(max_val));
}

// Decode `count` values of `bit_width` bits from an RLE/bit-packing hybrid run
// stream into `out`. Stops once `count` values are produced; trailing bytes are
// ignored (correct for unframed dictionary-index streams).
fn decodeRle(data: []const u8, bit_width: u8, count: usize, out: []u32) Error!void {
  if (count == 0) return;
  if (bit_width == 0) {
    @memset(out[0..count], 0);
    return;
  }
  const byte_width = (@as(usize, bit_width) + 7) / 8;
  var pos: usize = 0;
  var produced: usize = 0;

  while (produced < count) {
    // run header: ULEB128
    var header: u64 = 0;
    var shift: u6 = 0;
    while (true) {
      if (pos >= data.len) return error.Corrupt;
      const b = data[pos];
      pos += 1;
      header |= @as(u64, b & 0x7f) << shift;
      if (b & 0x80 == 0) break;
      if (shift >= 63) return error.Corrupt;
      shift += 7;
    }

    if (header & 1 == 1) {
      // bit-packed run: (header>>1) groups of 8 values
      const groups: usize = @intCast(header >> 1);
      const nvals = groups * 8;
      const nbytes = groups * @as(usize, bit_width);
      if (pos + nbytes > data.len) return error.Corrupt;
      var bitbuf: u64 = 0;
      var bits: u6 = 0;
      var bp = pos;
      var i: usize = 0;
      while (i < nvals and produced < count) : (i += 1) {
        while (bits < bit_width) {
          bitbuf |= @as(u64, data[bp]) << bits;
          bp += 1;
          bits += 8;
        }
        const mask: u64 = (@as(u64, 1) << @intCast(bit_width)) - 1;
        out[produced] = @intCast(bitbuf & mask);
        produced += 1;
        bitbuf >>= @intCast(bit_width);
        bits -= @intCast(bit_width);
      }
      pos += nbytes;
    } else {
      // RLE run: (header>>1) repeats of one value, byte_width bytes LE
      var rle_len: usize = @intCast(header >> 1);
      if (pos + byte_width > data.len) return error.Corrupt;
      var val: u32 = 0;
      var i: usize = 0;
      while (i < byte_width) : (i += 1) val |= @as(u32, data[pos + i]) << @intCast(8 * i);
      pos += byte_width;
      while (rle_len > 0 and produced < count) : (rle_len -= 1) {
        out[produced] = val;
        produced += 1;
      }
    }
  }
}
