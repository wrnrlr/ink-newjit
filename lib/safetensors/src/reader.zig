//! Safetensors container parsing: the 8-byte header length, the JSON header, and
//! the per-tensor specs (dtype, shape, byte range into the data blob). Actual
//! numeric decoding into ink I/F vectors lives in main.zig (it needs the k-ABI).
//!
//! File layout (https://github.com/huggingface/safetensors):
//!   [0..8)      u64 little-endian  = N, the JSON header length in bytes
//!   [8..8+N)    UTF-8 JSON object  = { name: {dtype, shape, data_offsets}, ... }
//!   [8+N..)     raw tensor data; data_offsets are relative to this blob start
//! The special key "__metadata__" maps to a string→string dict, not a tensor.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const Dtype = enum {
  BOOL,
  U8,
  I8,
  I16,
  U16,
  F16,
  BF16,
  I32,
  U32,
  F32,
  F64,
  I64,
  U64,

  pub fn parse(s: []const u8) ?Dtype {
    const map = .{
      .{ "BOOL", .BOOL }, .{ "U8", .U8 },   .{ "I8", .I8 },
      .{ "I16", .I16 },   .{ "U16", .U16 }, .{ "F16", .F16 },
      .{ "BF16", .BF16 }, .{ "I32", .I32 }, .{ "U32", .U32 },
      .{ "F32", .F32 },   .{ "F64", .F64 }, .{ "I64", .I64 },
      .{ "U64", .U64 },
    };
    inline for (map) |pair| {
      if (std.mem.eql(u8, s, pair[0])) return pair[1];
    }
    return null;
  }

  /// ink type symbol reported to the caller — the *original* dtype, so no
  /// precision/signedness information is lost even though the decoded column is
  /// widened to i32 or f32.
  pub fn sym(d: Dtype) [*:0]const u8 {
    return switch (d) {
      .BOOL => "bool", .U8 => "u8",   .I8 => "i8",
      .I16 => "i16",   .U16 => "u16", .F16 => "f16",
      .BF16 => "bf16", .I32 => "i32", .U32 => "u32",
      .F32 => "f32",   .F64 => "f64", .I64 => "i64",
      .U64 => "u64",
    };
  }

  pub fn size(d: Dtype) usize {
    return switch (d) {
      .BOOL, .U8, .I8 => 1,
      .I16, .U16, .F16, .BF16 => 2,
      .I32, .U32, .F32 => 4,
      .F64, .I64, .U64 => 8,
    };
  }

  pub fn isFloat(d: Dtype) bool {
    return switch (d) {
      .F16, .BF16, .F32, .F64 => true,
      else => false,
    };
  }
};

pub const Tensor = struct {
  name: []const u8,
  dtype: Dtype,
  shape: []const i32,
  begin: usize, // into the data blob
  end: usize,
};

pub const Meta = struct {
  key: []const u8,
  val: []const u8,
};

pub const File = struct {
  tensors: []const Tensor,
  meta: []const Meta, // entries from "__metadata__", empty if absent
  data: []const u8, // the tensor data blob (offsets index into this)
};

pub const Error = error{ Malformed, OutOfMemory };

pub fn read(aa: Alloc, bytes: []const u8) Error!File {
  if (bytes.len < 8) return error.Malformed;
  const hlen: u64 = std.mem.readInt(u64, bytes[0..8], .little);
  const data_start = 8 + hlen;
  if (data_start > bytes.len) return error.Malformed;
  const header = bytes[8..data_start];
  const data = bytes[data_start..];

  const parsed = std.json.parseFromSlice(std.json.Value, aa, header, .{}) catch return error.Malformed;
  const root = switch (parsed.value) {
    .object => |o| o,
    else => return error.Malformed,
  };

  var tensors: std.ArrayList(Tensor) = .empty;
  var meta: std.ArrayList(Meta) = .empty;

  var it = root.iterator();
  while (it.next()) |entry| {
    const name = entry.key_ptr.*;
    if (std.mem.eql(u8, name, "__metadata__")) {
      const mo = switch (entry.value_ptr.*) {
        .object => |o| o,
        else => continue,
      };
      var mit = mo.iterator();
      while (mit.next()) |me| {
        const v = switch (me.value_ptr.*) {
          .string => |s| s,
          else => continue,
        };
        try meta.append(aa, .{ .key = me.key_ptr.*, .val = v });
      }
      continue;
    }
    const obj = switch (entry.value_ptr.*) {
      .object => |o| o,
      else => return error.Malformed,
    };
    const dt_v = obj.get("dtype") orelse return error.Malformed;
    const dt_s = switch (dt_v) {
      .string => |s| s,
      else => return error.Malformed,
    };
    const dtype = Dtype.parse(dt_s) orelse return error.Malformed;

    const shape = try parseShape(aa, obj.get("shape") orelse return error.Malformed);
    const off = obj.get("data_offsets") orelse return error.Malformed;
    const range = try parseOffsets(off);
    if (range[1] < range[0] or range[1] > data.len) return error.Malformed;

    try tensors.append(aa, .{
      .name = name,
      .dtype = dtype,
      .shape = shape,
      .begin = range[0],
      .end = range[1],
    });
  }

  return .{
    .tensors = tensors.items,
    .meta = meta.items,
    .data = data,
  };
}

fn parseShape(aa: Alloc, v: std.json.Value) Error![]const i32 {
  const arr = switch (v) {
    .array => |a| a.items,
    else => return error.Malformed,
  };
  const out = try aa.alloc(i32, arr.len);
  for (arr, 0..) |el, i| {
    out[i] = switch (el) {
      .integer => |n| @intCast(std.math.clamp(n, 0, std.math.maxInt(i32))),
      else => return error.Malformed,
    };
  }
  return out;
}

fn parseOffsets(v: std.json.Value) Error![2]usize {
  const arr = switch (v) {
    .array => |a| a.items,
    else => return error.Malformed,
  };
  if (arr.len != 2) return error.Malformed;
  var out: [2]usize = undefined;
  for (arr, 0..) |el, i| {
    const n = switch (el) {
      .integer => |x| x,
      else => return error.Malformed,
    };
    if (n < 0) return error.Malformed;
    out[i] = @intCast(n);
  }
  return out;
}
