const std = @import("std");
const ast = @import("../parser/ast.zig");
const value = @import("../noun/value.zig");
const opmod = @import("../noun/operator.zig");
const Adverb = opmod.Adverb;
const Op1 = opmod.Op1;
const Op2 = opmod.Op2;
const intrinsic = @import("../primitive/intrinsic.zig");
const Op3 = opmod.Op3;
const Op4 = opmod.Op4;
const ir = @import("ir.zig");
const fntable = @import("../runtime/fntable.zig");
const V = value.V;
const N = @import("../noun/array.zig").N;
const Fn = opmod.Fn;
const Alloc = std.mem.Allocator;
const Chunk = @import("../runtime/tape.zig").Chunk;
const OpCode = @import("../runtime/tape.zig").OpCode;
const KOp = @import("../runtime/tape.zig").KOp;
const KInsn = @import("../runtime/tape.zig").KInsn;
const Pool = @import("../noun/symbol.zig").Pool;
const Fs = @import("../runtime/registry.zig").Fs;
const fold_mod = @import("../primitive/adverb/fold.zig");

// Strip the common leading indentation (spaces/tabs) from every line of a
// multi-line string body. Blank lines don't count toward the common indent and
// have their (partial) indentation removed. Returns a freshly allocated buffer.
fn dedent(alloc: Alloc, s: []const u8) anyerror![]u8 {
  const indentOf = struct {
    fn f(line: []const u8) ?usize {
      var n: usize = 0;
      while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
      return if (n == line.len) null else n; // null = blank line
    }
  }.f;
  var min: usize = std.math.maxInt(usize);
  var it = std.mem.splitScalar(u8, s, '\n');
  while (it.next()) |line| {
    if (indentOf(line)) |n| min = @min(min, n);
  }
  if (min == std.math.maxInt(usize)) min = 0; // all blank
  var out = try std.ArrayList(u8).initCapacity(alloc, s.len);
  errdefer out.deinit(alloc);
  var lines = std.mem.splitScalar(u8, s, '\n');
  var first = true;
  while (lines.next()) |line| {
    if (!first) out.appendAssumeCapacity('\n');
    first = false;
    const cut = @min(min, line.len);
    out.appendSliceAssumeCapacity(line[cut..]);
  }
  return out.toOwnedSlice(alloc);
}

// Public/private policy for one namespace declared with `\d ns [pub ...]`.
// `all_public` (bare `\d ns`) exports every member; otherwise only the names in
// `publics` are reachable from outside the namespace. Keys are interned symbol
// slices (stable, pool-owned), so the maps never free their own keys.
const NsPolicy = struct {
  all_public: bool,
  publics: std.StringHashMap(void),
};

pub const Compiler = struct {
  alloc: Alloc,
  chunk: *Chunk,
  globals: *std.StringHashMap(u16),
  symbols: *Pool,
  registry: *Fs,
  fn_tables: *fntable.FnTables,
  scope: *Scope,
  text_id: u32 = 0,
  // Namespaces (`\d`). Compile-time only — resolution mangles names to global
  // keys (`ns.member`) so there is zero runtime cost. `namespace` is the active
  // namespace (interned, stable; null = global scope) and persists across
  // separate compiles (REPL lines) since the Compiler outlives them.
  namespace: ?[]const u8 = null,
  // Implicit function namespace. While compiling a lambda BOUND to name `F`, this
  // is set to `F` (its fully-qualified assign name), so a bare reference in the
  // body resolves to the member `F.that` when such a global exists — e.g. inside
  // `group` a bare `expand` reaches `group.expand`. Distinct from `\d`: it affects
  // REFERENCE resolution only (never assignment), and only captures a name when the
  // qualified member actually exists, so it never shadows an unrelated global.
  fn_namespace: ?[]const u8 = null,
  namespaces: std.StringHashMap(NsPolicy),
  // Fully-qualified names (`ns.member`, interned) declared private by their
  // namespace's policy. Referenced from outside their namespace → compile error.
  private_members: std.StringHashMap(void),
  // Level-B monomorphic call-site opt. A name bound at GLOBAL scope with a SINGLE
  // colon (`:` = constant) to a trivial monadic intrinsic wrapper `{`sin x}` is an
  // alias for that opcode; recorded here name→Op1. A reference `sin y` then lowers
  // straight to Apply1(Op1.sin) (fusable) instead of a lambda call. A `::`
  // (double-bind = variable) or any non-matching rebind clears the entry, and a
  // local/param of the same name is skipped — so user shadowing is respected. This
  // is the payoff of the strict single/double-bind = constant/variable rule.
  intrinsic_alias: std.StringHashMap(Op1),
  // General `:`-constant propagation. A GLOBAL-scope SINGLE-bind (`:` = constant) to
  // a pure LITERAL (scalar / vector / string / symbol — not a var or expression) is
  // recorded name→its RHS ast node. A reference to that name then re-emits the literal
  // inline instead of a Global load, so downstream arithmetic constant-folds and const
  // scalars bake into fused kernels. A `::` (variable), a compound/indexed rebind, or a
  // non-literal rhs clears the entry; a local/param of the same name is skipped. Keys
  // are interned (stable); VALUES are ast nodes owned by the CURRENT unit's tree, so
  // the map is cleared at the start of every top-level compile (see compile()).
  // Relies on the single/double-bind contract: a `:`-global is never reassigned.
  const_globals: std.StringHashMap(*ast.Node),
  // Names mutated somewhere in the current unit — assigned with `::` (variable) or via
  // an indexed lvalue (`d[i]:…`), possibly INSIDE a lambda. Such a name is never a true
  // constant even if some top-level `:` binds it (real code writes `a:1; {a::2}[]; a`),
  // so it is excluded from const_globals / intrinsic_alias. Recomputed per unit by
  // collectMutated at the start of compile().
  mutated: std.StringHashMap(void),

  pub fn init(alloc: Alloc, chunk: *Chunk, globals: *std.StringHashMap(u16), symbols: *Pool, registry: *Fs, fn_tables: *fntable.FnTables) !Compiler {
    const scope = try alloc.create(Scope);
    scope.* = Scope.init(alloc, chunk, null);
    return .{
      .alloc = alloc,
      .chunk = chunk,
      .globals = globals,
      .symbols = symbols,
      .registry = registry,
      .fn_tables = fn_tables,
      .scope = scope,
      .namespaces = std.StringHashMap(NsPolicy).init(alloc),
      .private_members = std.StringHashMap(void).init(alloc),
      .intrinsic_alias = std.StringHashMap(Op1).init(alloc),
      .const_globals = std.StringHashMap(*ast.Node).init(alloc),
      .mutated = std.StringHashMap(void).init(alloc),
    };
  }

  pub fn deinit(self: *Compiler) void {
    self.mutated.deinit();
    self.const_globals.deinit();
    self.intrinsic_alias.deinit();
    var curr: ?*Scope = self.scope;
    while (curr) |s| {
      const parent = s.parent;
      s.deinit();
      self.alloc.destroy(s);
      curr = parent;
    }
    var nit = self.namespaces.valueIterator();
    while (nit.next()) |p| p.publics.deinit();
    self.namespaces.deinit();
    self.private_members.deinit();
  }

  pub fn compile(self: *Compiler, node: *ast.Node, is_tail: bool) anyerror!void {
    // const_globals values are ast nodes owned by THIS unit's tree (freed after);
    // drop last unit's entries so a later reference can't read a stale node. Then
    // find every name mutated in this unit (`::` / indexed, even inside a lambda) so
    // constant propagation excludes them.
    self.const_globals.clearRetainingCapacity();
    self.mutated.clearRetainingCapacity();
    try self.collectMutated(node);
    // Pre-register the namespace members assigned in this compilation unit so
    // forward/self/mutual references (recursion inside `\d ns`) resolve to the
    // member rather than falling back to a blank global. See prescanMembers.
    if (node.* == .terse) {
      try self.prescanMembers(node.terse.stmts);
      try self.prescanGlobals(node.terse.stmts);
    }
    const root_id = try self.compileNode(node, is_tail);
    if (self.scope.parent == null) {
      try self.runOptimizer(&self.scope.ir, root_id);
      try self.lower();
    }
  }

  // Mark the base variable(s) of a target expression as mutated: a plain var, the
  // base of an `.apply` index chain, or every element of a `(a;b;…)` destructure.
  fn markTargetVars(self: *Compiler, v: *ast.Node) anyerror!void {
    switch (v.*) {
      .literal => if (v.literal == .@"var") try self.mutated.put(try self.interned(v.literal.@"var"), {}),
      .apply => { var n = v; while (n.* == .apply) n = n.apply.f; try self.markTargetVars(n); },
      .list => if (v.list.seq) |seq| for (seq) |it| try self.markTargetVars(it),
      else => {},
    }
  }

  // A bind mutates its target (so the target is not a foldable constant) when it is a
  // `::` double-bind (variable; rhs wrapped in `.right`), an indexed lvalue (`d[i]:…`,
  // target is an `.apply` chain), or a COMPOUND assign (`op:` reads then writes). A
  // plain `:` scalar/destructure rebind is handled in-order at its site instead.
  fn markMutation(self: *Compiler, v: *ast.Node, f: ?ast.Op, a: ?*ast.Node) !void {
    const is_double = a != null and a.?.* == .right;
    const is_indexed = v.* == .apply;
    const is_compound = f != null and !std.mem.eql(u8, f.?, ":");
    if (!is_double and !is_indexed and !is_compound) return;
    try self.markTargetVars(v);
  }

  // Walk the whole unit collecting names mutated via `::` / indexed assignment,
  // descending into lambda bodies and every other node that can hold a bind, so a
  // later constant-propagation of a name the program actually mutates is impossible.
  fn collectMutated(self: *Compiler, node: *ast.Node) anyerror!void {
    switch (node.*) {
      .terse => |t| for (t.stmts) |s| try self.collectMutated(s.node),
      .verb, .stmt_clause, .stmt_adjunct, .phrase, .noun, .phrase_verb => |c| try self.collectMutated(c),
      .right => |r| try self.collectMutated(r.clause),
      .@"defer" => |d| try self.collectMutated(d.adjunct),
      .group => |g| try self.collectMutated(g.stmt),
      .term => |tm| try self.collectMutated(tm.f),
      .transit => |tr| { try self.collectMutated(tr.a); try self.collectMutated(tr.v); try self.collectMutated(tr.b); },
      .affix => |af| { try self.collectMutated(af.a); try self.collectMutated(af.b); },
      .apposit => |ap| { try self.collectMutated(ap.f); try self.collectMutated(ap.a); },
      .intrans => |i| { try self.collectMutated(i.a); try self.collectMutated(i.v); if (i.z) |z| try self.collectMutated(z); },
      .prefix => |p| { try self.collectMutated(p.a); if (p.z) |z| try self.collectMutated(z); },
      .compose => |c| switch (c) { .v => |v| try self.collectMutated(v), .fz => |fz| { try self.collectMutated(fz.f); try self.collectMutated(fz.z); } },
      .apply => |ap| { try self.collectMutated(ap.f); if (ap.a) |seq| for (seq) |x| try self.collectMutated(x); },
      .list => |l| if (l.seq) |seq| for (seq) |x| try self.collectMutated(x),
      .lambda => |lm| if (lm.b) |seq| for (seq) |x| try self.collectMutated(x),
      .cond => |cd| for (cd.stmts) |x| try self.collectMutated(x),
      .dict, .table => |d| if (d.items) |items| for (items) |it| try self.collectMutated(it.v),
      .utable => |u| { if (u.keys) |k| for (k) |it| try self.collectMutated(it.v); if (u.items) |i| for (i) |it| try self.collectMutated(it.v); },
      .bind => |b| { try self.markMutation(b.v, b.f, b.a); if (b.a) |a| try self.collectMutated(a); try self.collectMutated(b.v); },
      .pending => |p| { try self.markMutation(p.v, p.f, p.a); try self.collectMutated(p.a); try self.collectMutated(p.v); },
      else => {}, // literal, op, io, blank, monad, adverb_val, command — no child binds
    }
  }

  // Walk the top-level statements, tracking `\d` transitions, and pre-create a
  // global slot for every `ns.member` assigned here. resolveGlobalRef then sees
  // the member as existing even when referenced before its definition, so a
  // recursive `f:{…f…}` (or mutually recursive pair) inside a namespace binds to
  // `ns.f` instead of a blank global.  Only bare (undotted) assignment targets
  // become members; anything else keeps its normal global/namespace resolution.
  fn prescanMembers(self: *Compiler, stmts: []ast.Stmt) !void {
    var ns: ?[]const u8 = self.namespace;
    for (stmts) |stmt| {
      switch (stmt.node.*) {
        .command => |cmd| {
          if (std.mem.eql(u8, cmd.verb, "d")) {
            const t = std.mem.trim(u8, cmd.args, " \t");
            if (t.len == 0) ns = null else {
              var it = std.mem.tokenizeAny(u8, t, " \t");
              ns = try self.interned(it.next().?);
            }
          }
        },
        .bind => |b| try self.prescanTarget(b.v, ns),
        .pending => |p| try self.prescanTarget(p.v, ns),
        else => {},
      }
    }
  }

  // Register the assignment target(s) in `v` (a plain var or a `(a;b;…)` list
  // destructuring) as members of namespace `ns`, if any.
  fn prescanTarget(self: *Compiler, v: *ast.Node, ns: ?[]const u8) !void {
    const namespace = ns orelse return;
    if (v.* == .literal and v.literal == .@"var") {
      const name = v.literal.@"var";
      if (nsOf(name) == null) _ = try self.getOrAddGlobal(try self.qualify(namespace, name));
    } else if (v.* == .list) {
      if (v.list.seq) |seq| for (seq) |item| {
        if (item.* == .literal and item.literal == .@"var") {
          const name = item.literal.@"var";
          if (nsOf(name) == null) _ = try self.getOrAddGlobal(try self.qualify(namespace, name));
        }
      };
    }
  }

  // Whole-file prescan: pre-register a global slot for every top-level assignment
  // target that is *qualified* (a dotted name, or a bare name inside `\d ns`),
  // tracking `\d` across the statement list. Scripts compile statement-by-statement
  // (repl.evalStream), so the per-unit prescanMembers only ever sees one statement;
  // running this over the WHOLE parsed file first makes a qualified reference that
  // precedes its definition resolve to the right member — the basis for both
  // order-independent defs and implicit-function-namespace lookup (fn_namespace).
  pub fn prescanGlobals(self: *Compiler, stmts: []ast.Stmt) !void {
    var ns: ?[]const u8 = self.namespace;
    for (stmts) |stmt| {
      switch (stmt.node.*) {
        .command => |cmd| {
          if (std.mem.eql(u8, cmd.verb, "d")) {
            const t = std.mem.trim(u8, cmd.args, " \t");
            if (t.len == 0) ns = null else {
              var it = std.mem.tokenizeAny(u8, t, " \t");
              ns = try self.interned(it.next().?);
            }
          }
        },
        .bind => |b| try self.prescanGlobalTarget(b.v, ns),
        .pending => |p| try self.prescanGlobalTarget(p.v, ns),
        else => {},
      }
    }
  }

  fn prescanGlobalTarget(self: *Compiler, v: *ast.Node, ns: ?[]const u8) !void {
    if (v.* == .literal and v.literal == .@"var") {
      try self.prescanQualified(v.literal.@"var", ns);
    } else if (v.* == .list) {
      if (v.list.seq) |seq| for (seq) |item| {
        if (item.* == .literal and item.literal == .@"var")
          try self.prescanQualified(item.literal.@"var", ns);
      };
    }
  }

  // Register the slot only for a name that resolves to a qualified member (dotted,
  // or bare inside a namespace). Plain global names already resolve lazily on first
  // reference, so pre-registering them would change nothing — skip to stay minimal.
  fn prescanQualified(self: *Compiler, name: []const u8, ns: ?[]const u8) !void {
    if (nsOf(name) != null) { _ = try self.getOrAddGlobal(try self.interned(name)); return; }
    if (ns) |n| { _ = try self.getOrAddGlobal(try self.qualify(n, name)); }
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
      .dict => |d| try self.compileDict(d, false),
      .table => |t| try self.compileDict(t, true),
      .utable => |u| try self.compileUTable(u),
      .pending => |p| try self.compileBind(.{ .v = p.v, .f = p.f, .a = p.a }),
      .op => |op| blk: {
        // op used as a value: prefer Op2 (dyadic) form so polymorphic
        // calls can fall back to Op1 via op2ToOp1 when invoked with 1 arg.
        // For Op1-only verbs (e.g. "sqrt", "first"), build a monadic Fn.
        const v: V = if (Op2.fromString(op)) |o|
          .{ .o = Fn.dyad(o) }
        else if (Op1.fromString(op)) |o|
          .{ .o = Fn.monad(o) }
        else
          .{ .o = Fn.makeTrain(op) };
        break :blk try self.emitConst(v);
      },
      .io => |io| blk: {
        const op = Op2.fromString(io) orelse return error.UnknownOp;
        break :blk try self.emitConst(V{ .o = Fn.dyad(op) });
      },
      .monad => |mv| blk: {
        const op = Op1.fromString(mv.f) orelse return error.UnknownOp;
        break :blk try self.emitConst(V{ .o = Fn.monad(op) });
      },
      .adverb_val => |a| try self.emitConst(V{ .o = Fn.adverb(adverbFromString(a)) }),
      .command => |cmd| blk: {
        // `\d` switches the compile-time namespace (see setNamespace); it has no
        // runtime effect, so it lowers to a blank rather than a Command opcode.
        if (std.mem.eql(u8, cmd.verb, "d")) {
          try self.setNamespace(cmd.args);
          break :blk try self.emitOp(.Gap, &.{});
        }
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
    const seq = l.seq orelse return try self.emitOpWithArg(.MakeList, 0, &.{});
    var inputs: std.ArrayList(ir.ValueId) = .empty;
    defer inputs.deinit(self.alloc);
    for (seq) |x| try inputs.append(self.alloc, try self.compileNode(x, false));
    return try self.emitOpWithArg(.MakeList, @intCast(seq.len), inputs.items);
  }

  // Dict/table literals lower to the dict verb `!` (and `+` flip for tables)
  // rather than dedicated opcodes:
  //   [a:1;b:2]   →  `a`b ! (1;2)
  //   [[]a:1 2]   →  + (`a ! 1 2)
  // n==1 keeps the key/value scalar (matching `s!v`); n>1 builds the key and
  // value lists with MakeList so they promote exactly as the old opcode did.
  fn compileDict(self: *Compiler, d: ast.Dict, is_table: bool) anyerror!ir.ValueId {
    const n = if (d.items) |items| items.len else 0;

    var dict_id: ir.ValueId = undefined;
    if (n == 0) {
      // [] → ()!() : empty keys keyed to empty values.
      const keys_id = try self.emitOpWithArg(.MakeList, 0, &.{});
      const vals_id = try self.emitOpWithArg(.MakeList, 0, &.{});
      var pair = [_]ir.ValueId{ keys_id, vals_id };
      dict_id = try self.emitOpWithArg(.Apply2, @intFromEnum(Op2.@"!"), &pair);
    } else {
      dict_id = try self.compileDictItems(d.items.?, n);
    }

    if (is_table) {
      var finputs = [_]ir.ValueId{dict_id};
      return try self.emitOpWithArg(.Apply1, @intFromEnum(Op1.@"+"), &finputs);
    }
    return dict_id;
  }

  fn compileDictItems(self: *Compiler, items: ast.Items, n: usize) anyerror!ir.ValueId {
    var dict_id: ir.ValueId = undefined;
    if (n == 1) {
      const key_id = try self.emitConst(.{ .s = try self.symbols.intern(items[0].k) });
      const val_id = try self.compileNode(items[0].v, false);
      var pair = [_]ir.ValueId{ key_id, val_id };
      dict_id = try self.emitOpWithArg(.Apply2, @intFromEnum(Op2.@"!"), &pair);
    } else {
      var kinputs: std.ArrayList(ir.ValueId) = .empty;
      defer kinputs.deinit(self.alloc);
      for (items) |item|
        try kinputs.append(self.alloc, try self.emitConst(.{ .s = try self.symbols.intern(item.k) }));
      const keys_id = try self.emitOpWithArg(.MakeList, @intCast(n), kinputs.items);

      var vinputs: std.ArrayList(ir.ValueId) = .empty;
      defer vinputs.deinit(self.alloc);
      for (items) |item|
        try vinputs.append(self.alloc, try self.compileNode(item.v, false));
      const vals_id = try self.emitOpWithArg(.MakeList, @intCast(n), vinputs.items);

      var pair = [_]ir.ValueId{ keys_id, vals_id };
      dict_id = try self.emitOpWithArg(.Apply2, @intFromEnum(Op2.@"!"), &pair);
    }
    return dict_id;
  }

  fn compileUTable(self: *Compiler, u: ast.UTable) anyerror!ir.ValueId {
    // [[keys][vals]] — each half is a flipped dict (table), then keyed with !
    const keys_id = try self.compileDict(.{ .items = u.keys }, true);
    if (keys_id == ir.NO_VALUE) return ir.NO_VALUE;
    const vals_id = try self.compileDict(.{ .items = u.items }, true);
    if (vals_id == ir.NO_VALUE) return ir.NO_VALUE;
    var pair = [_]ir.ValueId{ keys_id, vals_id };
    return try self.emitOpWithArg(.Apply2, @intFromEnum(Op2.@"!"), &pair);
  }

  fn compileApply(self: *Compiler, ap: ast.Apply, is_tail: bool) anyerror!ir.ValueId {
    const seq = if (ap.a) |s| s else &[_]*ast.Node{};
    const n: u8 = @intCast(seq.len);

    // Monomorphic intrinsic call site: a literal intrinsic SYMBOL applied directly
    // (`` `sin x `` — which is exactly what the lib/prelude.k bodies `{`sin x}`
    // compile to) lowers straight to the Op1/Op2 kernel. That is fusable by the
    // optimizer, and it skips both the syms.apply string-match and the buggy
    // `@`(symbol, int-scalar) dispatch (.plan/triage.md). A literal symbol can't be
    // shadowed, so this needs no scope analysis. See src/primitive/intrinsic.zig.
    if (n == 1 and ap.f.* == .literal and ap.f.literal == .@"var") {
      const nm = ap.f.literal.@"var";
      if (!self.isLocalName(nm) and !self.hasFnMember(nm)) if (self.intrinsic_alias.get(nm)) |o1| {
        const a = try self.compileNode(seq[0], false);
        return try self.emitOpWithArg(.Apply1, @intFromEnum(o1), &.{a});
      };
    }
    if (ap.f.* == .literal and ap.f.literal == .s) {
      if (intrinsic.find(ap.f.literal.s)) |ic| {
        if (n == 1) {
          if (ic.op1) |o1| {
            const a = try self.compileNode(seq[0], false);
            return try self.emitOpWithArg(.Apply1, @intFromEnum(o1), &.{a});
          }
        } else if (n == 2) {
          if (ic.op2) |o2| {
            var in2 = [_]ir.ValueId{ try self.compileNode(seq[0], false), try self.compileNode(seq[1], false) };
            return try self.emitOpWithArg(.Apply2, @intFromEnum(o2), &in2);
          }
        }
      }
    }

    // @[x;i;f] (3) / @[x;i;f;v] (4) → Apply3/Apply4 with Op3/Op4 byte (no function on stack).
    // Same for .[x;p;f] / .[x;p;f;v] → drill3 / drill4.
    if (ap.f.* == .op and (seq.len == 3 or seq.len == 4)) {
      const op_str = ap.f.op;
      const is_amend = std.mem.eql(u8, op_str, "@");
      const is_drill = std.mem.eql(u8, op_str, ".");
      // ?[x;y;z] (3 args only) → splice. 4-arg `?` keeps the generic path.
      const is_splice = seq.len == 3 and std.mem.eql(u8, op_str, "?");
      if (is_amend or is_drill or is_splice) {
        var inputs: std.ArrayList(ir.ValueId) = .empty;
        defer inputs.deinit(self.alloc);
        for (seq) |x| try inputs.append(self.alloc, try self.compileNode(x, false));
        if (seq.len == 3) {
          const op3: Op3 = if (is_amend) .amend3 else if (is_drill) .drill3 else .splice3;
          return try self.emitOpWithArg(.Apply3, @intFromEnum(op3), inputs.items);
        } else {
          const op4: Op4 = if (is_amend) .amend4 else .drill4;
          return try self.emitOpWithArg(.Apply4, @intFromEnum(op4), inputs.items);
        }
      }
    }

    var inputs: std.ArrayList(ir.ValueId) = .empty;
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
        // Multi-line string: content opens with a literal newline (only the
        // lexer's multi-line path can produce this). Strip the leading newline
        // and the common indentation of all non-blank lines before decoding.
        const src = if (c.len > 0 and c[0] == '\n') try dedent(self.alloc, c[1..]) else c;
        defer if (src.ptr != c.ptr) self.alloc.free(src);
        const cc = src;
        // Decode backslash escapes: \n \t \0 \\ \" → actual bytes
        var buf = try std.ArrayList(u8).initCapacity(self.alloc, cc.len);
        defer buf.deinit(self.alloc);
        var i: usize = 0;
        while (i < cc.len) {
          if (cc[i] == '\\' and i + 1 < cc.len) {
            buf.appendAssumeCapacity(switch (cc[i + 1]) {
              'n' => '\n', 't' => '\t', '0' => 0, else => cc[i + 1],
            });
            i += 2;
          } else {
            buf.appendAssumeCapacity(cc[i]);
            i += 1;
          }
        }
        if (buf.items.len == 1) break :blk V{ .c = buf.items[0] };
        const n = try N(u8).n1(self.alloc, buf.items);
        break :blk V{ .C = n };
      },
      .s => |s| V{ .s = try self.symbols.intern(s) },
      .n => |x| V{ .n = x },
      .N => |arr| V{ .N = try N(u32).fromSlice(self.alloc, arr) },
      .d => |x| V{ .d = x },
      .h => |x| V{ .h = x },
      .D => |arr| V{ .D = try N(f64).fromSlice(self.alloc, arr) },
      .H => |arr| V{ .H = try N(f16).fromSlice(self.alloc, arr) },
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

    // Constant propagation: a `:`-bound global constant (literal) inlines its value
    // here — re-emitting the literal — so downstream arithmetic folds and the Global
    // load is elided. Skipped when a local/param of the same name shadows it. The rhs
    // is always a non-var literal, so this recurses at most once into compileLiteral.
    if (!self.isLocalName(name)) if (self.const_globals.get(name)) |rhs| {
      return try self.compileNode(rhs, false);
    };

    const scope = self.scope;
    if (scope.is_lambda) {
      if (std.mem.eql(u8, name, "x")) { scope.uses_x = true; }
      else if (std.mem.eql(u8, name, "y")) { scope.uses_y = true; }
      else if (std.mem.eql(u8, name, "z")) { scope.uses_z = true; }

      const id = try self.emitOpWithArg(.Local, 0, &.{});
      try self.addPatch(name);
      return id;
    } else {
      return try self.emitOpWithArg(.Global, try self.resolveGlobalRef(name), &.{});
    }
  }

  fn compileBind(self: *Compiler, b: ast.Bind) anyerror!ir.ValueId {
    // `sym: val → sym 0: val  (WriteLines; `0:"hello" → print to stdout)
    if (b.v.* == .literal and b.v.literal == .s and b.a != null and b.f == null) {
      const lhs_id = try self.compileNode(b.v, false);
      const rhs_id = try self.compileNode(b.a.?, false);
      var inputs: [2]ir.ValueId = .{ lhs_id, rhs_id };
      return try self.emitOpWithArg(.Apply2, @intFromEnum(Op2.@"0:"), &inputs);
    }

    // Indexed-lvalue assignment is sugar for amend:
    //   d[i]:v      →  d : @[d;i;:;v]
    //   d[i]+:v     →  d : @[d;i;+;v]   (compound op folds into the amend verb)
    //   d[i;j]:v    →  d : .[d;(i;j);:;v]   (multi-index → drill)
    // Works for any indexable: dicts (adds/replaces a key), lists and vectors.
    if (b.v.* == .apply and b.a != null) {
      // Indexed-lvalue assignment is sugar for amend. The lvalue may be a CHAIN of
      // single indexes — `name[i][j]:v` — which we flatten into the base variable plus
      // the full index path, so it drills exactly like the multi-index form `d[i;j]:v`
      // (one in-place `.` amend, never materializing the intermediate containers).
      var seqs: std.ArrayList(ast.Seq) = .empty;
      defer seqs.deinit(self.alloc);
      var node: *ast.Node = b.v;
      while (node.* == .apply) {
        try seqs.append(self.alloc, node.apply.a orelse &.{});
        node = node.apply.f;
      }
      // Only `name[idx...]:v` (the chain bottoms out at a plain variable) is assignable.
      if (node.* != .literal or node.literal != .@"var") return error.UnsupportedAssignment;
      const base_node = node;
      // The walk collected index groups outermost-first; flatten them base-outward.
      var path: std.ArrayList(*ast.Node) = .empty;
      defer path.deinit(self.alloc);
      var gi: usize = seqs.items.len;
      while (gi > 0) {
        gi -= 1;
        for (seqs.items[gi]) |idx| try path.append(self.alloc, idx);
      }
      const seq: ast.Seq = path.items;
      if (seq.len == 0) {
        // `d[]:v` / `d[]op:v` → whole-value (re)assign `d:v` / `d:d op v`.
        return try self.compileBind(.{ .v = base_node, .f = b.f, .a = b.a });
      }
      const amend_fn: ast.Op = if (b.f) |op| (if (std.mem.eql(u8, op, ":")) ":" else op) else ":";
      const verb_str: ast.Op = if (seq.len == 1) "@" else ".";
      var amend_verb = ast.Node{ .op = verb_str };
      var fn_node = ast.Node{ .op = amend_fn };
      var list_node = ast.Node{ .list = .{ .seq = seq } };
      const index_node: *ast.Node = if (seq.len == 1) seq[0] else &list_node;
      var apply_seq = [_]*ast.Node{ base_node, index_node, &fn_node, b.a.? };
      var apply_node = ast.Node{ .apply = .{ .f = &amend_verb, .a = apply_seq[0..] } };
      // Preserve global-vs-local target. `name[i]::v` / `name[i]op::v` arrive with
      // b.a wrapped in `.right` (the second colon) — the same marker plain global
      // assigns use. Re-wrap the synthesized amend so the write-back targets the
      // global rather than a fresh local. `name[i]:v` / `name[i]op:v` stay local.
      const is_global = b.a.?.* == .right;
      var right_node = ast.Node{ .right = .{ .clause = &apply_node } };
      const write_a: *ast.Node = if (is_global) &right_node else &apply_node;
      return try self.compileBind(.{ .v = base_node, .f = null, .a = write_a });
    }

    // Implicit function namespace: binding a lambda to name `F` scopes bare
    // references in its body to the sub-namespace `F` (see fn_namespace). Set it
    // around the RHS compile so it is live when the lambda's deferred name patches
    // resolve (compileLambda end). Restored on return; never affects assignment.
    const saved_fn_ns = self.fn_namespace;
    defer self.fn_namespace = saved_fn_ns;
    if (b.v.* == .literal and b.v.literal == .@"var") {
      if (b.a) |rhs0| {
        const lam = if (rhs0.* == .right) rhs0.right.clause else rhs0;
        const is_colon = b.f == null or std.mem.eql(u8, b.f.?, ":");
        if (lam.* == .lambda and is_colon)
          self.fn_namespace = try self.qualifiedAssignName(b.v.literal.@"var");
      }
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
        // A GLOBAL-scope SINGLE-bind (`:` = constant) records the name for constant
        // folding: a pure literal rhs → const_globals (propagate the value), a monadic
        // intrinsic wrapper `{`sin x}` → intrinsic_alias (lower calls to the opcode).
        // A `::` (double-bind = variable, arrives as a `.right` rhs), a compound op
        // (`+:`), an indexed rebind, or any other rhs clears both — a variable can't
        // be folded. Relies on the single/double-bind contract (a `:`-global is const).
        if (!scope.is_lambda) {
          _ = self.const_globals.remove(name);
          _ = self.intrinsic_alias.remove(name);
          const is_double = b.a != null and b.a.?.* == .right;
          const compound = b.f != null and !std.mem.eql(u8, b.f.?, ":");
          // A name the unit mutates anywhere (`::` / indexed, even inside a lambda)
          // is not a constant, so never record it.
          if (!is_double and !compound and !self.mutated.contains(name)) if (b.a) |rhs| {
            if (rhs.* == .literal and rhs.literal != .@"var") {
              try self.const_globals.put(try self.interned(name), rhs);
            } else if (monoIntrinsicWrapper(rhs)) |op1| {
              try self.intrinsic_alias.put(try self.interned(name), op1);
            }
          };
        }
        return try self.emitOpWithArg(.AssignGlobal, try self.resolveGlobalAssign(name), &.{rhs_id});
      }
    } else if (b.v.* == .literal and b.v.literal != .@"var") {
      // Non-variable noun on LHS of ':' — dyadic right verb: x:y = y.
      // b.v is a non-assignable expression; just return the already-compiled rhs.
      return rhs_id;
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
            const nop_id = try self.emitOpWithArg(.Nop, try self.resolveGlobalAssign(name), &.{});
            const inst = self.scope.ir.get(nop_id);
            inst.arg3 = 2; // arg3==2: global list-assign target (u16 index); ==1 is a local (u8)
            self.scope.ir.markEffectful(nop_id);
          } else return error.UnsupportedAssignment;
        }
        return id;
      }
    }
    return ir.NO_VALUE;
  }

  fn compileTransit(self: *Compiler, t: ast.Transit, is_tail: bool) anyerror!ir.ValueId {
    // Seeded adverb tacit: n op:\ g where g is verb-like → lambda {n op:\ g x}
    // e.g. '1<:\ (|1#:\)'' → '{1<:\ (|1#:\)' x}'
    if (t.v.* == .term and isVerbLike(t.b)) {
      var x_node = ast.Node{ .literal = .{ .@"var" = "x" } };
      var bx_node = ast.Node{ .apposit = .{ .f = t.b, .a = &x_node } };
      var body_node = ast.Node{ .transit = .{ .a = t.a, .v = t.v, .b = &bx_node } };
      var body_arr = [1]*ast.Node{&body_node};
      const lambda = ast.Lambda{ .a = null, .b = body_arr[0..], .start = 0, .end = 0 };
      return try self.compileLambda(lambda);
    }
    if (t.v.* == .op or t.v.* == .io) {
      const op = if (t.v.* == .op) t.v.op else t.v.io;
      if (Op2.fromString(op)) |o| {
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
      if (i.v.* == .op or i.v.* == .io) {
        const op = if (i.v.* == .op) i.v.op else i.v.io;
        if (Op2.fromString(op)) |_| {
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
      if (i.v.* == .op or i.v.* == .io) {
        const op = if (i.v.* == .op) i.v.op else i.v.io;
        if (Op2.fromString(op)) |o| {
          // Partial dyadic symbolic or IO op: a v -> v(a, )
          const v = V{ .o = Fn.dyad(o) };
          var inputs: [2]ir.ValueId = undefined;
          inputs[0] = try self.emitConst(v);
          inputs[1] = try self.compileNode(i.a, false);
          const id = try self.emitOpWithArg(.MakePartial, 1, &inputs);
          self.scope.ir.get(id).arg2 = 1;
          return id;
        }
      }
      // Seeded adverb with no right arg: n op:\ → lambda {n op:\ x}
      if (i.v.* == .term) {
        var x_node = ast.Node{ .literal = .{ .@"var" = "x" } };
        var body_node = ast.Node{ .transit = .{ .a = i.a, .v = i.v, .b = &x_node } };
        var body_arr = [1]*ast.Node{&body_node};
        const lambda = ast.Lambda{ .a = null, .b = body_arr[0..], .start = 0, .end = 0 };
        return try self.compileLambda(lambda);
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
      if (Op1.fromString(p.v) != null or Op2.fromString(p.v) != null) {
        return try self.compilePrimitive(p.v, 1, &.{arg_id});
      } else if (std.ascii.isAlphabetic(p.v[0])) {
        const v: V = if (Op2.fromString(p.v)) |o| .{ .o = Fn.dyad(o) }
                     else if (Op1.fromString(p.v)) |o| .{ .o = Fn.monad(o) }
                     else .{ .o = Fn.makeTrain(p.v) };
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

  // If `node` is the canonical prelude wrapper `{`sin x}` — a lambda whose sole
  // statement applies a literal intrinsic symbol (with an Op1) to the lambda's
  // sole parameter — return that Op1. Used to alias a `:`-bound global to the
  // opcode. The arg must BE the parameter, so `{`sin y}` (y free) is not matched.
  fn monoIntrinsicWrapper(node: *ast.Node) ?Op1 {
    if (node.* != .lambda) return null;
    const lam = node.lambda;
    const body = lam.b orelse return null;
    var n = body.len;
    while (n > 0 and body[n - 1].* == .blank) n -= 1;
    if (n != 1) return null;
    const s = body[0];
    if (s.* != .apposit) return null;
    const f = s.apposit.f;
    const a = s.apposit.a;
    if (f.* != .literal or f.literal != .s) return null;
    if (a.* != .literal or a.literal != .@"var") return null;
    const argname = a.literal.@"var";
    if (lam.a) |args| {
      if (args.len != 1 or !std.mem.eql(u8, args[0].value, argname)) return null;
    } else if (!std.mem.eql(u8, argname, "x")) return null; // implicit args: only x
    const ic = intrinsic.find(f.literal.s) orelse return null;
    return ic.op1;
  }

  // True if `name` resolves to a local (a param or a lambda-local) in the current
  // scope — in which case an intrinsic alias of the same name must NOT fire.
  // Lambdas don't close over parent scope, so only the immediate scope matters.
  fn isLocalName(self: *Compiler, name: []const u8) bool {
    const s = self.scope;
    if (!s.is_lambda) return false;
    if (s.locals.contains(name)) return true;
    if (s.named_args) |args| for (args) |arg| {
      if (std.mem.eql(u8, arg.value, name)) return true;
    };
    return false;
  }

  fn compileApposit(self: *Compiler, ap: ast.Apposit, is_tail: bool) anyerror!ir.ValueId {
    // Level-B: a constant (`:`) global aliased to an intrinsic wrapper, applied by
    // juxtaposition (`sin y`), lowers to the Op1 kernel — fusable at the call site,
    // no lambda frame. Cleared on `::`/rebind; skipped for a local/param of the
    // same name. See intrinsic_alias.
    if (ap.f.* == .literal and ap.f.literal == .@"var") {
      const nm = ap.f.literal.@"var";
      if (!self.isLocalName(nm) and !self.hasFnMember(nm)) if (self.intrinsic_alias.get(nm)) |o1| {
        const a = try self.compileNode(ap.a, false);
        return try self.emitOpWithArg(.Apply1, @intFromEnum(o1), &.{a});
      };
    }
    // Monomorphic intrinsic call site: a literal intrinsic SYMBOL juxtaposed with an
    // argument (`` `sin a ``) — the shape the lib/prelude.k bodies `{`sin x}` take —
    // lowers straight to the Op1 kernel, so it fuses with adjacent elementwise ops
    // and skips the syms.apply string-match. A literal symbol can't be shadowed.
    // See src/primitive/intrinsic.zig / compileApply's twin peephole.
    if (ap.f.* == .literal and ap.f.literal == .s) {
      if (intrinsic.find(ap.f.literal.s)) |ic| if (ic.op1) |o1| {
        const a = try self.compileNode(ap.a, false);
        return try self.emitOpWithArg(.Apply1, @intFromEnum(o1), &.{a});
      };
    }
    // When both sides are single-char verb ops, build a train (composition) constant.
    var ops_buf: [7]u8 = undefined;
    var ops_len: usize = 0;
    if (collectVerbOps(ap.f, &ops_buf, &ops_len) and collectVerbOps(ap.a, &ops_buf, &ops_len)) {
      const v = V{ .o = Fn.makeTrain(ops_buf[0..ops_len]) };
      return try self.emitConst(v);
    }
    // Tacit composition: f g where both are verb-like → lambda {f (g x)}
    if (isVerbLike(ap.f) and isVerbLike(ap.a)) {
      return try self.compileTacitCompose(ap.f, ap.a, is_tail);
    }
    var inputs: [2]ir.ValueId = undefined;
    inputs[0] = try self.compileNode(ap.f, false);
    inputs[1] = try self.compileNode(ap.a, false);
    return try self.emitOpWithArg(if (is_tail) .TailCall else .Call, 1, &inputs);
  }

  // Returns true if the node statically produces a function (verb-like expression).
  fn isVerbLike(node: *ast.Node) bool {
    return switch (node.*) {
      .op, .monad, .adverb_val => true,
      .term => true,
      .group => |g| isVerbLike(g.stmt),
      .apposit => |ap| isVerbLike(ap.f) and isVerbLike(ap.a),
      .transit => |t| isVerbLike(t.b),
      .intrans => |i| i.z == null and i.v.* == .term,
      else => false,
    };
  }

  // Compiles a tacit composition {f (g x)} as a lambda.
  fn compileTacitCompose(self: *Compiler, f_node: *ast.Node, g_node: *ast.Node, is_tail: bool) anyerror!ir.ValueId {
    _ = is_tail;
    var x_node = ast.Node{ .literal = .{ .@"var" = "x" } };
    var gx_node = ast.Node{ .apposit = .{ .f = g_node, .a = &x_node } };
    var fgx_node = ast.Node{ .apposit = .{ .f = f_node, .a = &gx_node } };
    var body_arr = [1]*ast.Node{&fgx_node};
    const lambda = ast.Lambda{ .a = null, .b = body_arr[0..], .start = 0, .end = 0 };
    return try self.compileLambda(lambda);
  }

  // Collects single-char op bytes from a op node or nested apposit of ops.
  // Returns true if the entire subtree consists of single-char verb ops, false otherwise.
  fn collectVerbOps(node: *ast.Node, buf: []u8, pos: *usize) bool {
    switch (node.*) {
      .op => |op| {
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
    return switch (a[0]) {
      '\'' => if (a.len == 1) .@"'" else .@"':",
      '/'  => if (a.len == 1) .@"/" else .@"/:",
      '\\' => if (a.len == 1) .@"\\" else .@"\\:",
      else => unreachable,
    };
  }

  fn compileTerm(self: *Compiler, t: ast.Term) anyerror!ir.ValueId {
    const f_id = try self.compileNode(t.f, false);
    const adv = adverbFromString(t.a);
    return try self.emitOpWithArg(.Derive, @intFromEnum(adv), &.{f_id});
  }

  fn compilePrimitive(self: *Compiler, name: []const u8, arity_val: u8, inputs: []const ir.ValueId) anyerror!ir.ValueId {
    if (arity_val == 1) {
      if (Op1.fromString(name)) |op| {
        return try self.emitOpWithArg(.Apply1, @intFromEnum(op), inputs);
      }
    } else if (arity_val == 2) {
      if (Op2.fromString(name)) |op| {
        return try self.emitOpWithArg(.Apply2, @intFromEnum(op), inputs);
      }
    }
    const v = V{ .o = Fn.makeTrain(name) };
    const f_id = try self.emitConst(v);
    var buf: [3]ir.ValueId = undefined;
    buf[0] = f_id;
    @memcpy(buf[1..][0..inputs.len], inputs);
    return try self.emitOpWithArg(.Apply, arity_val, buf[0 .. inputs.len + 1]);
  }

  fn compileLambda(self: *Compiler, l: ast.Lambda) anyerror!ir.ValueId {
    const chunk_ptr = try self.alloc.create(Chunk);
    chunk_ptr.* = try Chunk.init(self.alloc);
    var chunk_owned = true;
    errdefer if (chunk_owned) { chunk_ptr.deinit(); self.alloc.destroy(chunk_ptr); };

    const scope_ptr = try self.alloc.create(Scope);
    scope_ptr.* = Scope.init(self.alloc, chunk_ptr, self.scope);
    scope_ptr.is_lambda = true;
    scope_ptr.named_args = l.a;
    defer { scope_ptr.deinit(); self.alloc.destroy(scope_ptr); }

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
          inst.arg1 = try self.resolveGlobalRef(patch.name);
        }
      }

      const root_id = if (scope_ptr.ir.instructions.items.len > 0) @as(ir.ValueId, @intCast(scope_ptr.ir.instructions.items.len - 1)) else ir.NO_VALUE;
      try self.runOptimizer(&scope_ptr.ir, root_id);
      try self.lower();
      break :blk a;
    };

    const locals_count = @as(u8, @intCast(scope_ptr.locals.count()));

    const range_id = try self.registry.addRange(self.text_id, l.start, l.end);
    const lambda_idx = try self.fn_tables.addLambda(.{
      .arity  = arity_res,
      .locals = locals_count,
      .chunk  = chunk_ptr,
      .range  = range_id,
    });
    chunk_owned = false;
    return try self.emitConst(V{ .o = Fn.lambda(lambda_idx, arity_res) });
  }

  fn compileCond(self: *Compiler, c: ast.Cond, is_tail: bool) anyerror!ir.ValueId {
    const stmts = c.stmts;
    const jump_count = stmts.len / 2;
    const end_jumps = try self.alloc.alloc(usize, jump_count);
    defer self.alloc.free(end_jumps);

    var res_ids: std.ArrayList(ir.ValueId) = .empty;
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
    // Call/Apply/TailCall marshal their arguments through a fixed 8-slot buffer
    // in the VM (doCallWithMode/doTailCall). Reject over-long arg lists here so
    // a 9+ argument call site fails to compile instead of overflowing that
    // buffer at runtime. Matches the 8-parameter lambda cap.
    switch (op) {
      .Call, .TailCall, .Apply => if (arg > 8) return error.TooManyArgs,
      else => {},
    }
    return try self.scope.ir.emitWithArg(op, arg, inputs);
  }

  fn emitConst(self: *Compiler, val: V) !ir.ValueId {
    return try self.scope.ir.emitConstant(val);
  }

  fn getOrAddGlobal(self: *Compiler, name: []const u8) !u16 {
    const gop = try self.globals.getOrPut(name);
    if (!gop.found_existing) {
      gop.key_ptr.* = try self.alloc.dupe(u8, name);
      gop.value_ptr.* = @intCast(self.globals.count() - 1);
    }
    return gop.value_ptr.*;
  }

  // ── Namespaces (`\d`) ────────────────────────────────────────────────────
  // The namespace of a qualified name (`ns.member` → `ns`), or null if bare.
  fn nsOf(name: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    return name[0..dot];
  }
  // The short member name of a qualified name (`ns.member` → `member`).
  fn memberOf(name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
  }

  // Intern `s` and return the pool-owned (stable, deduped) slice.
  fn interned(self: *Compiler, s: []const u8) ![]const u8 {
    return self.symbols.get(try self.symbols.intern(s));
  }

  // `ns.member`, interned so the slice is stable for use as a map/global key.
  fn qualify(self: *Compiler, ns: []const u8, member: []const u8) ![]const u8 {
    var buf: [256]u8 = undefined;
    const q = std.fmt.bufPrint(&buf, "{s}.{s}", .{ ns, member }) catch return error.NameTooLong;
    return self.interned(q);
  }

  // Handle a `\d` command at compile time: `\d` resets to global scope,
  // `\d ns` opens namespace `ns` (all members public), `\d ns a b` opens `ns`
  // with only `a` and `b` public. Registers/updates the namespace policy.
  fn setNamespace(self: *Compiler, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) { self.namespace = null; return; }
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const ns = try self.interned(it.next().?);
    const gop = try self.namespaces.getOrPut(ns);
    if (!gop.found_existing) {
      gop.key_ptr.* = ns;
      gop.value_ptr.* = .{ .all_public = true, .publics = std.StringHashMap(void).init(self.alloc) };
    }
    var any_pub = false;
    while (it.next()) |p| {
      any_pub = true;
      try gop.value_ptr.publics.put(try self.interned(p), {});
    }
    if (any_pub) gop.value_ptr.all_public = false;
    self.namespace = ns;
  }

  // True if `member` is exported by namespace `ns` per its policy. Namespaces
  // never `\d`-declared (ad-hoc dotted names) are treated as fully public.
  fn isPublic(self: *Compiler, ns: []const u8, member: []const u8) bool {
    const policy = self.namespaces.get(ns) orelse return true;
    return policy.all_public or policy.publics.contains(member);
  }

  // Resolve a variable *reference* to a global slot, applying namespace rules.
  //   qualified `a.m`   → resolved RELATIVE to the current namespace first
  //                       (`cur.a.m`) when such a member exists, so inside
  //                       `\d font` a `cff2.outline` reaches `font.cff2.outline`;
  //                       otherwise the absolute `a.m`, with a strict-privacy
  //                       error if it is private and referenced from outside `a`.
  //   bare `m` in `ns`  → `ns.m` if that member exists, else global `m`.
  //   bare `m` globally → global `m`.
  fn resolveGlobalRef(self: *Compiler, name: []const u8) !u16 {
    if (nsOf(name)) |ns| {
      if (self.namespace) |cur| {
        const rel = try self.qualify(cur, name);
        if (self.globals.contains(rel)) return self.getOrAddGlobal(rel);
      }
      const inside = if (self.namespace) |cur| std.mem.eql(u8, cur, ns) else false;
      if (!inside and self.private_members.contains(name)) return error.PrivateName;
      return self.getOrAddGlobal(name);
    }
    // Implicit function namespace (innermost): a bare `expand` inside `group`
    // resolves to `group.expand` when that member exists, else falls through.
    if (self.fn_namespace) |fns| {
      const q = try self.qualify(fns, name);
      if (self.globals.contains(q)) return self.getOrAddGlobal(q);
    }
    if (self.namespace) |ns| {
      const q = try self.qualify(ns, name);
      if (self.globals.contains(q)) return self.getOrAddGlobal(q);
    }
    return self.getOrAddGlobal(name);
  }

  // The fully-qualified global key an assignment to `name` would target: a dotted
  // name as-is, a bare name qualified by the active `\d` namespace, else bare.
  // Used to seed `fn_namespace` when binding a lambda to a name.
  fn qualifiedAssignName(self: *Compiler, name: []const u8) ![]const u8 {
    if (nsOf(name) != null) return self.interned(name);
    if (self.namespace) |ns| return self.qualify(ns, name);
    return self.interned(name);
  }

  // True if bare `name` names a member of the active implicit function namespace
  // (`fn_namespace.name` exists as a global). Used to let such a member shadow a
  // prelude intrinsic-alias fast-path within its own function body.
  fn hasFnMember(self: *Compiler, name: []const u8) bool {
    if (nsOf(name) != null) return false;
    const fns = self.fn_namespace orelse return false;
    const q = self.qualify(fns, name) catch return false;
    return self.globals.contains(q);
  }

  // Resolve an *assignment* target to a global slot. A bare name inside a
  // namespace defines `ns.name`; its visibility is recorded so later
  // cross-namespace references can be rejected.
  fn resolveGlobalAssign(self: *Compiler, name: []const u8) !u16 {
    if (nsOf(name) != null) return self.getOrAddGlobal(name); // explicit `ns.m:`
    if (self.namespace) |ns| {
      const q = try self.qualify(ns, name);
      if (!self.isPublic(ns, name)) try self.private_members.put(q, {});
      return self.getOrAddGlobal(q);
    }
    return self.getOrAddGlobal(name);
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
      // Nop carries a list-assign target index: arg3==1 a u8 local, ==2 a u16 global.
      .Nop => return switch (inst.arg3) { 1 => 1, 2 => 2, else => 0 },
      .Const => {
        // Small i32 constants are emitted as the 3-byte Int opcode.
        if (inst.val) |v| {
          if (v == .i and v.i >= std.math.minInt(i16) and v.i <= std.math.maxInt(i16)) return 3;
        }
        return 3;
      },
      // Global indices are u16 (opcode + 2 bytes); local/list-assign-count args stay u8.
      .Global, .AssignGlobal => return 3,
      .Local, .AssignLocal,
      .Call, .TailCall, .Apply1, .Apply2, .Apply3, .Apply4, .Apply,
      .MakeList, .Derive,
      .ListAssignLocal, .ListAssignGlobal => return 2,
      .Drop => {
        if (inst.inputs.len > 0 and inst.inputs[0] != ir.NO_VALUE and !self.scope.ir.get(inst.inputs[0]).is_dead) return 1;
        return 0;
      },
      .Jump, .JumpFalse, .JumpTrue => return 3,
      .MakePartial, .ReduceZip, .FusedMap => return 3,
      else => return 1,
    }
  }

  fn lowerInst(self: *Compiler, chunk: *Chunk, inst: ir.IRInst, idx: usize, offsets: []usize) !void {
    if (inst.op == .Nop) {
      if (inst.arg3 == 1) try chunk.write(@as(u8, @intCast(inst.arg1)))       // local list-assign target
      else if (inst.arg3 == 2) try chunk.write16(@as(u16, @intCast(inst.arg1))); // global list-assign target
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
      try chunk.write16(c_idx);
      return;
    }

    // FusedMap: register the kernel program in the chunk, emit opcode + u16 index.
    if (inst.op == .FusedMap) {
      try chunk.writeOp(.FusedMap);
      const kidx = try chunk.addKernel(inst.kcode.?, @intCast(inst.arg1), @intCast(inst.arg2), (inst.arg3 & 1) != 0, (inst.arg3 & 2) != 0);
      try chunk.write16(kidx);
      return;
    }


    // Last-use local: emit LocalLast so the VM can steal the slot.
    const effective_op: OpCode = if (inst.is_last and inst.op == .Local) .LocalLast else inst.op;

    try chunk.writeOp(effective_op);
    switch (effective_op) {
      // Global indices are u16; everything else here (local slots, arg counts,
      // adverb ids, list-assign target counts) stays a single byte.
      .Global, .AssignGlobal => {
        try chunk.write16(@as(u16, @intCast(inst.arg1)));
      },
      .Local, .LocalLast, .AssignLocal, .Call, .TailCall, .Apply1, .Apply2, .Apply3, .Apply4, .Apply,
      .MakeList, .Derive, .ListAssignLocal, .ListAssignGlobal => {
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
      .MakePartial, .ReduceZip => {
        try chunk.write(@as(u8, @intCast(inst.arg1)));
        try chunk.write(@as(u8, @intCast(inst.arg2)));
      },
      else => {},
    }
  }

  fn runOptimizer(self: *Compiler, scope_ir: *ir.IR, root_id: ir.ValueId) !void {
    try optimize(self.alloc, scope_ir, root_id);
    _ = try inlineLambdas(self.alloc, scope_ir, self.fn_tables);
    try optimize(self.alloc, scope_ir, root_id);
    try livenessLocals(self.alloc, scope_ir);
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

  pub fn init(alloc: Alloc, chunk: *Chunk, parent: ?*Scope) Scope {
    return .{
      .alloc = alloc,
      .parent = parent,
      .chunk = chunk,
      .ir = ir.IR.init(alloc),
      .locals = std.StringHashMap(u8).init(alloc),
      .patches = .empty,
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

// ── Optimizer ────────────────────────────────────────────────────────────────

const LocalSet = struct {
  bits: [4]u64 = .{0, 0, 0, 0},

  pub fn set(s: *LocalSet, i: u8) void { s.bits[i >> 6] |= @as(u64, 1) << @as(u6, @truncate(i)); }
  pub fn clear(s: *LocalSet, i: u8) void { s.bits[i >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(i))); }
  pub fn has(s: LocalSet, i: u8) bool { return (s.bits[i >> 6] >> @as(u6, @truncate(i))) & 1 != 0; }
  pub fn unionWith(s: *LocalSet, o: LocalSet) void { for (0..4) |j| s.bits[j] |= o.bits[j]; }
  pub fn eql(a: LocalSet, b: LocalSet) bool { for (0..4) |j| if (a.bits[j] != b.bits[j]) return false; return true; }
  pub fn diff(a: LocalSet, b: LocalSet) LocalSet { var r = a; for (0..4) |j| r.bits[j] &= ~b.bits[j]; return r; }
};

const BB = struct {
  start:   u32,
  end:     u32,
  succ:    [2]u32 = .{0, 0},
  n_succ:  u8     = 0,
  gen:     LocalSet = .{},
  kill:    LocalSet = .{},
  livein:  LocalSet = .{},
  liveout: LocalSet = .{},
};

inline fn isCall1(inst: *const ir.IRInst) bool {
  return (inst.op == .Call or inst.op == .TailCall) and inst.arg1 == 1 and inst.inputs.len == 2;
}

fn isFusableReducer(op: Op1) bool {
  return switch (op) { .@"+/", .@"*/", .@"&/", .@"|/" => true, else => false };
}

// ── FusedMap: collapse a maximal pointwise arithmetic subtree ─────────────────
// Pointwise ops that fuse into one @Vector pass (see fuse.zig). Dyadic `%` and the
// monadic transcendentals are float-only (KOp.floatOnly) → the kernel is flagged
// so i32 operands fall back at runtime.
fn fusableMapBin(arg1: u32) ?KOp {
  return switch (@as(Op2, @enumFromInt(arg1))) {
    .@"+" => .Add, .@"-" => .Sub, .@"*" => .Mul, .@"&" => .Min, .@"|" => .Max, .@"%" => .Div,
    .@"<" => .Lt, .@">" => .Gt, .@"=" => .Eq,
    else => null,
  };
}
fn fusableMapMon(arg1: u32) ?KOp {
  return switch (@as(Op1, @enumFromInt(arg1))) {
    .@"-" => .Neg, .sqr => .Sqr, .sqrt => .Sqrt, .exp => .Exp, .log => .Log, .sin => .Sin, .cos => .Cos,
    else => null,
  };
}
// The pointwise KOp this IR node contributes, or null if it isn't fusable.
fn nodeKOp(inst: *const ir.IRInst) ?KOp {
  if (inst.op == .Apply2 and inst.inputs.len == 2) return fusableMapBin(inst.arg1);
  if (inst.op == .Apply1 and inst.inputs.len == 1) return fusableMapMon(inst.arg1);
  return null;
}
fn isFusableMapNode(inst: *const ir.IRInst) bool {
  return nodeKOp(inst) != null;
}

const KMAX_DEPTH = 16;
const FUSE_MIN_OPS = 2;   // fuse only chains of >=2 pointwise ops (single ops already SIMD)

// Builds a postfix kernel by DFS over a pointwise subtree. Bails (returns false,
// caller discards) on anything the safe fast subset doesn't cover: a shared leaf
// (same ValueId twice — would need a Dup the stack scheduler doesn't give us),
// a multi-use leaf, or a tree too deep/wide. Interior node ids are collected and
// only marked dead by the caller once the whole build succeeds.
const FuseBuilder = struct {
  ir: *ir.IR,
  uc: []const u32,
  code: *std.ArrayList(KInsn),
  leaves: *std.ArrayList(ir.ValueId),
  interior: *std.ArrayList(ir.ValueId),
  alloc: Alloc,
  sp: u32 = 0,
  maxsp: u32 = 0,
  nbin: u32 = 0,
  float_only: bool = false,

  fn leafIndex(self: *FuseBuilder, id: ir.ValueId) !?u8 {
    for (self.leaves.items) |l| if (l == id) return null;  // shared leaf → bail
    if (self.leaves.items.len >= 255) return null;
    const i: u8 = @intCast(self.leaves.items.len);
    try self.leaves.append(self.alloc, id);
    return i;
  }

  // Returns null on bail, else whether the subtree is "definitely boolean" (a
  // comparison, or `&`/`|` of two definitely-bool subtrees) so the caller can set
  // Kernel.result_bool. Bool values flow through the kernel as 0/1 in the numeric
  // type; `&`/`|`=Min/Max compute AND/OR on them, so no separate logical KOps.
  fn build(self: *FuseBuilder, id: ir.ValueId, is_root: bool) !?bool {
    const inst = self.ir.get(id);
    const kop = nodeKOp(inst);
    const absorb = kop != null and (is_root or self.uc[id] == 1);
    if (!absorb) {                                   // leaf
      if (self.uc[id] != 1) return null;             // shared/multi-use leaf → bail
      const li = (try self.leafIndex(id)) orelse return null;
      try self.code.append(self.alloc, .{ .op = .Col, .arg = li });
      self.sp += 1;
      if (self.sp > self.maxsp) self.maxsp = self.sp;
      return false;                                  // a leaf is not definitely-bool
    }
    const k = kop.?;
    if (k.floatOnly()) self.float_only = true;
    var all_children_bool = true;
    for (inst.inputs) |in| {
      if (in == ir.NO_VALUE or in >= self.ir.instructions.items.len) return null;
      const cb = (try self.build(in, false)) orelse return null;
      if (!cb) all_children_bool = false;
    }
    try self.code.append(self.alloc, .{ .op = k, .arg = 0 });
    self.sp -= k.arity() - 1;   // arity → 1 (monadic: 0 net; dyadic: -1)
    self.nbin += 1;
    if (!is_root) try self.interior.append(self.alloc, id);
    return k.isCmp() or ((k == .Min or k == .Max) and all_children_bool);
  }
};

fn fuseMaps(alloc: Alloc, scope_ir: *ir.IR) !bool {
  const insts = scope_ir.instructions.items;
  if (insts.len == 0) return false;
  const uc = try alloc.alloc(u32, insts.len);
  defer alloc.free(uc);
  @memset(uc, 0);
  for (insts) |inst| {
    if (inst.is_dead) continue;
    for (inst.inputs) |idv| if (idv != ir.NO_VALUE and idv < uc.len) { uc[idv] += 1; };
  }
  // A fusable node is a root unless it is the single-use fusable input of another.
  const absorbed = try alloc.alloc(bool, insts.len);
  defer alloc.free(absorbed);
  @memset(absorbed, false);
  for (insts) |*inst| {
    if (inst.is_dead or !isFusableMapNode(inst)) continue;
    for (inst.inputs) |idv| {
      if (idv == ir.NO_VALUE or idv >= insts.len) continue;
      if (isFusableMapNode(scope_ir.get(idv)) and uc[idv] == 1) absorbed[idv] = true;
    }
  }

  var code: std.ArrayList(KInsn) = .empty;
  defer code.deinit(alloc);
  var leaves: std.ArrayList(ir.ValueId) = .empty;
  defer leaves.deinit(alloc);
  var interior: std.ArrayList(ir.ValueId) = .empty;
  defer interior.deinit(alloc);

  var changed = false;
  for (insts, 0..) |*inst, id| {
    if (inst.is_dead or !isFusableMapNode(inst) or absorbed[id]) continue;
    code.clearRetainingCapacity();
    leaves.clearRetainingCapacity();
    interior.clearRetainingCapacity();
    var b = FuseBuilder{ .ir = scope_ir, .uc = uc, .code = &code, .leaves = &leaves, .interior = &interior, .alloc = alloc };
    const rb_opt = b.build(@intCast(id), true) catch null;
    if (rb_opt == null or b.nbin < FUSE_MIN_OPS or b.maxsp > KMAX_DEPTH or leaves.items.len > 255) continue;

    const kcode = try scope_ir.alloc.dupe(KInsn, code.items);
    const new_inputs = try scope_ir.alloc.dupe(ir.ValueId, leaves.items);
    scope_ir.alloc.free(inst.inputs);
    inst.op = .FusedMap;
    inst.arg1 = @intCast(leaves.items.len);   // ncol
    inst.arg2 = b.maxsp;                       // eval-stack depth
    inst.arg3 = (@as(u32, if (b.float_only) 1 else 0)) | (@as(u32, if (rb_opt.?) 2 else 0));  // bit0 float-only, bit1 result-bool
    inst.inputs = new_inputs;
    inst.kcode = kcode;
    for (interior.items) |iid| scope_ir.instructions.items[iid].is_dead = true;
    changed = true;
  }
  return changed;
}

fn isFusableBin(op: Op2) bool {
  return switch (op) {
    .@"+", .@"-", .@"*", .@"&", .@"|", .@"<", .@">", .@"=" => true,
    else => false,
  };
}

fn isBuiltinDyad(inst: *const ir.IRInst, op: Op2) bool {
  if (inst.op != .Const) return false;
  const v = inst.val orelse return false;
  if (v != .o) return false;
  if (v.o.kind != .callable) return false;
  if (!opmod.isOp2Idx(v.o.idx)) return false;
  return v.o.getOp2() == op;
}

fn optimize(alloc: Alloc, scope_ir: *ir.IR, root_id: ir.ValueId) !void {
  while (try constantFolding(alloc, scope_ir) or
         try peepholeIdioms(alloc, scope_ir) or
         try fuseMaps(alloc, scope_ir) or
         try dce(alloc, scope_ir, root_id)) {}
}

fn peepholeIdioms(alloc: Alloc, scope_ir: *ir.IR) !bool {
  const insts = scope_ir.instructions.items;
  const use_count = try alloc.alloc(u32, insts.len);
  defer alloc.free(use_count);
  @memset(use_count, 0);
  for (insts) |inst| {
    if (inst.is_dead) continue;
    for (inst.inputs) |id| {
      if (id != ir.NO_VALUE and id < use_count.len) use_count[id] += 1;
    }
  }

  var changed = false;
  for (insts) |*inst| {
    if (inst.is_dead) continue;

    if (inst.op == .Apply1 and inst.inputs.len == 1) {
      const red: Op1 = @enumFromInt(inst.arg1);
      if (isFusableReducer(red)) fz: {
        const prod_id = inst.inputs[0];
        if (prod_id == ir.NO_VALUE or use_count[prod_id] != 1) break :fz;
        const prod = scope_ir.get(prod_id);
        if (prod.op != .Apply2 or prod.inputs.len != 2) break :fz;
        const bin: Op2 = @enumFromInt(prod.arg1);
        if (!isFusableBin(bin)) break :fz;
        const a = prod.inputs[0];
        const b = prod.inputs[1];
        if (a == ir.NO_VALUE or b == ir.NO_VALUE) break :fz;

        const old_inputs = inst.inputs;
        const new_inputs = try scope_ir.alloc.alloc(ir.ValueId, 2);
        new_inputs[0] = a;
        new_inputs[1] = b;
        inst.inputs = new_inputs;
        inst.op = .ReduceZip;
        inst.arg1 = @intFromEnum(red);
        inst.arg2 = prod.arg1;
        scope_ir.alloc.free(old_inputs);
        scope_ir.instructions.items[prod_id].is_dead = true;
        changed = true;
        continue;
      }
    }

    if (!isCall1(inst)) continue;
    const f_id = inst.inputs[0];
    const arg_id = inst.inputs[1];
    if (f_id == ir.NO_VALUE or arg_id == ir.NO_VALUE) continue;
    const f_inst = scope_ir.get(f_id);

    if (f_inst.op == .Derive
        and f_inst.arg1 == @intFromEnum(Adverb.@"/")
        and f_inst.inputs.len == 1
        and use_count[f_id] == 1)
    {
      const base_id = f_inst.inputs[0];
      if (base_id != ir.NO_VALUE) {
        const base = scope_ir.get(base_id);
        if (base.op == .Const) blk: {
          const v = base.val orelse break :blk;
          if (v != .o) break :blk;
          if (v.o.kind != .callable) break :blk;
          if (!opmod.isOp2Idx(v.o.idx)) break :blk;
          const fused = fold_mod.fusedReducerOf(v.o.getOp2()) orelse break :blk;

          const old_inputs = inst.inputs;
          const new_inputs = try scope_ir.alloc.alloc(ir.ValueId, 1);
          new_inputs[0] = arg_id;
          inst.inputs = new_inputs;
          inst.op = .Apply1;
          inst.arg1 = @intFromEnum(fused);
          scope_ir.alloc.free(old_inputs);

          scope_ir.instructions.items[f_id].is_dead = true;
          changed = true;
          continue;
        }
      }
    }

    // Idiom: #'=x (tally-each over group) → freq x.
    // IR shape: Call1( Derive(', [Const #]), Call1(Const =, [x]) ). Both # and =
    // are emitted as Op2 consts and dispatched monadically. Replace the whole
    // thing with Apply1(freq, x), eliding both the group and the each.
    if (f_inst.op == .Derive
        and f_inst.arg1 == @intFromEnum(Adverb.@"'")
        and f_inst.inputs.len == 1
        and use_count[f_id] == 1
        and use_count[arg_id] == 1)
    {
      const base_id = f_inst.inputs[0];
      const inner = scope_ir.get(arg_id);
      if (base_id != ir.NO_VALUE and isCall1(inner)) blk: {
        // base of the each must be a const tally `#` (Op2, applied monadically)
        const base = scope_ir.get(base_id);
        if (base.op != .Const) break :blk;
        const bv = base.val orelse break :blk;
        if (bv != .o or bv.o.kind != .callable) break :blk;
        if (!opmod.isOp2Idx(bv.o.idx) or bv.o.getOp2() != .@"#") break :blk;
        // the argument must be a group: const `=` (Op2, monadic) applied to x
        const gfn_id = inner.inputs[0];
        const x_id   = inner.inputs[1];
        if (gfn_id == ir.NO_VALUE or x_id == ir.NO_VALUE) break :blk;
        const gfn = scope_ir.get(gfn_id);
        if (gfn.op != .Const) break :blk;
        const gv = gfn.val orelse break :blk;
        if (gv != .o or gv.o.kind != .callable) break :blk;
        if (!opmod.isOp2Idx(gv.o.idx) or gv.o.getOp2() != .@"=") break :blk;

        const old_inputs = inst.inputs;
        const new_inputs = try scope_ir.alloc.alloc(ir.ValueId, 1);
        new_inputs[0] = x_id;
        inst.inputs = new_inputs;
        inst.op = .Apply1;
        inst.arg1 = @intFromEnum(Op1.freq);
        scope_ir.alloc.free(old_inputs);

        scope_ir.instructions.items[f_id].is_dead = true;
        scope_ir.instructions.items[arg_id].is_dead = true;
        changed = true;
        continue;
      }
    }

    if (!isBuiltinDyad(f_inst, .@"*")) continue;
    const inner = scope_ir.get(arg_id);
    if (!isCall1(inner)) continue;
    if (use_count[arg_id] != 1) continue;
    const f_inner_id = inner.inputs[0];
    const x_id       = inner.inputs[1];
    if (f_inner_id == ir.NO_VALUE or x_id == ir.NO_VALUE) continue;
    if (!isBuiltinDyad(scope_ir.get(f_inner_id), .@"|")) continue;

    const old_inputs = inst.inputs;
    const new_inputs = try scope_ir.alloc.alloc(ir.ValueId, 1);
    new_inputs[0] = x_id;
    inst.inputs = new_inputs;
    inst.op = .Apply1;
    inst.arg1 = @intFromEnum(Op1.last);
    scope_ir.alloc.free(old_inputs);

    scope_ir.instructions.items[arg_id].is_dead = true;
    changed = true;
  }
  return changed;
}

fn constantFolding(alloc: Alloc, scope_ir: *ir.IR) !bool {
  var changed = false;
  for (scope_ir.instructions.items) |*inst| {
    if (inst.is_dead) continue;

    if (inst.op == .Apply1 and inst.inputs.len > 0 and inst.inputs[0] != ir.NO_VALUE) {
      const input = scope_ir.get(inst.inputs[0]);
      if (input.op == .Const) {
        const op: Op1 = @enumFromInt(inst.arg1);
        if (foldMonad(op, input.val.?)) |res| {
          if (inst.val) |v| v.deinit(alloc);
          alloc.free(inst.inputs);
          inst.* = .{ .op = .Const, .val = res, .is_pure = true };
          changed = true;
        }
      }
    }

    if (inst.op == .Apply2 and inst.inputs.len > 1 and
        inst.inputs[0] != ir.NO_VALUE and inst.inputs[1] != ir.NO_VALUE) {
      const left = scope_ir.get(inst.inputs[0]);
      const right = scope_ir.get(inst.inputs[1]);
      if (left.op == .Const and right.op == .Const) {
        const op: Op2 = @enumFromInt(inst.arg1);
        if (foldDyad(op, left.val.?, right.val.?)) |res| {
          if (inst.val) |v| v.deinit(alloc);
          alloc.free(inst.inputs);
          inst.* = .{ .op = .Const, .val = res, .is_pure = true };
          changed = true;
        }
      }
    }
  }
  return changed;
}

fn dce(alloc: Alloc, scope_ir: *ir.IR, root_id: ir.ValueId) !bool {
  var changed = false;
  const insts = scope_ir.instructions.items;
  const used = try alloc.alloc(bool, insts.len);
  defer alloc.free(used);
  @memset(used, false);
  if (root_id != ir.NO_VALUE) used[root_id] = true;

  var i = insts.len;
  while (i > 0) {
    i -= 1;
    const inst = insts[i];
    if (inst.is_dead) continue;
    if (!inst.is_pure or used[i]) {
      for (inst.inputs) |id| { if (id != ir.NO_VALUE) used[id] = true; }
    } else {
      scope_ir.instructions.items[i].is_dead = true;
      changed = true;
    }
  }
  return changed;
}

fn inlineLambdas(alloc: Alloc, scope_ir: *ir.IR, fn_tables: *const fntable.FnTables) !bool {
  _ = alloc;
  var changed = false;
  const insts = scope_ir.instructions.items;
  for (insts, 0..) |*inst, i| {
    if (inst.is_dead) continue;
    if (inst.op != .Call and inst.op != .TailCall) continue;
    if (inst.inputs.len < 1) continue;
    const func_id = inst.inputs[0];
    if (func_id == ir.NO_VALUE) continue;
    const func_inst = scope_ir.get(func_id);
    if (func_inst.op != .Const) continue;
    const fval = func_inst.val orelse continue;
    if (fval != .o) continue;
    const fn_ref = fval.o;
    if (fn_ref.kind != .callable or !opmod.isLambdaIdx(fn_ref.idx)) continue;
    const lambda_idx = opmod.lambdaIdxOf(fn_ref.idx);
    if (lambda_idx >= fn_tables.lambdas.items.len) continue;
    const entry = fn_tables.lambdas.items[lambda_idx];
    const op_byte = tryGetSimpleOp(entry.chunk, entry.arity) orelse continue;
    const n_args = inst.inputs.len - 1;
    if (n_args != entry.arity) continue;
    const new_op: OpCode = if (entry.arity == 1) .Apply1 else .Apply2;
    const new_inputs = try scope_ir.alloc.dupe(ir.ValueId, inst.inputs[1..]);
    scope_ir.alloc.free(inst.inputs);
    inst.op = new_op;
    inst.arg1 = op_byte;
    inst.inputs = new_inputs;
    inst.is_pure = true;
    _ = i;
    changed = true;
  }
  return changed;
}

fn livenessLocals(alloc: Alloc, scope_ir: *ir.IR) !void {
  const insts = scope_ir.instructions.items;
  const n = insts.len;
  if (n == 0) return;

  const leaders = try alloc.alloc(bool, n);
  defer alloc.free(leaders);
  @memset(leaders, false);
  leaders[0] = true;
  for (insts, 0..) |inst, i| {
    if (inst.is_dead) continue;
    switch (inst.op) {
      .Jump, .JumpFalse, .JumpTrue => {
        const t = inst.arg1;
        if (t < n) leaders[t] = true;
        if (i + 1 < n) leaders[i + 1] = true;
      },
      else => {},
    }
  }

  var bbs: std.ArrayList(BB) = .empty;
  defer bbs.deinit(alloc);
  const bb_of = try alloc.alloc(u32, n);
  defer alloc.free(bb_of);
  {
    var s: u32 = 0;
    for (1..n + 1) |i| {
      if (i == n or leaders[i]) {
        const id: u32 = @intCast(bbs.items.len);
        for (s..@as(u32, @intCast(i))) |j| bb_of[j] = id;
        try bbs.append(alloc, .{ .start = s, .end = @intCast(i) });
        s = @intCast(i);
      }
    }
  }
  const nb = bbs.items.len;

  for (bbs.items, 0..) |*bb, bi| {
    var last_op = OpCode.Nop;
    var last_arg: u32 = 0;
    {
      var j = bb.end;
      while (j > bb.start) {
        j -= 1;
        if (!insts[j].is_dead) { last_op = insts[j].op; last_arg = insts[j].arg1; break; }
      }
    }
    switch (last_op) {
      .Return => {},
      .Jump => {
        if (last_arg < n) { bb.succ[0] = bb_of[last_arg]; bb.n_succ = 1; }
      },
      .JumpFalse, .JumpTrue => {
        if (last_arg < n) { bb.succ[0] = bb_of[last_arg]; bb.n_succ = 1; }
        if (bi + 1 < nb) { bb.succ[bb.n_succ] = @intCast(bi + 1); bb.n_succ += 1; }
      },
      else => {
        if (bi + 1 < nb) { bb.succ[0] = @intCast(bi + 1); bb.n_succ = 1; }
      },
    }
  }

  for (bbs.items) |*bb| {
    for (bb.start..bb.end) |i| {
      const inst = insts[i];
      if (inst.is_dead) continue;
      switch (inst.op) {
        .Local => {
          const idx: u8 = @intCast(inst.arg1);
          if (!bb.kill.has(idx)) bb.gen.set(idx);
        },
        .AssignLocal => bb.kill.set(@intCast(inst.arg1)),
        .Nop => if (inst.arg3 == 1) bb.kill.set(@intCast(inst.arg1)),
        else => {},
      }
    }
  }

  var changed = true;
  while (changed) {
    changed = false;
    var bi = nb;
    while (bi > 0) {
      bi -= 1;
      const bb = &bbs.items[bi];
      var new_lo = LocalSet{};
      for (0..bb.n_succ) |si| new_lo.unionWith(bbs.items[bb.succ[si]].livein);
      var new_li = bb.gen;
      new_li.unionWith(new_lo.diff(bb.kill));
      if (!new_lo.eql(bb.liveout) or !new_li.eql(bb.livein)) {
        bb.liveout = new_lo;
        bb.livein  = new_li;
        changed = true;
      }
    }
  }

  for (bbs.items) |*bb| {
    var live = bb.liveout;
    var i = bb.end;
    while (i > bb.start) {
      i -= 1;
      const inst = &scope_ir.instructions.items[i];
      if (inst.is_dead) continue;
      switch (inst.op) {
        .AssignLocal => live.clear(@intCast(inst.arg1)),
        .Nop         => if (inst.arg3 == 1) live.clear(@intCast(inst.arg1)),
        .Local       => {
          const idx: u8 = @intCast(inst.arg1);
          if (!live.has(idx)) inst.is_last = true;
          live.set(idx);
        },
        else => {},
      }
    }
  }
}

fn foldMonad(op: Op1, x: V) ?V {
  return switch (x) {
    .i => |xv| switch (op) {
      .@"+" => x.ref(),
      .@"-" => V{ .i = 0 -% xv },
      .@"~" => V{ .b = xv == 0 },
      else => null,
    },
    .f => |xv| switch (op) {
      .@"-" => V{ .f = -xv },
      .@"~" => V{ .b = xv == 0.0 },
      else => null,
    },
    .b => |xv| switch (op) {
      .@"~" => V{ .b = !xv },
      else => null,
    },
    else => null,
  };
}

fn foldDyad(op: Op2, x: V, y: V) ?V {
  if (x == .i and y == .i) {
    const xv = x.i; const yv = y.i;
    return switch (op) {
      .@"+" => V{ .i = xv +% yv },
      .@"-" => V{ .i = xv -% yv },
      .@"*" => V{ .i = xv *% yv },
      .@"&" => V{ .i = @min(xv, yv) },
      .@"|" => V{ .i = @max(xv, yv) },
      .@"<" => V{ .b = xv < yv },
      .@">" => V{ .b = xv > yv },
      .@"=" => V{ .b = xv == yv },
      .@"~" => V{ .b = xv == yv },
      else => null,
    };
  }
  if (x == .f and y == .f) {
    const xv = x.f; const yv = y.f;
    return switch (op) {
      .@"+" => V{ .f = xv + yv },
      .@"-" => V{ .f = xv - yv },
      .@"*" => V{ .f = xv * yv },
      .@"%" => V{ .f = xv / yv },
      .@"&" => V{ .f = @min(xv, yv) },
      .@"|" => V{ .f = @max(xv, yv) },
      .@"<" => V{ .b = xv < yv },
      .@">" => V{ .b = xv > yv },
      .@"=" => V{ .b = xv == yv },
      .@"~" => V{ .b = xv == yv },
      else => null,
    };
  }
  if (x == .b and y == .b) {
    const xv = x.b; const yv = y.b;
    return switch (op) {
      .@"=" => V{ .b = xv == yv },
      .@"~" => V{ .b = xv == yv },
      else => null,
    };
  }
  return null;
}

fn tryGetSimpleOp(c: *const Chunk, arity: u8) ?u8 {
  const code = c.code.items;
  if (arity == 1 and code.len == 5) {
    const op0: OpCode = @enumFromInt(code[0]);
    if ((op0 == .Local or op0 == .LocalLast) and code[1] == 0) {
      if (@as(OpCode, @enumFromInt(code[2])) == .Apply1 and
          @as(OpCode, @enumFromInt(code[4])) == .Return)
        return code[3];
    }
  }
  if (arity == 2 and code.len == 7) {
    const op0: OpCode = @enumFromInt(code[0]);
    const op1: OpCode = @enumFromInt(code[2]);
    if ((op0 == .Local or op0 == .LocalLast) and code[1] == 0 and
        (op1 == .Local or op1 == .LocalLast) and code[3] == 1) {
      if (@as(OpCode, @enumFromInt(code[4])) == .Apply2 and
          @as(OpCode, @enumFromInt(code[6])) == .Return)
        return code[5];
    }
  }
  return null;
}
