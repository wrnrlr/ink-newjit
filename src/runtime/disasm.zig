const std = @import("std");
const chunk_mod  = @import("tape.zig");
const value      = @import("../noun/value.zig");
const compiler_mod = @import("compiler.zig");
const ast        = @import("../parser/ast.zig");

const OpCode   = chunk_mod.OpCode;
const Chunk    = chunk_mod.Chunk;
const V        = value.V;
const opmod    = @import("../noun/operator.zig");
const Op1      = opmod.Op1;
const Op2      = opmod.Op2;
const Op3      = opmod.Op3;
const Op4      = opmod.Op4;
const Adverb   = opmod.Adverb;
const Pool   = @import("../noun/symbol.zig").Pool;
const Compiler = compiler_mod.Compiler;
const Parser   = ast.Parser;

pub const Disassembler = struct {
  compiler: *Compiler,

  pub fn init(compiler: *Compiler) Disassembler {
    return .{ .compiler = compiler };
  }

  pub fn compileFile(self: *Disassembler, parser: *Parser, path: []const u8) !void {
    const alloc = self.compiler.alloc;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(10 * 1024 * 1024));
    const text_id = try self.compiler.registry.addFile(path, text);
    const node = try parser.parse(text);
    defer parser.free(node);
    for (self.compiler.chunk.constants.items) |*v| v.deinit(alloc);
    self.compiler.chunk.constants.clearRetainingCapacity();
    self.compiler.chunk.code.clearRetainingCapacity();
    self.compiler.scope.reset();
    self.compiler.text_id = text_id;
    try self.compiler.compile(node, false);
  }

  pub fn print(self: *Disassembler, out: *std.Io.Writer) !void {
    const alloc = self.compiler.alloc;
    const name_map = try buildNameMap(alloc, self.compiler.globals);
    defer alloc.free(name_map);

    try out.print("=== [main] ===\n", .{});
    try printChunk(self.compiler.chunk, self.compiler.symbols, name_map, out);

    for (self.compiler.fn_tables.lambdas.items, 0..) |entry, i| {
      try out.print("\n=== [λ{d}] arity={d} locals={d} ===\n",
        .{ i, entry.arity, entry.locals });
      try printChunk(entry.chunk, self.compiler.symbols, name_map, out);
    }
    try out.flush();
  }
};

fn buildNameMap(alloc: std.mem.Allocator, globals: *std.StringHashMap(u8)) ![]const ?[]const u8 {
  const map = try alloc.alloc(?[]const u8, 256);
  @memset(map, null);
  var it = globals.iterator();
  while (it.next()) |e| map[@as(usize, e.value_ptr.*)] = e.key_ptr.*;
  return map;
}

fn readU16(code: []const u8, ip: usize) u16 {
  return @as(u16, code[ip]) | (@as(u16, code[ip + 1]) << 8);
}

fn printChunk(chunk: *Chunk, symbols: *const Pool, names: []const ?[]const u8, out: *std.Io.Writer) !void {
  const code = chunk.code.items;
  var ip: usize = 0;

  while (ip < code.len) {
    const off = ip;
    const op: OpCode = @enumFromInt(code[ip]);
    ip += 1;

    try out.print(" {d:04}  ", .{off});

    switch (op) {
      .Nop    => try out.print("Nop\n", .{}),
      .Gap    => try out.print("Gap\n", .{}),
      .Drop   => try out.print("Drop\n", .{}),
      .Dup    => try out.print("Dup\n", .{}),
      .Return => try out.print("Return\n", .{}),
      .Const => {
        const idx = code[ip]; ip += 1;
        try out.print("Const       {d:3}    ", .{idx});
        try fmtValue(chunk.constants.items[idx], symbols, out);
        try out.print("\n", .{});
      },
      .Int => {
        const v: i32 = @as(i16, @bitCast(readU16(code, ip))); ip += 2;
        try out.print("Int         {d}\n", .{v});
      },
      .Global => {
        const idx = code[ip]; ip += 1;
        try out.print("Global      {d:3}", .{idx});
        if (names[idx]) |n| try out.print("    ({s})", .{n});
        try out.print("\n", .{});
      },
      .Local => {
        const idx = code[ip]; ip += 1;
        try out.print("Local       {d}\n", .{idx});
      },
      .LocalLast => {
        const idx = code[ip]; ip += 1;
        try out.print("LocalLast   {d}\n", .{idx});
      },

      .AssignGlobal => {
        const idx = code[ip]; ip += 1;
        try out.print("AssignGlobal {d:3}", .{idx});
        if (names[idx]) |n| try out.print("    ({s})", .{n});
        try out.print("\n", .{});
      },
      .AssignLocal => {
        const idx = code[ip]; ip += 1;
        try out.print("AssignLocal  {d}\n", .{idx});
      },
      .ListAssignGlobal => {
        const n = code[ip]; ip += 1;
        try out.print("ListAssignGlobal {d}  (", .{n});
        for (0..n) |k| {
          const idx = code[ip]; ip += 1;
          if (k > 0) try out.print("; ", .{});
          if (names[idx]) |nm| try out.print("{s}", .{nm})
          else try out.print("{d}", .{idx});
        }
        try out.print(")\n", .{});
      },
      .ListAssignLocal => {
        const n = code[ip]; ip += 1;
        try out.print("ListAssignLocal  {d}  (", .{n});
        for (0..n) |k| {
          if (k > 0) try out.print("; ", .{});
          try out.print("{d}", .{code[ip]});
          ip += 1;
        }
        try out.print(")\n", .{});
      },
      .Jump => {
        const delta: i32 = @as(i16, @bitCast(readU16(code, ip))); ip += 2;
        try out.print("Jump        → {d}\n", .{@as(i64, @intCast(ip)) + delta});
      },
      .JumpFalse => {
        const delta: i32 = @as(i16, @bitCast(readU16(code, ip))); ip += 2;
        try out.print("JumpFalse   → {d}\n", .{@as(i64, @intCast(ip)) + delta});
      },
      .JumpTrue => {
        const delta: i32 = @as(i16, @bitCast(readU16(code, ip))); ip += 2;
        try out.print("JumpTrue    → {d}\n", .{@as(i64, @intCast(ip)) + delta});
      },
      .Apply1 => {
        const verb: Op1 = @enumFromInt(code[ip]); ip += 1;
        try out.print("Apply1      {s}\n", .{verb.toString()});
      },
      .Apply2 => {
        const verb: Op2 = @enumFromInt(code[ip]); ip += 1;
        try out.print("Apply2      {s}\n", .{verb.toString()});
      },
      .ReduceZip => {
        const red: Op1 = @enumFromInt(code[ip]); ip += 1;
        const bin: Op2 = @enumFromInt(code[ip]); ip += 1;
        try out.print("ReduceZip   {s} {s}\n", .{ red.toString(), bin.toString() });
      },
      .Call     => { const n = code[ip]; ip += 1; try out.print("Call        {d}\n", .{n}); },
      .TailCall => { const n = code[ip]; ip += 1; try out.print("TailCall    {d}\n", .{n}); },
      .Apply    => { const n = code[ip]; ip += 1; try out.print("Apply       {d}\n", .{n}); },

      .MakeList  => { const n = code[ip]; ip += 1; try out.print("MakeList    {d}\n", .{n}); },
      .Apply3 => {
        const op3: Op3 = @enumFromInt(code[ip]); ip += 1;
        try out.print("Apply3      {s}\n", .{op3.toString()});
      },
      .Apply4 => {
        const op4: Op4 = @enumFromInt(code[ip]); ip += 1;
        try out.print("Apply4      {s}\n", .{op4.toString()});
      },
      .MakePartial => {
        const argc = code[ip]; ip += 1;
        const mask = code[ip]; ip += 1;
        try out.print("MakePartial {d}  mask=0b{b:08}\n", .{ argc, mask });
      },
      .Derive => {
        const adv: Adverb = @enumFromInt(code[ip]); ip += 1;
        try out.print("Derive      {s}\n", .{@tagName(adv)});
      },
      .Command => {
        try out.print("Command\n", .{});
      },
    }
  }
}

fn fmtValue(v: V, symbols: *const Pool, out: *std.Io.Writer) anyerror!void {
  switch (v) {
    .blank   => try out.print("(blank)", .{}),
    .err     => |e| try out.print("!{s}", .{@tagName(e)}),
    .b       => |b| try out.print("{s}", .{if (b) "1b" else "0b"}),
    .i       => |i| try out.print("{d}", .{i}),
    .f       => |f| try out.print("{d}", .{f}),
    .c       => |c| try out.print("\"{c}\"", .{c}),
    .s       => |s| try out.print("`{s}", .{symbols.get(s)}),
    .partial => |p| try out.print("partial(arity={d})", .{p.arity}),
    .m       => try out.print("dict", .{}),
    .M       => try out.print("table", .{}),

    .B => |n| try out.print("B[{d}]", .{n.ptr.len}),
    .F => |n| try out.print("F[{d}]", .{n.ptr.len}),
    .S => |n| try out.print("S[{d}]", .{n.ptr.len}),
    .L => |n| try out.print("L[{d}]", .{n.ptr.len}),

    .I => |n| {
      if (n.ptr.len <= 8) {
        try out.print("(", .{});
        for (n.slice(), 0..) |x, k| {
          if (k > 0) try out.print(" ", .{});
          try out.print("{d}", .{x});
        }
        try out.print(")", .{});
      } else {
        try out.print("I[{d}]", .{n.ptr.len});
      }
    },
    .C => |n| {
      try out.print("\"", .{});
      const s   = n.slice();
      const lim = @min(s.len, 32);
      for (s[0..lim]) |c| try out.print("{c}", .{c});
      if (s.len > 32) try out.print("...", .{});
      try out.print("\"", .{});
    },

    .func => |f| switch (f.kind) {
      .callable => {
        const idx = f.idx;
        if (opmod.isLambdaIdx(idx)) {
          try out.print("λ{d}", .{opmod.lambdaIdxOf(idx)});
        } else if (opmod.isOp1Idx(idx)) {
          try out.print("{s}", .{opmod.op1OfIdx(idx).toString()});
        } else if (opmod.isOp2Idx(idx)) {
          try out.print("{s}", .{opmod.op2OfIdx(idx).toString()});
        } else if (opmod.isAdverbIdx(idx)) {
          try out.print("{s}", .{@tagName(opmod.adverbOfIdx(idx))});
        } else if (opmod.isOp3Idx(idx)) {
          try out.print("{s}", .{opmod.op3OfIdx(idx).toString()});
        } else if (opmod.isOp4Idx(idx)) {
          try out.print("{s}", .{opmod.op4OfIdx(idx).toString()});
        }
      },
      .derived => {
        const base_idx = f.idx;
        if (opmod.isLambdaIdx(base_idx)) {
          try out.print("λ{d}{s}", .{ opmod.lambdaIdxOf(base_idx), @tagName(f.getAdverb()) });
        } else if (opmod.isOp1Idx(base_idx)) {
          try out.print("{s}{s}", .{ opmod.op1OfIdx(base_idx).toString(), @tagName(f.getAdverb()) });
        } else if (opmod.isOp2Idx(base_idx)) {
          try out.print("{s}{s}", .{ opmod.op2OfIdx(base_idx).toString(), @tagName(f.getAdverb()) });
        } else {
          try out.print("[builtin:{d}]{s}", .{ base_idx, @tagName(f.getAdverb()) });
        }
      },
      .derived_data => try out.print("derived[{d}]{s}", .{ f.idx, @tagName(f.getAdverb()) }),
      .train => {
        var buf: [7]u8 = undefined;
        try out.print("train({s})", .{f.trainOps(&buf)});
      },
    },
    .x => |obj| try out.print("<{s}>", .{obj.vtable.name}),
  }
}
