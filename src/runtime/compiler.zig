const std = @import("std");
const ast = @import("../parser/ast.zig");
const value = @import("../noun/value.zig");
const Adverb = @import("../noun/operator.zig").Adverb;
const ir = @import("ir.zig");
const optimizer = @import("optimizer.zig");
const fntable = @import("fntable.zig");
const V = value.V;
const N = @import("../noun/array.zig").N;
const Fn = @import("../noun/operator.zig").Fn;
const Alloc = std.mem.Allocator;
const Chunk = @import("tape.zig").Chunk;
const OpCode = @import("tape.zig").OpCode;
const Op = @import("tape.zig").Op;
const Pool = @import("../noun/symbol.zig").Pool;
const Registry = @import("registry.zig").Registry;

pub const Compiler = struct {
  alloc: Alloc,
  chunk: *Chunk,
  globals: *std.StringHashMap(u8),
  symbols: *Pool,
  registry: *Registry,
  fn_tables: *fntable.FnTables,
  scope: *Scope,
  text_id: u32 = 0,

  pub fn init(alloc: Alloc, chunk: *Chunk, globals: *std.StringHashMap(u8), symbols: *Pool, registry: *Registry, fn_tables: *fntable.FnTables) !Compiler {
    const scope = try alloc.create(Scope);
    scope.* = try Scope.init(alloc, chunk, null);
    return .{
      .alloc = alloc,
      .chunk = chunk,
      .globals = globals,
      .symbols = symbols,
      .registry = registry,
      .fn_tables = fn_tables,
      .scope = scope,
    };
  }

  pub fn deinit(self: *Compiler) void {
    var curr: ?*Scope = self.scope;
    while (curr) |s| {
      const parent = s.parent;
      s.deinit();
      self.alloc.destroy(s);
      curr = parent;
    }
  }

  pub fn compile(self: *Compiler, node: *ast.Node, is_tail: bool) anyerror!void {
    const root_id = try self.compileNode(node, is_tail);
    if (self.scope.parent == null) {
      var opt = optimizer.Optimizer.init(self.alloc);
      try opt.optimize(&self.scope.ir, root_id);
      _ = try opt.inlineLambdas(&self.scope.ir, self.fn_tables);
      try opt.optimize(&self.scope.ir, root_id);
      try opt.livenessLocals(&self.scope.ir);
      try self.lower();
    }
  }

  fn compileNode(self: *Compiler, node: *ast.Node, is_tail: bool) anyerror!ir.ValueId {
    return switch (node.*) {
      .terse => |t| {
        var res: ir.ValueId = ir.NO_VALUE;
        for (t.stmts, 0..) |stmt, idx| {
          const val = try self.compileNode(stmt.node, is_tail and idx == t.stmts.len - 1);
          if (idx < t.stmts.len - 1) {
            _ = try self.emitOp(.Drop, &.{val});
          } else {
            res = val;
          }
        }
        return res;
      },
      .literal => |lit| try self.compileLiteral(lit),
      .transit => |t| try self.compileTransit(t, is_tail),
      .bind => |b| try self.compileBind(b),
      .lambda => |l| try self.compileLambda(l),
      .apposit => |ap| try self.compileApposit(ap, is_tail),
      .intrans => |i| try self.compileIntrans(i, is_tail),
      .prefix => |p| try self.compilePrefix(p, is_tail),
      .compose => |c| try self.compileCompose(c),
      .group => |g| try self.compileNode(g.stmt, is_tail),
      .apply => |ap| try self.compileApply(ap, is_tail),
      .term => |t| try self.compileTerm(t),
      .cond => |c| try self.compileCond(c, is_tail),
      .right => |r| try self.compileNode(r.clause, is_tail),
      .list => |l| try self.compileList(l),
      .dict => |d| try self.compileDict(d, .MakeDict),
      .table => |t| try self.compileDict(t, .MakeTable),
      .utable => |u| try self.compileUTable(u),
      .pending => |p| try self.compileBind(.{ .v = p.v, .f = p.f, .a = p.a }),
      .verb_op => |op| blk: {
        const v: V = if (Op.fromString(op)) |o|
          .{ .func = Fn.dyad(o) }
        else
          .{ .func = Fn.makeTrain(op) };
        break :blk try self.emitConst(v);
      },
      .io => |io| blk: {
        const op = Op.fromString(io) orelse return error.UnknownOp;
        break :blk try self.emitConst(V{ .func = Fn.dyad(op) });
      },
      .monad => |mv| blk: {
        const op = Op.fromString(mv.f) orelse return error.UnknownOp;
        break :blk try self.emitConst(V{ .func = Fn.monad(op) });
      },
      .adverb_val => |a| try self.emitConst(V{ .func = Fn.adverb(adverbFromString(a)) }),
      .command => |cmd| blk: {
        // Encode command as: verb\0count_str\0args
        var count_buf: [12]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{cmd.n}) catch "1";
        const full_len = cmd.verb.len + 1 + count_str.len + 1 + cmd.args.len;
        const buf = try self.alloc.alloc(u8, full_len);
        defer self.alloc.free(buf);
        @memcpy(buf[0..cmd.verb.len], cmd.verb);
        buf[cmd.verb.len] = 0;
        @memcpy(buf[cmd.verb.len + 1 .. cmd.verb.len + 1 + count_str.len], count_str);
        buf[cmd.verb.len + 1 + count_str.len] = 0;
        @memcpy(buf[cmd.verb.len + 2 + count_str.len ..], cmd.args);
        const cv = V{ .C = try N(u8).n1(self.alloc, buf) };
        defer cv.deinit(self.alloc);
        const const_id = try self.emitConst(cv);
        break :blk try self.emitOpWithArg(.Command, 0, &.{const_id});
      },
      .blank => try self.emitOp(.Gap, &.{}),
      else => {
        std.debug.print("Compiler: Unsupported node type: {}\n", .{std.meta.activeTag(node.*)});
        return ir.NO_VALUE;
      },
    };
  }

  fn compileList(self: *Compiler, l: ast.List) anyerror!ir.ValueId {
    var inputs = try std.ArrayList(ir.ValueId).initCapacity(self.alloc, 0);
    defer inputs.deinit(self.alloc);
    if (l.seq) |seq|
      for (seq) |x| try inputs.append(self.alloc, try self.compileNode(x, false));
    const n = if (l.seq) |seq| @as(u8, @intCast(seq.len)) else 0;
    return try self.emitOpWithArg(.MakeList, n, inputs.items);
  }
  
  fn compileDict(self: *Compiler, d: ast.Dict, op: OpCode) anyerror!ir.ValueId {
    const items = d.items orelse return ir.NO_VALUE;
    var inputs = try std.ArrayList(ir.ValueId).initCapacity(self.alloc, items.len * 2);
    defer inputs.deinit(self.alloc);
    for (items) |item|
      try inputs.append(self.alloc, try self.emitConst(.{ .s = try self.symbols.intern(item.k) }));
    for (items) |item|
      try inputs.append(self.alloc, try self.compileNode(item.v, false));
    return try self.emitOpWithArg(op, @intCast(items.len), inputs.items);
  }

  fn compileUTable(self: *Compiler, u: ast.UTable) anyerror!ir.ValueId {
    _ = self; _ = u;
    @panic("utable not implemented in compiler");
  }

  fn compileApply(self: *Compiler, ap: ast.Apply, is_tail: bool) anyerror!ir.ValueId {
    const seq = if (ap.a) |s| s else &[_]*ast.Node{};
    const n: u8 = @intCast(seq.len);

    // @[x;y;f] and .[x;y;f] with 3+ args compile to Amend/Dmend (no function arg on stack).
    if (ap.f.* == .verb_op and seq.len >= 3) {
      const op_str = ap.f.verb_op;
      const opcode: ?OpCode = if (std.mem.eql(u8, op_str, "@")) .Amend
                              else if (std.mem.eql(u8, op_str, ".")) .Dmend
                              else null;
      if (opcode) |opc| {
        var inputs = try std.ArrayList(ir.ValueId).initCapacity(self.alloc, seq.len);
        defer inputs.deinit(self.alloc);
        for (seq) |x| try inputs.append(self.alloc, try self.compileNode(x, false));
        return try self.emitOpWithArg(opc, n, inputs.items);
      }
    }

    var inputs = try std.ArrayList(ir.ValueId).initCapacity(self.alloc, seq.len + 1);
    defer inputs.deinit(self.alloc);
    try inputs.append(self.alloc, try self.compileNode(ap.f, false));
    for (seq) |x| try inputs.append(self.alloc, try self.compileNode(x, false));
    return try self.emitOpWithArg(if (is_tail) .TailCall else .Apply, n, inputs.items);
  }

  fn compileLiteral(self: *Compiler, lit: ast.Literal) anyerror!ir.ValueId {
    const v = switch (lit) {
      .b => |b| V{ .b = b },
      .i => |i| V{ .i = i },
      .f => |f| V{ .f = f },
      .c => |c| blk: {
        // Decode backslash escapes: \n \t \0 \\ \" → actual bytes
        var buf = try std.ArrayList(u8).initCapacity(self.alloc, c.len);
        defer buf.deinit(self.alloc);
        var i: usize = 0;
        while (i < c.len) {
          if (c[i] == '\\' and i + 1 < c.len) {
            buf.appendAssumeCapacity(switch (c[i + 1]) {
              'n' => '\n', 't' => '\t', '0' => 0, else => c[i + 1],
            });
            i += 2;
          } else {
            buf.appendAssumeCapacity(c[i]);
            i += 1;
          }
        }
        if (buf.items.len == 1) break :blk V{ .c = buf.items[0] };
        const n = try N(u8).n1(self.alloc, buf.items);
        break :blk V{ .C = n };
      },
      .s => |s| V{ .s = try self.symbols.intern(s) },
      .B => |B| V{ .B = try N(bool).fromSlice(self.alloc, B) },
      .I => |I| V{ .I = try N(i32).fromSlice(self.alloc, I) },
      .F => |F| V{ .F = try N(f32).fromSlice(self.alloc, F) },
      .S => |S| blk: {
        const n = try N(u32).init(self.alloc, S.len);
        for (S, 0..) |s, i| n.slice()[i] = try self.symbols.intern(s);
        break :blk V{ .S = n };
      },
      .C => |C| V{ .C = try N(u8).fromSlice(self.alloc, C) },
      .@"var" => |name| return try self.compileVar(name),
    };
    defer v.deinit(self.alloc);
    return try self.emitConst(v);
  }

  fn compileVar(self: *Compiler, name: []const u8) anyerror!ir.ValueId {
    if (self.scope.inline_args) |args| {
      if (std.mem.eql(u8, name, "x")) return if (args.len > 0) args[0] else try self.emitOp(.Gap, &.{});
      if (std.mem.eql(u8, name, "y")) return if (args.len > 1) args[1] else try self.emitOp(.Gap, &.{});
      if (std.mem.eql(u8, name, "z")) return if (args.len > 2) args[2] else try self.emitOp(.Gap, &.{});
    }

    const scope = self.scope;
    if (scope.is_lambda) {
      if (std.mem.eql(u8, name, "x")) { scope.uses_x = true; }
      else if (std.mem.eql(u8, name, "y")) { scope.uses_y = true; }
      else if (std.mem.eql(u8, name, "z")) { scope.uses_z = true; }

      const id = try self.emitOpWithArg(.Local, 0, &.{});
      try self.addPatch(name);
      return id;
    } else {
      if (self.globals.get(name)) |index| {
        return try self.emitOpWithArg(.Global, index, &.{});
      } else {
        const index = @as(u8, @intCast(self.globals.count()));
        try self.globals.put(try self.alloc.dupe(u8, name), index);
        return try self.emitOpWithArg(.Global, index, &.{});
      }
    }
  }

  fn compileBind(self: *Compiler, b: ast.Bind) anyerror!ir.ValueId {
    // `sym: val → sym 0: val  (WriteLines; `0:"hello" → print to stdout)
    if (b.v.* == .literal and b.v.literal == .s and b.a != null and b.f == null) {
      const lhs_id = try self.compileNode(b.v, false);
      const rhs_id = try self.compileNode(b.a.?, false);
      var inputs: [2]ir.ValueId = .{ lhs_id, rhs_id };
      return try self.emitOpWithArg(.Apply2, @intFromEnum(Op.@"0:"), &inputs);
    }

    const rhs_id: ir.ValueId = if (b.a) |rhs| blk: {
      if (b.f) |op| {
        if (std.mem.eql(u8, op, ":")) {
          break :blk try self.compileNode(rhs, false);
        } else {
          var inputs: [2]ir.ValueId = undefined;
          inputs[0] = try self.compileNode(b.v, false);
          inputs[1] = try self.compileNode(rhs, false);
          break :blk try self.compilePrimitive(op, 2, &inputs);
        }
      } else {
        break :blk try self.compileNode(rhs, false);
      }
    } else try self.emitOp(.Gap, &.{});

    if (b.v.* == .literal and b.v.literal == .@"var") {
      const name = b.v.literal.@"var";
      const scope = self.scope;

      const is_global_assign = (b.f != null and std.mem.eql(u8, b.f.?, ":")) or
                               (b.a != null and b.a.?.* == .right);
      if (scope.is_lambda and !is_global_assign) {
        if (!scope.locals.contains(name)) try scope.locals.put(name, 0);
        const id = try self.emitOp(.AssignLocal, &.{rhs_id});
        try self.addPatch(name);
        return id;
      } else {
        const gop = try self.globals.getOrPut(name);
        if (!gop.found_existing) {
          gop.key_ptr.* = try self.alloc.dupe(u8, name);
          gop.value_ptr.* = @intCast(self.globals.count() - 1);
        }
        return try self.emitOpWithArg(.AssignGlobal, gop.value_ptr.*, &.{rhs_id});
      }
    } else if (b.v.* == .list) {
      const list = b.v.list;
      const seq = list.seq orelse return ir.NO_VALUE;
      const n: u8 = @intCast(seq.len);
      const scope = self.scope;

      if (scope.is_lambda) {
        const id = try self.emitOpWithArg(.ListAssignLocal, n, &.{rhs_id});
        for (seq) |item| {
          if (item.* == .literal and item.literal == .@"var") {
            const name = item.literal.@"var";
            if (!scope.locals.contains(name)) try scope.locals.put(name, 0);
            const nop_id = try self.emitOpWithArg(.Nop, 0, &.{});
            const inst = self.scope.ir.get(nop_id);
            inst.arg3 = 1;
            self.scope.ir.markEffectful(nop_id);
            try self.addPatch(name);
          } else return error.UnsupportedAssignment;
        }
        return id;
      } else {
        const id = try self.emitOpWithArg(.ListAssignGlobal, n, &.{rhs_id});
        for (seq) |item| {
          if (item.* == .literal and item.literal == .@"var") {
            const name = item.literal.@"var";
            const gop = try self.globals.getOrPut(name);
            if (!gop.found_existing) {
              gop.key_ptr.* = try self.alloc.dupe(u8, name);
              gop.value_ptr.* = @intCast(self.globals.count() - 1);
            }
            const nop_id = try self.emitOpWithArg(.Nop, gop.value_ptr.*, &.{});
            const inst = self.scope.ir.get(nop_id);
            inst.arg3 = 1;
            self.scope.ir.markEffectful(nop_id);
          } else return error.UnsupportedAssignment;
        }
        return id;
      }
    }
    return ir.NO_VALUE;
  }

  fn compileTransit(self: *Compiler, t: ast.Transit, is_tail: bool) anyerror!ir.ValueId {
    if (t.v.* == .verb_op or t.v.* == .io) {
      const op = if (t.v.* == .verb_op) t.v.verb_op else t.v.io;
      if (Op.fromString(op)) |o| {
        var inputs: [2]ir.ValueId = undefined;
        inputs[0] = try self.compileNode(t.a, false);
        inputs[1] = try self.compileNode(t.b, false);
        return try self.emitOpWithArg(.Apply2, @intFromEnum(o), &inputs);
      } else if (!std.ascii.isAlphabetic(op[0])) {
        const a_id = try self.compileNode(t.a, false);
        const b_id = try self.compileNode(t.b, false);
        if (op.len > 1) {
          const res = try self.compilePrimitive(op[1..], 1, &.{b_id});
          var final_inputs: [2]ir.ValueId = undefined;
          final_inputs[0] = a_id;
          final_inputs[1] = res;
          return try self.compilePrimitive(op[0..1], 2, &final_inputs);
        }
        var inputs: [2]ir.ValueId = .{ a_id, b_id };
        return try self.compilePrimitive(op[0..1], 2, &inputs);
      }
    }

    var inputs: [3]ir.ValueId = undefined;
    inputs[0] = try self.compileNode(t.v, false);
    inputs[1] = try self.compileNode(t.a, false);
    inputs[2] = try self.compileNode(t.b, false);
    return try self.emitOpWithArg(if (is_tail) .TailCall else .Call, 2, &inputs);
  }

  fn compileIntrans(self: *Compiler, i: ast.Intrans, is_tail: bool) anyerror!ir.ValueId {
    if (i.z) |z| {
      if (i.v.* == .verb_op or i.v.* == .io) {
        const op = if (i.v.* == .verb_op) i.v.verb_op else i.v.io;
        if (Op.fromString(op)) |_| {
          var inputs: [2]ir.ValueId = undefined;
          inputs[0] = try self.compileNode(i.a, false);
          inputs[1] = try self.compileNode(z, false);
          return try self.compilePrimitive(op, 2, &inputs);
        }
      }
      var inputs: [3]ir.ValueId = undefined;
      inputs[0] = try self.compileNode(i.v, false);
      inputs[1] = try self.compileNode(i.a, false);
      inputs[2] = try self.compileNode(z, false);
      return try self.emitOpWithArg(if (is_tail) .TailCall else .Call, 2, &inputs);
    } else {
      if (i.v.* == .verb_op or i.v.* == .io) {
        const op = if (i.v.* == .verb_op) i.v.verb_op else i.v.io;
        if (Op.fromString(op)) |o| {
          // Partial dyadic symbolic or IO op: a v -> v(a, )
          const v = V{ .func = Fn.dyad(o) };
          var inputs: [2]ir.ValueId = undefined;
          inputs[0] = try self.emitConst(v);
          inputs[1] = try self.compileNode(i.a, false);
          const id = try self.emitOpWithArg(.MakePartial, 1, &inputs);
          self.scope.ir.get(id).arg2 = 1;
          return id;
        }
      }
      var inputs: [2]ir.ValueId = undefined;
      inputs[0] = try self.compileNode(i.v, false);
      inputs[1] = try self.compileNode(i.a, false);
      return try self.emitOpWithArg(if (is_tail) .TailCall else .Call, 1, &inputs);
    }
  }

  fn compilePrefix(self: *Compiler, p: ast.Prefix, is_tail: bool) anyerror!ir.ValueId {
    if (p.z) |z| {
      var inputs: [2]ir.ValueId = undefined;
      inputs[0] = try self.compileNode(p.a, false);
      inputs[1] = try self.compileNode(z, false);
      return try self.compilePrimitive(p.v, 2, &inputs);
    } else {
      const arg_id = try self.compileNode(p.a, false);
      if (Op.fromString(p.v)) |_| {
        return try self.compilePrimitive(p.v, 1, &.{arg_id});
      } else if (std.ascii.isAlphabetic(p.v[0])) {
        const v: V = if (Op.fromString(p.v)) |o| .{ .func = Fn.dyad(o) } else .{ .func = Fn.makeTrain(p.v) };
        var inputs: [2]ir.ValueId = undefined;
        inputs[0] = try self.emitConst(v);
        inputs[1] = arg_id;
        return try self.emitOpWithArg(if (is_tail) .TailCall else .Call, 1, &inputs);
      } else {
        return try self.compilePrimitive(p.v, 1, &.{arg_id});
      }
    }
  }

  fn compileCompose(self: *Compiler, c: ast.Compose) anyerror!ir.ValueId {
    return switch (c) {
      .v => |v| try self.compileNode(v, false),
      .fz => |fz| blk: {
        _ = try self.compileNode(fz.f, false);
        break :blk try self.compileNode(fz.z, false);
      },
    };
  }

  fn compileApposit(self: *Compiler, ap: ast.Apposit, is_tail: bool) anyerror!ir.ValueId {
    // When both sides are single-char verb ops, build a train (composition) constant.
    var ops_buf: [7]u8 = undefined;
    var ops_len: usize = 0;
    if (collectVerbOps(ap.f, &ops_buf, &ops_len) and collectVerbOps(ap.a, &ops_buf, &ops_len)) {
      const v = V{ .func = Fn.makeTrain(ops_buf[0..ops_len]) };
      return try self.emitConst(v);
    }
    var inputs: [2]ir.ValueId = undefined;
    inputs[0] = try self.compileNode(ap.f, false);
    inputs[1] = try self.compileNode(ap.a, false);
    return try self.emitOpWithArg(if (is_tail) .TailCall else .Call, 1, &inputs);
  }

  // Collects single-char op bytes from a verb_op node or nested apposit of verb_ops.
  // Returns true if the entire subtree consists of single-char verb ops, false otherwise.
  fn collectVerbOps(node: *ast.Node, buf: []u8, pos: *usize) bool {
    switch (node.*) {
      .verb_op => |op| {
        if (op.len == 1 and pos.* < buf.len) {
          buf[pos.*] = op[0];
          pos.* += 1;
          return true;
        }
        return false;
      },
      .apposit => |ap| return collectVerbOps(ap.f, buf, pos) and collectVerbOps(ap.a, buf, pos),
      else => return false,
    }
  }

  fn adverbFromString(a: []const u8) Adverb {
    if (std.mem.eql(u8, a, "'")) return .@"'"
    else if (std.mem.eql(u8, a, "/")) return .@"/"
    else if (std.mem.eql(u8, a, "\\")) return .@"\\"
    else if (std.mem.eql(u8, a, "':")) return .@"':"
    else if (std.mem.eql(u8, a, "/:")) return .@"/:"
    else if (std.mem.eql(u8, a, "\\:")) return .@"\\:"
    else unreachable;
  }

  fn compileTerm(self: *Compiler, t: ast.Term) anyerror!ir.ValueId {
    const f_id = try self.compileNode(t.f, false);
    const adv = adverbFromString(t.a);
    return try self.emitOpWithArg(.Derive, @intFromEnum(adv), &.{f_id});
  }

  fn compilePrimitive(self: *Compiler, name: []const u8, arity_val: u8, inputs: []const ir.ValueId) anyerror!ir.ValueId {
    if (Op.fromString(name)) |op| {
      return try self.emitOpWithArg(if (arity_val == 1) .Apply1 else .Apply2, @intFromEnum(op), inputs);
    } else {
      const v = V{ .func = Fn.makeTrain(name) };
      const f_id = try self.emitConst(v);
      var call_inputs = try std.ArrayList(ir.ValueId).initCapacity(self.alloc, inputs.len + 1);
      defer call_inputs.deinit(self.alloc);
      try call_inputs.append(self.alloc, f_id);
      for (inputs) |input| try call_inputs.append(self.alloc, input);
      return try self.emitOpWithArg(.Apply, arity_val, call_inputs.items);
    }
  }

  fn compileLambda(self: *Compiler, l: ast.Lambda) anyerror!ir.ValueId {
    const chunk_ptr = try self.alloc.create(Chunk);
    chunk_ptr.* = try Chunk.init(self.alloc);
    var chunk_owned = true;
    errdefer if (chunk_owned) { chunk_ptr.deinit(); self.alloc.destroy(chunk_ptr); };

    const scope_ptr = try self.alloc.create(Scope);
    scope_ptr.* = try Scope.init(self.alloc, chunk_ptr, self.scope);
    scope_ptr.is_lambda = true;
    scope_ptr.named_args = l.a;
    var scope_owned = true;
    errdefer if (scope_owned) { scope_ptr.deinit(); self.alloc.destroy(scope_ptr); };

    const arity_res = blk: {
      const old_scope = self.scope;
      const old_chunk = self.chunk;
      self.scope = scope_ptr;
      self.chunk = chunk_ptr;
      defer {
        self.scope = old_scope;
        self.chunk = old_chunk;
      }

      if (l.b) |seq| {
        var last: ir.ValueId = ir.NO_VALUE;
        var end = seq.len;
        while (end > 0 and seq[end - 1].* == .blank) end -= 1;
        const stmts = seq[0..end];
        for (stmts, 0..) |stmt, idx| {
          const val = try self.compileNode(stmt, idx == stmts.len - 1);
          if (idx < stmts.len - 1) {
            if (val != ir.NO_VALUE) _ = try self.emitOp(.Drop, &.{val});
          } else {
            last = val;
          }
        }
        _ = try self.emitOp(.Return, &.{last});
      } else {
        const id = try self.emitOp(.Gap, &.{});
        _ = try self.emitOp(.Return, &.{id});
      }

      const a = scope_ptr.arity();
      for (scope_ptr.patches.items) |patch| {
        const inst = &scope_ptr.ir.instructions.items[patch.instruction_idx];
        if (l.a) |args| {
          var found = false;
          for (args, 0..) |arg, i| {
            if (arg.is_some and std.mem.eql(u8, arg.value, patch.name)) {
              inst.arg1 = @intCast(i);
              found = true;
              break;
            }
          }
          if (found) continue;
        } else {
          if (std.mem.eql(u8, patch.name, "x")) { inst.arg1 = 0; continue; }
          else if (std.mem.eql(u8, patch.name, "y")) { inst.arg1 = 1; continue; }
          else if (std.mem.eql(u8, patch.name, "z")) { inst.arg1 = 2; continue; }
        }

        var local_idx: u8 = a;
        var found_local = false;
        var it = scope_ptr.locals.iterator();
        while (it.next()) |entry| {
          if (std.mem.eql(u8, entry.key_ptr.*, patch.name)) {
            inst.arg1 = local_idx;
            found_local = true;
            break;
          }
          local_idx += 1;
        }

        if (!found_local) {
          inst.op = .Global;
          if (self.globals.get(patch.name)) |idx| {
            inst.arg1 = idx;
          } else {
            const idx = @as(u8, @intCast(self.globals.count()));
            try self.globals.put(try self.alloc.dupe(u8, patch.name), idx);
            inst.arg1 = idx;
          }
        }
      }

      var opt = optimizer.Optimizer.init(self.alloc);
      const root_id = if (scope_ptr.ir.instructions.items.len > 0) @as(ir.ValueId, @intCast(scope_ptr.ir.instructions.items.len - 1)) else ir.NO_VALUE;
      try opt.optimize(&scope_ptr.ir, root_id);
      _ = try opt.inlineLambdas(&scope_ptr.ir, self.fn_tables);
      try opt.optimize(&scope_ptr.ir, root_id);
      try opt.livenessLocals(&scope_ptr.ir);
      try self.lower();
      break :blk a;
    };

    const locals_count = @as(u8, @intCast(scope_ptr.locals.count()));
    scope_ptr.deinit();
    self.alloc.destroy(scope_ptr);
    scope_owned = false;

    const range_id = try self.registry.addRange(self.text_id, l.start, l.end);
    const lambda_idx = try self.fn_tables.addLambda(.{
      .arity  = arity_res,
      .locals = locals_count,
      .chunk  = chunk_ptr,
      .range  = range_id,
    });
    chunk_owned = false;
    return try self.emitConst(V{ .func = Fn.lambda(lambda_idx, arity_res) });
  }

  fn compileCond(self: *Compiler, c: ast.Cond, is_tail: bool) anyerror!ir.ValueId {
    const stmts = c.stmts;
    const jump_count = stmts.len / 2;
    const end_jumps = try self.alloc.alloc(usize, jump_count);
    defer self.alloc.free(end_jumps);

    var res_ids = try std.ArrayList(ir.ValueId).initCapacity(self.alloc, jump_count + 1);
    defer res_ids.deinit(self.alloc);

    var i: usize = 0;
    var j: usize = 0;
    var res: ir.ValueId = ir.NO_VALUE;
    while (i + 1 < stmts.len) : (i += 2) {
      const cond_id = try self.compileNode(stmts[i], false);
      const false_jump = try self.emitJump(.JumpFalse, &.{cond_id});
      res = try self.compileNode(stmts[i + 1], is_tail);
      try res_ids.append(self.alloc, res);
      end_jumps[j] = try self.emitJump(.Jump, &.{res});
      j += 1;
      try self.patchJump(false_jump);
    }

    res = if (i < stmts.len) try self.compileNode(stmts[i], is_tail)
          else try self.emitOp(.Gap, &.{});
    
    try res_ids.append(self.alloc, res);

    for (end_jumps[0..j]) |jump| try self.patchJump(jump);
    return try self.emitOp(.Nop, res_ids.items);
  }

  fn emitJump(self: *Compiler, op: OpCode, inputs: []const ir.ValueId) anyerror!usize {
    const idx = self.scope.ir.instructions.items.len;
    _ = try self.emitOpWithArg(op, 0xffff, inputs);
    return idx;
  }

  fn patchJump(self: *Compiler, idx: usize) !void {
    self.scope.ir.instructions.items[idx].arg1 = @intCast(self.scope.ir.instructions.items.len);
  }

  fn emitOp(self: *Compiler, op: OpCode, inputs: []const ir.ValueId) !ir.ValueId {
    return try self.scope.ir.emit(op, inputs);
  }

  fn emitOpWithArg(self: *Compiler, op: OpCode, arg: u32, inputs: []const ir.ValueId) !ir.ValueId {
    return try self.scope.ir.emitWithArg(op, arg, inputs);
  }

  fn emitConst(self: *Compiler, val: V) !ir.ValueId {
    return try self.scope.ir.emitConstant(val);
  }

  fn addPatch(self: *Compiler, name: []const u8) !void {
    try self.scope.patches.append(self.alloc, .{
      .instruction_idx = self.scope.ir.instructions.items.len - 1,
      .name = name,
    });
  }

  pub fn lower(self: *Compiler) !void {
    const scope = self.scope;
    if (scope.ir.instructions.items.len == 0) return;

    const offsets = try self.alloc.alloc(usize, scope.ir.instructions.items.len + 1);
    defer self.alloc.free(offsets);

    var current_offset: usize = 0;
    for (scope.ir.instructions.items, 0..) |inst, i| {
      offsets[i] = current_offset;
      if (inst.is_dead) continue;
      current_offset += self.instSize(inst);
    }
    offsets[scope.ir.instructions.items.len] = current_offset;

    for (scope.ir.instructions.items, 0..) |inst, i| {
      if (inst.is_dead) continue;
      try self.lowerInst(scope.chunk, inst, i, offsets);
    }
    try scope.chunk.buildBlocks();
  }

  fn instSize(self: *Compiler, inst: ir.IRInst) usize {
    switch (inst.op) {
      .Nop => return if (inst.arg3 == 1) 1 else 0,
      .Const => {
        // Small i32 constants are emitted as the 3-byte Int opcode.
        if (inst.val) |v| {
          if (v == .i and v.i >= std.math.minInt(i16) and v.i <= std.math.maxInt(i16)) return 3;
        }
        return 2;
      },
      .Local, .Global, .AssignLocal, .AssignGlobal,
      .Call, .TailCall, .Apply1, .Apply2, .Apply,
      .MakeList, .MakeDict, .MakeTable, .Derive, .Amend, .Dmend,
      .ListAssignLocal, .ListAssignGlobal => return 2,
      .Drop => {
        if (inst.inputs.len > 0 and inst.inputs[0] != ir.NO_VALUE and !self.scope.ir.get(inst.inputs[0]).is_dead) return 1;
        return 0;
      },
      .Jump, .JumpFalse, .JumpTrue => return 3,
      .MakePartial => return 3,
      else => return 1,
    }
  }

  fn lowerInst(self: *Compiler, chunk: *Chunk, inst: ir.IRInst, idx: usize, offsets: []usize) !void {
    if (inst.op == .Nop and inst.arg3 == 1) {
      try chunk.write(@as(u8, @intCast(inst.arg1)));
      return;
    } else if (inst.op == .Nop) {
      return;
    }

    if (inst.op == .Drop) {
      if (inst.inputs.len == 0 or inst.inputs[0] == ir.NO_VALUE or self.scope.ir.get(inst.inputs[0]).is_dead) return;
    }

    // Small i32 constants: emit Int opcode + inline i16 instead of Const + pool index.
    if (inst.op == .Const) {
      if (inst.val) |v| {
        if (v == .i and v.i >= std.math.minInt(i16) and v.i <= std.math.maxInt(i16)) {
          try chunk.writeOp(.Int);
          try chunk.write16(@as(u16, @bitCast(@as(i16, @intCast(v.i)))));
          return;
        }
      }
      try chunk.writeOp(.Const);
      const c_idx = try chunk.addConstant(inst.val.?.ref());
      try chunk.write(c_idx);
      return;
    }

    // Last-use local: emit LocalLast so the VM can steal the slot.
    const effective_op: OpCode = if (inst.is_last and inst.op == .Local) .LocalLast else inst.op;

    try chunk.writeOp(effective_op);
    switch (effective_op) {
      .Local, .LocalLast, .Global, .AssignLocal, .AssignGlobal, .Call, .TailCall, .Apply1, .Apply2, .Apply,
      .MakeList, .MakeDict, .MakeTable, .Derive, .Amend, .Dmend, .ListAssignLocal, .ListAssignGlobal => {
        try chunk.write(@as(u8, @intCast(inst.arg1)));
      },
      .Drop => {},
      .Jump, .JumpFalse, .JumpTrue => {
        const target_ir_idx = inst.arg1;
        const target_offset = offsets[target_ir_idx];
        const current_offset = offsets[idx];
        const jump_size: i32 = @as(i32, @intCast(target_offset)) - @as(i32, @intCast(current_offset + 3));
        try chunk.write16(@as(u16, @bitCast(@as(i16, @intCast(jump_size)))));
      },
      .MakePartial => {
        try chunk.write(@as(u8, @intCast(inst.arg1)));
        try chunk.write(@as(u8, @intCast(inst.arg2)));
      },
      else => {},
    }
  }
};

const PatchInfo = struct {
  instruction_idx: usize,
  name: []const u8,
};

const Scope = struct {
  alloc: Alloc,
  parent: ?*Scope,
  chunk: *Chunk,
  ir: ir.IR,
  locals: std.StringHashMap(u8),
  patches: std.ArrayList(PatchInfo),
  inline_args: ?[]ir.ValueId = null,

  is_lambda: bool = false,
  named_args: ?ast.Args = null,
  uses_x: bool = false,
  uses_y: bool = false,
  uses_z: bool = false,

  pub fn init(alloc: Alloc, chunk: *Chunk, parent: ?*Scope) !Scope {
    return .{
      .alloc = alloc,
      .parent = parent,
      .chunk = chunk,
      .ir = try ir.IR.init(alloc),
      .locals = std.StringHashMap(u8).init(alloc),
      .patches = try std.ArrayList(PatchInfo).initCapacity(alloc, 0),
    };
  }

  pub fn deinit(self: *Scope) void {
    self.ir.deinit();
    self.locals.deinit();
    self.patches.deinit(self.alloc);
  }

  pub fn reset(self: *Scope) void {
    self.ir.reset();
    self.locals.clearRetainingCapacity();
    self.patches.clearRetainingCapacity();
    self.uses_x = false;
    self.uses_y = false;
    self.uses_z = false;
  }

  fn arity(self: *Scope) u8 {
    if (self.named_args) |args| return @intCast(args.len);
    if (self.uses_z) return 3;
    if (self.uses_y) return 2;
    if (self.uses_x) return 1;
    return 0;
  }
};
