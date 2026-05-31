const std = @import("std");
const VM = @import("../runtime/vm.zig").VM;
const V = @import("./value.zig").V;
const Fn = @import("./operator.zig").Fn;
const Adverb = @import("./operator.zig").Adverb;
const FnKind = @import("./operator.zig").FnKind;
const Dict = @import("./dict.zig").Dict;
const Alloc = std.mem.Allocator;

fn adverbStr(adv: Adverb) []const u8 {
  return switch (adv) {
    .@"'" => "'",
    .@"/" => "/",
    .@"\\" => "\\",
    .@"':" => "':",
    .@"/:" => "/:",
    .@"\\:" => "\\:",
  };
}

pub const Formatter = struct {
  ctx: *anyopaque,
  formatFn: *const fn (ctx: *anyopaque, value: V, writer: *std.Io.Writer) anyerror!void,

  pub fn format(self: Formatter, value: V, writer: *std.Io.Writer) !void {
    try self.formatFn(self.ctx, value, writer);
  }
};

pub const TerseFormatter = struct {
  vm: *const VM,
  alloc: Alloc,
  mode: Mode,
  indent_level: usize = 0,
  force_single_line: bool = false,

  pub const Mode = enum { Repl, Text };

  const Self = @This();

  pub fn init(vm: *const VM, alloc: Alloc, mode: Mode) Self {
    return .{
      .vm = vm,
      .alloc = alloc,
      .mode = mode,
      .force_single_line = (mode == .Text),
    };
  }

  pub fn formatter(self: *Self) Formatter {
    return Formatter{
      .ctx = self,
      .formatFn = struct {
        fn format(ctx: *anyopaque, value: V, writer: *std.Io.Writer) anyerror!void {
          const self_ptr: *Self = @ptrCast(@alignCast(ctx));
          try self_ptr.formatValue(value, writer);
        }
      }.format,
    };
  }

  fn formatValue(self: *Self, v: V, w: anytype) anyerror!void {
    switch (v) {
      .i => |a| {
        if (a == std.math.minInt(i32)) {
          try w.writeAll("0N");
        } else {
          try w.print("{d}", .{a});
        }
      },
      .f => |a| {
        if (std.math.isNan(a)) {
          try w.writeAll("0n");
        } else if (std.math.isInf(a)) {
          try w.writeAll(if (a > 0) "0w" else "-0w");
        } else {
          var buf: [64]u8 = undefined;
          const s = try std.fmt.bufPrint(&buf, "{d}", .{a});
          try w.writeAll(s);
          if (std.mem.indexOfScalar(u8, s, '.') == null and std.mem.indexOfScalar(u8, s, 'e') == null) {
            try w.writeAll(".0");
          }
        }
      },
      .c => |a| {
        const byte: u8 = @intCast(a);
        try w.writeAll("\"");
        switch (byte) {
          0    => try w.writeAll("\\0"),
          '\n' => try w.writeAll("\\n"),
          '\t' => try w.writeAll("\\t"),
          '\\' => try w.writeAll("\\\\"),
          else => try w.writeByte(byte),
        }
        try w.writeAll("\"");
      },
      .b => |a| try w.print("{d}b", .{@as(u8, if (a) 1 else 0)}),
      .s => |a| {
        if (a < self.vm.symbolCount()) {
          try w.print("`{s}", .{self.vm.getSymbol(a)});
        } else {
          try w.print("`{d}", .{a});
        }
      },
      .I => |n| try self.formatVector(i32, n.slice(), w),
      .F => |n| try self.formatVector(f32, n.slice(), w),
      .S => |n| try self.formatVector(u32, n.slice(), w),
      .C => |n| try self.formatVector(u8, n.slice(), w),
      .B => |n| try self.formatVector(bool, n.slice(), w),
      .L => |n| {
        const slice = n.slice();
        if (slice.len == 0) {
          try w.writeAll("()");
          return;
        }

        if (slice.len == 1) {
          try w.writeAll(",");
          try self.formatValue(slice[0], w);
          return;
        }

        try w.writeAll("(");
        const is_multiline = !self.force_single_line and self.isComplex(v);
        const old_single = self.force_single_line;
        if (is_multiline) {
          self.force_single_line = true;
          self.indent_level += 1;
        }

        for (slice, 0..) |item, i| {
          if (i > 0) {
            if (is_multiline) {
              try w.writeAll("\n");
              try self.writeIndent(w);
            } else {
              try w.writeAll(";");
            }
          }
          try self.formatValue(item, w);
        }
        if (is_multiline) self.indent_level -= 1;
        self.force_single_line = old_single;
        try w.writeAll(")");
      },
      .m => |d| try self.formatDict(d, w),
      .M => |d| try self.formatTable(d, w),
      .func => |ref| try self.formatFn(ref, w),
      .partial => |p| {
        // Compact display for operator projections: 1+ or +1
        const opmod = @import("./operator.zig");
        const is_builtin = p.ref.kind == .callable and opmod.isBuiltinIdx(p.ref.idx) and p.ref.arity == 2;
        if (is_builtin and p.arity == 2) {
          const arg0_filled = p.fill & 1 != 0;
          const arg1_filled = p.fill & 2 != 0;
          if (arg0_filled and !arg1_filled) {
            try self.formatValue(p.args[0], w);
            try self.formatFn(p.ref, w);
            return;
          } else if (!arg0_filled and arg1_filled) {
            try self.formatFn(p.ref, w);
            try self.formatValue(p.args[1], w);
            return;
          }
        }
        try self.formatFn(p.ref, w);
        try w.writeAll("[");
        for (0..p.arity) |i| {
          if (i > 0) try w.writeAll(";");
          if (p.fill & (@as(u8, 1) << @intCast(i)) != 0)
            try self.formatValue(p.args[i], w);
        }
        try w.writeAll("]");
      },
      .x => |obj| {
        if (obj.vtable.format_fn) |fmt| {
          var buf: [256]u8 = undefined;
          const n = fmt(obj.data, &buf);
          try w.writeAll(buf[0..n]);
        } else {
          try w.print("<{s}>", .{obj.vtable.name});
        }
      },
      .err => |a| try w.print("!{s}", .{@tagName(a)}),
      .blank => {},
    }
  }

  fn formatFn(self: *Self, ref: Fn, w: anytype) anyerror!void {
    const opmod = @import("./operator.zig");
    switch (ref.kind) {
      .callable => {
        const idx = ref.idx;
        if (opmod.isLambdaIdx(idx)) {
          const entry = self.vm.fn_tables.lambdaAt(opmod.lambdaIdxOf(idx));
          try w.writeAll(self.vm.registry.getSource(entry.range));
        } else if (opmod.isOp1Idx(idx)) {
          try w.writeAll(opmod.op1OfIdx(idx).toString());
          try w.writeAll(":");
        } else if (opmod.isOp2Idx(idx)) {
          try w.writeAll(opmod.op2OfIdx(idx).toString());
        } else if (opmod.isAdverbIdx(idx)) {
          try w.writeAll(@tagName(opmod.adverbOfIdx(idx)));
        } else if (opmod.isOp3Idx(idx)) {
          try w.writeAll(opmod.op3OfIdx(idx).toString());
        } else if (opmod.isOp4Idx(idx)) {
          try w.writeAll(opmod.op4OfIdx(idx).toString());
        }
      },
      .derived => {
        const base_idx = ref.idx;
        if (opmod.isLambdaIdx(base_idx)) {
          try w.print("{{lambda:{d}}}", .{opmod.lambdaIdxOf(base_idx)});
        } else if (opmod.isOp1Idx(base_idx)) {
          try w.writeAll(opmod.op1OfIdx(base_idx).toString());
        } else if (opmod.isOp2Idx(base_idx)) {
          try w.writeAll(opmod.op2OfIdx(base_idx).toString());
        } else {
          try w.print("[builtin:{d}]", .{base_idx});
        }
        try w.writeAll(adverbStr(ref.getAdverb()));
      },
      .derived_data => {
        const entry = self.vm.fn_tables.derivedAt(@intCast(ref.idx));
        try self.formatValue(entry.base, w);
        try w.writeAll(adverbStr(entry.adverb));
      },
      .train => {
        var buf: [7]u8 = undefined;
        const ops = ref.trainOps(&buf);
        try w.writeAll(ops);
      },
    }
  }

  fn formatVector(self: *Self, comptime T: type, slice: []const T, w: anytype) anyerror!void {
    if (T == u8) {
      if (slice.len == 1) try w.writeAll(",");
      try w.writeAll("\"");
      for (slice) |c| {
        switch (c) {
          0    => try w.writeAll("\\0"),
          '\n' => try w.writeAll("\\n"),
          '\t' => try w.writeAll("\\t"),
          '\\' => try w.writeAll("\\\\"),
          else => try w.writeByte(c),
        }
      }
      try w.writeAll("\"");
      return;
    }
    if (slice.len == 0) {
      try w.writeAll("&0");
    } else if (slice.len == 1) {
      try w.writeAll(",");
      try self.formatAtom(T, slice[0], w);
    } else {
      for (slice, 0..) |e, i| {
        if (i > 0 and (T != u32 or self.mode == .Repl)) try w.writeAll(" ");
        try self.formatAtom(T, e, w);
      }
    }
  }

  fn formatDict(self: *Self, d: Dict, w: anytype) anyerror!void {
    const keys = d.av();
    const vals = d.bv();
    const n = keys.len();

    const can_use_syntax = (keys.tag() == .S) or (keys.tag() == .s) or (keys.tag() == .L and self.allSymbols(keys.L.slice()));

    if (!can_use_syntax) {
      try self.formatValue(keys, w);
      try w.writeAll("!");
      try self.formatValue(vals, w);
      return;
    }

    try w.writeAll("[");
    for (0..n) |i| {
      if (i > 0) try w.writeAll(";");
      const k = keys.at(i);
      defer k.deinit(self.alloc);
      if (k.tag() == .s) {
        if (k.s < self.vm.symbolCount()) {
          try w.writeAll(self.vm.getSymbol(k.s));
        } else {
          try w.print("{d}", .{k.s});
        }
      } else {
        try self.formatValue(k, w);
      }
      try w.writeAll(":");
      const v = if (n == 1) vals.ref() else vals.at(i);
      defer v.deinit(self.alloc);
      try self.formatValue(v, w);
    }
    try w.writeAll("]");
  }

  fn formatTable(self: *Self, d: Dict, w: anytype) anyerror!void {
    try w.writeAll("[[]");
    const keys = d.av();
    const vals = d.bv();
    const n = keys.len();
    for (0..n) |i| {
      if (i > 0) try w.writeAll(";");
      const k = keys.at(i);
      defer k.deinit(self.alloc);
      if (k.tag() == .s) {
        if (k.s < self.vm.symbolCount()) {
          try w.writeAll(self.vm.getSymbol(k.s));
        } else {
          try w.print("{d}", .{k.s});
        }
      } else {
        try self.formatValue(k, w);
      }
      try w.writeAll(":");
      const v = vals.at(i);
      defer v.deinit(self.alloc);
      try self.formatValue(v, w);
    }
    try w.writeAll("]");
  }

  fn allSymbols(self: *Self, slice: []const V) bool {
    _ = self;
    if (slice.len == 0) return false;
    for (slice) |item| {
      if (item.tag() != .s) return false;
    }
    return true;
  }

  fn formatAtom(self: *Self, comptime T: type, val: T, w: anytype) !void {
    switch (T) {
      bool => try self.formatValue(V{ .b = val }, w),
      i32 => try self.formatValue(V{ .i = val }, w),
      f32 => try self.formatValue(V{ .f = val }, w),
      u32 => try self.formatValue(V{ .s = val }, w),
      u8 => try self.formatValue(V{ .c = @intCast(val) }, w),
      else => unreachable,
    }
  }

  fn isComplex(_: *Self, v: V) bool {
    return switch (v) {
      .L => |n| {
        for (n.slice()) |item| {
          if (switch (item) {
            .I, .F, .S, .C, .B, .L, .m => true,
            else => false,
          }) return true;
        }
        return false;
      },
      .m, .M, => true,
      else => false,
    };
  }

  fn writeIndent(self: *Self, w: anytype) anyerror!void {
    if (self.mode == .Text) return;
    for (0..self.indent_level) |_| {
      try w.writeAll(" ");
    }
  }
};

test "format int" {
  
}

test "format float" {
  
}

test "format list" {
  
}
