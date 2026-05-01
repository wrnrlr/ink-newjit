/// Terse/K → WGSL transpiler for fragment shaders.
/// Compatible with the fill.wgsl binding layout.
///
/// Subset supported:
///   Literals:     integers, floats, symbols (color names), variables
///   Operators:    + - * % (div) & (min) | (max) ^ (abs/pow) _ (floor) , (vec-join)
///   Monadic:      - (neg) % (sqrt) ^ (abs) _ (floor) # (length)
///   Builtins:     sin cos tan asin acos atan sqrt abs floor ceil fract sign
///                 exp log length normalize dot cross min max clamp mix step smoothstep
///                 distance pow
///   Assignment:   name: expr
///   Destructure:  (a;b): expr
///   List:         (a;b;c) → vecN constructor
///   Index:        v[0 1] → swizzle .xy
///   Globals:      .`resolution → u_view.viewSize
///   Colors:       `red400 → vec4<f32> RGBA
///   Cond:         $[test;then;else]
///   Lambda:       {[args] body}  (last unnamed = fragment entry)

const std = @import("std");
const ast = @import("lang").ast;
const color = @import("./color.zig");

pub const Error = error{
  OutOfMemory,
  UnsupportedNode,
  UnsupportedVerb,
  UnknownVariable,
  UnknownColor,
  TypeMismatch,
};

// ---------------------------------------------------------------------------
// WGSL types
// ---------------------------------------------------------------------------

pub const WgslType = enum {
  void,
  bool,
  f32,
  vec2f,
  vec3f,
  vec4f,
  unknown,

  pub fn wgslName(self: WgslType) []const u8 {
    return switch (self) {
      .void => "void", .bool => "bool", .f32 => "f32",
      .vec2f => "vec2<f32>", .vec3f => "vec3<f32>", .vec4f => "vec4<f32>",
      .unknown => "/* ? */",
    };
  }

  pub fn size(self: WgslType) u32 { return switch (self) { .f32 => 1, .vec2f => 2, .vec3f => 3, .vec4f => 4, else => 0 }; }

  pub fn fromSize(n: u32) WgslType {
    return switch (n) {
      1 => .f32,
      2 => .vec2f,
      3 => .vec3f,
      4 => .vec4f,
      else => .unknown,
    };
  }

  pub fn promote(a: WgslType, b: WgslType) WgslType {
    const sa = a.size();
    const sb = b.size();
    if (sa == 0 or sb == 0) return .unknown;
    return fromSize(@max(sa, sb));
  }
};

// Scope – variable type tracking
const Scope = struct {
  alloc: std.mem.Allocator,
  parent: ?*const Scope,
  vars: std.StringHashMapUnmanaged(WgslType),

  fn init(alloc: std.mem.Allocator, parent: ?*const Scope) Scope {
    return .{ .alloc = alloc, .parent = parent, .vars = .{} };
  }

  fn deinit(self: *Scope) void {
    self.vars.deinit(self.alloc);
  }

  fn get(self: *const Scope, name: []const u8) ?WgslType {
    if (self.vars.get(name)) |t| return t;
    if (self.parent) |p| return p.get(name);
    return null;
  }

  fn put(self: *Scope, name: []const u8, t: WgslType) !void {
    try self.vars.put(self.alloc, name, t);
  }
};

// Function info
const ArgInfo = struct {
  name: []const u8,
  typ: WgslType,
};

const FuncInfo = struct {
  args: []ArgInfo,
  ret: WgslType,
  lambda: *ast.Node, // .lambda node
};

// List writer — thin wrapper so write functions use appendSlice/append
const ListWriter = struct {
  list: *std.ArrayList(u8),
  alloc: std.mem.Allocator,

  pub fn writeAll(self: ListWriter, s: []const u8) Error!void {
    try self.list.appendSlice(self.alloc, s);
  }

  pub fn writeByte(self: ListWriter, c: u8) Error!void {
    try self.list.append(self.alloc, c);
  }

  pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) Error!void {
    const s = try std.fmt.allocPrint(self.alloc, fmt, args);
    try self.list.appendSlice(self.alloc, s);
  }
};

// ---------------------------------------------------------------------------
// Colour lookup
// ---------------------------------------------------------------------------

/// Returns RGBA for a terse colour symbol name (e.g. "red400", "teal200").
/// Symbol names are lowercase; color field names are PascalCase — compare case-insensitively.
fn colorFromName(name: []const u8) ?color.Rgba {
    inline for (@typeInfo(color).@"struct".decls) |decl| {
        const val = @field(color, decl.name);
        if (@TypeOf(val) == color.Rgba) {
            if (std.ascii.eqlIgnoreCase(name, decl.name)) return val;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Verb mappings
// ---------------------------------------------------------------------------

/// Map a k verb string to a WGSL infix operator for dyadic use.
fn dyadicInfix(verb: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, verb, "+")) return "+";
    if (std.mem.eql(u8, verb, "-")) return "-";
    if (std.mem.eql(u8, verb, "*")) return "*";
    if (std.mem.eql(u8, verb, "/")) return "/";
    if (std.mem.eql(u8, verb, "%")) return "/";
    if (std.mem.eql(u8, verb, "!")) return "%";
    if (std.mem.eql(u8, verb, "=")) return "==";
    if (std.mem.eql(u8, verb, "~")) return "==";
    if (std.mem.eql(u8, verb, "<")) return "<";
    if (std.mem.eql(u8, verb, ">")) return ">";
    return null;
}

/// Map a k verb to a WGSL function call name for dyadic use.
fn dyadicFn(verb: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, verb, "!")) return "modf_rem";
    if (std.mem.eql(u8, verb, "&")) return "min";
    if (std.mem.eql(u8, verb, "|")) return "max";
    if (std.mem.eql(u8, verb, "^")) return "pow";
    return null;
}

/// Map a k verb to a WGSL function call name for monadic use.
fn monadicFn(verb: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, verb, "%")) return "sqrt";
    if (std.mem.eql(u8, verb, "^")) return "abs";
    if (std.mem.eql(u8, verb, "_")) return "floor";
    if (std.mem.eql(u8, verb, "#")) return "length";
    if (std.mem.eql(u8, verb, "-")) return "negate";
    return null;
}

/// Heuristic: guess arg type from name.
fn guessArgType(name: []const u8) WgslType {
    const eql = std.mem.eql;
    if (eql(u8, name, "uv") or eql(u8, name, "pos") or eql(u8, name, "coord") or
        eql(u8, name, "center") or eql(u8, name, "position") or eql(u8, name, "st") or
        eql(u8, name, "p") or eql(u8, name, "q")) return .vec2f;
    if (eql(u8, name, "color") or eql(u8, name, "col") or eql(u8, name, "fg") or
        eql(u8, name, "bg") or eql(u8, name, "foreground") or eql(u8, name, "background") or
        eql(u8, name, "rgba") or eql(u8, name, "c")) return .vec4f;
    return .f32;
}

// ---------------------------------------------------------------------------
// Builtin function names (pass-through to WGSL)
// ---------------------------------------------------------------------------

const WGSL_BUILTINS = [_][]const u8{
  "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
  "sqrt", "abs", "floor", "ceil", "fract", "sign", "round",
  "exp", "log", "exp2", "log2",
  "min", "max", "clamp", "mix", "step", "smoothstep",
  "length", "distance", "dot", "cross", "normalize",
  "pow", "mod", "modf",
  "reflect", "refract",
  "all", "any",
};

fn isBuiltin(name: []const u8) bool {
    for (WGSL_BUILTINS) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Transpiler
// ---------------------------------------------------------------------------

pub const Transpiler = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    out: std.ArrayList(u8),
    funcs: std.StringHashMapUnmanaged(FuncInfo),
    global_scope: Scope,

    pub fn init(alloc: std.mem.Allocator) Transpiler {
        return .{
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .out = .{},
            .funcs = .{},
            .global_scope = Scope.init(alloc, null),
        };
    }

    pub fn deinit(self: *Transpiler) void {
        self.arena.deinit();
        self.out.deinit(self.alloc);
        self.funcs.deinit(self.alloc);
        self.global_scope.deinit();
    }

    /// Transpile a parsed terse AST to a WGSL shader string.
    /// Caller owns the returned slice (allocated with `alloc`).
    pub fn transpile(self: *Transpiler, node: *ast.Node) Error![]const u8 {
        const aa = self.arena.allocator();

        // Phase 1: collect named function definitions and find entry lambda
        const entry = try self.collectFuncs(node, aa);

        // Phase 2: build global scope (all function names + their return types)
        var it = self.funcs.iterator();
        while (it.next()) |kv| {
            try self.global_scope.put(kv.key_ptr.*, kv.value_ptr.ret);
        }

        // Phase 3: emit
        const w = ListWriter{ .list = &self.out, .alloc = self.alloc };
        try self.writePreamble(w);
        try self.writeNamedFuncs(w, aa);
        try self.writeVertexShader(w);
        if (entry) |e| {
            try self.writeFragmentMain(w, e, aa);
        }

        return self.out.toOwnedSlice(self.alloc);
    }

    // -----------------------------------------------------------------------
    // Phase 1: collect named function definitions
    // -----------------------------------------------------------------------

    fn collectFuncs(self: *Transpiler, node: *ast.Node, aa: std.mem.Allocator) Error!?*ast.Node {
        const stmts = switch (node.*) {
            .terse => |t| t.stmts,
            else => return error.UnsupportedNode,
        };

        var last_entry: ?*ast.Node = null;

        for (stmts) |stmt| {
            switch (stmt.node.*) {
                .bind => |b| {
                    if (b.v.* == .literal and b.v.literal == .@"var") {
                        if (b.a) |rhs| {
                            if (rhs.* == .lambda) {
                                const name = b.v.literal.@"var";
                                const info = try self.buildFuncInfo(name, rhs, aa);
                                try self.funcs.put(self.alloc, name, info);
                            }
                        }
                    }
                },
                .lambda => {
                    last_entry = stmt.node;
                },
                else => {},
            }
        }

        return last_entry;
    }

    fn buildFuncInfo(self: *Transpiler, _: []const u8, lambda_node: *ast.Node, aa: std.mem.Allocator) Error!FuncInfo {
        const lambda = lambda_node.lambda;

        var arg_list = std.ArrayList(ArgInfo){};
        if (lambda.a) |args| {
            for (args) |arg| {
                if (arg.is_some) {
                    try arg_list.append(aa, .{ .name = arg.value, .typ = guessArgType(arg.value) });
                }
            }
        }
        const arg_slice = try arg_list.toOwnedSlice(aa);

        // Infer return type from body using a temporary scope
        var scope = Scope.init(aa, &self.global_scope);
        for (arg_slice) |a| try scope.put(a.name, a.typ);

        var ret = WgslType.void;
        if (lambda.b) |body| {
            for (body) |stmt| {
                if (stmt.* == .blank) continue;
                ret = self.inferType(stmt, &scope) catch .unknown;
                switch (stmt.*) {
                    .bind => |b| blk: {
                        if (b.v.* != .literal) break :blk;
                        if (b.v.literal != .@"var") break :blk;
                        const name = b.v.literal.@"var";
                        const vt = if (b.a) |rhs| self.inferType(rhs, &scope) catch .unknown else .unknown;
                        scope.put(name, vt) catch {};
                    },
                    else => {},
                }
            }
        }

        return FuncInfo{
            .args = arg_slice,
            .ret = ret,
            .lambda = lambda_node,
        };
    }

    // -----------------------------------------------------------------------
    // Type inference
    // -----------------------------------------------------------------------

    fn inferType(self: *Transpiler, node: *ast.Node, scope: *const Scope) Error!WgslType {
        return switch (node.*) {
            .blank => .void,
            .literal => |lit| switch (lit) {
                .b => .bool,
                .i => .f32,
                .f => .f32,
                .I => |v| WgslType.fromSize(@intCast(v.len)),
                .F => |v| WgslType.fromSize(@intCast(v.len)),
                .s => |name| blk: {
                    if (colorFromName(name) != null) break :blk .vec4f;
                    break :blk .unknown;
                },
                .@"var" => |name| scope.get(name) orelse .unknown,
                else => .unknown,
            },
            .transit => |t| blk: {
                if (t.v.* == .verb_op and std.mem.eql(u8, t.v.verb_op, ",")) {
                    const ta = try self.inferType(t.a, scope);
                    const tb = try self.inferType(t.b, scope);
                    break :blk WgslType.fromSize(ta.size() + tb.size());
                }
                const ta = try self.inferType(t.a, scope);
                const tb = try self.inferType(t.b, scope);
                break :blk WgslType.promote(ta, tb);
            },
            .intrans => |i| blk: {
                break :blk try self.inferType(i.a, scope);
            },
            .prefix => |p| blk: {
                if (std.mem.eql(u8, p.v, ".")) {
                    if (p.a.* == .literal and p.a.literal == .s) {
                        const sym = p.a.literal.s;
                        if (std.mem.eql(u8, sym, "resolution")) break :blk .vec2f;
                        if (colorFromName(sym) != null) break :blk .vec4f;
                    }
                }
                break :blk try self.inferType(p.a, scope);
            },
            .apposit => |ap| blk: {
                // .`symbol — parser may produce apposit{f=verb_op("."), a=symbol} instead of prefix
                const f_is_dot = switch (ap.f.*) {
                    .literal => |lit| lit == .@"var" and std.mem.eql(u8, lit.@"var", "."),
                    .verb_op => |op| std.mem.eql(u8, op, "."),
                    .verb_io => |io| std.mem.eql(u8, io, "."),
                    else => false,
                };
                if (f_is_dot and ap.a.* == .literal and ap.a.literal == .s) {
                    const sym = ap.a.literal.s;
                    if (std.mem.eql(u8, sym, "resolution")) break :blk .vec2f;
                    if (colorFromName(sym) != null) break :blk .vec4f;
                }
                const tf = try self.inferType(ap.f, scope);
                const ta = try self.inferType(ap.a, scope);
                if (tf == .f32 and ta == .f32) break :blk .vec2f;
                if (tf == .vec2f and ta == .f32) break :blk .vec3f;
                if (tf == .vec3f and ta == .f32) break :blk .vec4f;
                if (ap.f.* == .literal and ap.f.literal == .@"var") {
                    const name = ap.f.literal.@"var";
                    if (scope.get(name)) |t| break :blk t;
                }
                break :blk .unknown;
            },
            .apply => |ap| blk: {
                if (ap.f.* == .literal and ap.f.literal == .@"var") {
                    const name = ap.f.literal.@"var";
                    if (self.funcs.get(name)) |fi| break :blk fi.ret;
                    if (scope.get(name)) |t| break :blk t;
                }
                break :blk .unknown;
            },
            .group => |g| try self.inferType(g.stmt, scope),
            .list => |l| blk: {
                const seq = l.seq orelse break :blk .unknown;
                break :blk WgslType.fromSize(@intCast(seq.len));
            },
            .lambda => .void,
            .bind => |b| blk: {
                if (b.a) |rhs| break :blk try self.inferType(rhs, scope);
                break :blk .void;
            },
            .cond => |c| blk: {
                if (c.stmts.len >= 2) break :blk try self.inferType(c.stmts[1], scope);
                break :blk .unknown;
            },
            else => .unknown,
        };
    }

    // -----------------------------------------------------------------------
    // Emit: preamble
    // -----------------------------------------------------------------------

    fn writePreamble(_: *Transpiler, w: ListWriter) Error!void {
        try w.writeAll(
            \\// Generated by terse transpiler
            \\
            \\struct ViewUniforms {
            \\  viewSize: vec2<f32>,
            \\  _pad: vec2<f32>,
            \\}
            \\
            \\@group(0) @binding(0) var<uniform> u_view: ViewUniforms;
            \\
            \\struct VertexInput {
            \\  @location(0) pos: vec2<f32>,
            \\  @location(1) uv: vec2<f32>,
            \\}
            \\
            \\struct VertexOutput {
            \\  @builtin(position) position: vec4<f32>,
            \\  @location(0) ftcoord: vec2<f32>,
            \\  @location(1) fpos: vec2<f32>,
            \\}
            \\
            \\
        );
    }

    fn writeVertexShader(_: *Transpiler, w: ListWriter) Error!void {
        try w.writeAll(
            \\@vertex
            \\fn vs_main(in: VertexInput) -> VertexOutput {
            \\  var out: VertexOutput;
            \\  out.ftcoord = in.uv;
            \\  out.fpos = in.pos;
            \\  out.position = vec4<f32>(
            \\    2.0 * in.pos.x / u_view.viewSize.x - 1.0,
            \\    1.0 - 2.0 * in.pos.y / u_view.viewSize.y,
            \\    0.0, 1.0
            \\  );
            \\  return out;
            \\}
            \\
            \\
        );
    }

    // -----------------------------------------------------------------------
    // Emit: named functions
    // -----------------------------------------------------------------------

    fn writeNamedFuncs(self: *Transpiler, w: ListWriter, aa: std.mem.Allocator) Error!void {
        var it = self.funcs.iterator();
        while (it.next()) |kv| {
            try self.writeFn(w, kv.key_ptr.*, kv.value_ptr.*, aa);
            try w.writeByte('\n');
        }
    }

    fn writeFn(self: *Transpiler, w: ListWriter, name: []const u8, info: FuncInfo, aa: std.mem.Allocator) Error!void {
        try w.writeAll("fn ");
        try w.writeAll(name);
        try w.writeByte('(');
        for (info.args, 0..) |arg, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(arg.name);
            try w.writeAll(": ");
            try w.writeAll(arg.typ.wgslName());
        }
        try w.writeAll(") -> ");
        try w.writeAll(info.ret.wgslName());
        try w.writeAll(" {\n");

        var scope = Scope.init(aa, &self.global_scope);
        for (info.args) |a| try scope.put(a.name, a.typ);

        const lambda = info.lambda.lambda;
        if (lambda.b) |body| {
            try self.writeBody(w, body, &scope, info.ret, aa);
        }

        try w.writeAll("}\n");
    }

    fn writeFragmentMain(self: *Transpiler, w: ListWriter, entry: *ast.Node, aa: std.mem.Allocator) Error!void {
        const lambda = entry.lambda;

        try w.writeAll("@fragment\n");
        try w.writeAll("fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {\n");

        var scope = Scope.init(aa, &self.global_scope);

        if (lambda.a) |args| {
            const nargs = blk: {
                var n: usize = 0;
                for (args) |a| if (a.is_some) { n += 1; };
                break :blk n;
            };

            var idx: usize = 0;
            for (args) |arg| {
                if (!arg.is_some) continue;
                idx += 1;
                if (idx == nargs) {
                    try w.writeAll("  let ");
                    try w.writeAll(arg.value);
                    try w.writeAll(" = in.fpos;\n");
                    try scope.put(arg.value, .vec2f);
                } else {
                    const t = guessArgType(arg.value);
                    try w.writeAll("  let ");
                    try w.writeAll(arg.value);
                    try w.writeAll(" = ");
                    try w.writeAll(t.wgslName());
                    try w.writeAll("(0.0);\n");
                    try scope.put(arg.value, t);
                }
            }
        }

        if (lambda.b) |body| {
            try self.writeBody(w, body, &scope, .vec4f, aa);
        }

        try w.writeAll("}\n");
    }

    // -----------------------------------------------------------------------
    // Body emission
    // -----------------------------------------------------------------------

    fn writeBody(self: *Transpiler, w: ListWriter, body: ast.Seq, scope: *Scope, ret: WgslType, aa: std.mem.Allocator) Error!void {
        var tmp_count: u32 = 0;
        var last_expr: ?[]const u8 = null;
        var last_type: WgslType = .void;

        // Find the index of the last non-blank statement
        var last_real_idx: usize = 0;
        for (body, 0..) |stmt, i| {
            if (stmt.* != .blank) last_real_idx = i;
        }

        for (body, 0..) |stmt, idx| {
            const is_last = idx == last_real_idx;
            switch (stmt.*) {
                .blank => continue,
                .bind => |b| {
                    const expr_str = try self.emitExpr(b.a orelse continue, scope, w, &tmp_count, aa);
                    const expr_type = self.inferType(b.a orelse continue, scope) catch .unknown;

                    if (b.v.* == .literal and b.v.literal == .@"var") {
                        const vname = b.v.literal.@"var";
                        if (scope.get(vname) != null) {
                            try w.writeAll("  ");
                            try w.writeAll(vname);
                            try w.writeAll(" = ");
                            try w.writeAll(expr_str);
                            try w.writeAll(";\n");
                        } else {
                            try w.writeAll("  var ");
                            try w.writeAll(vname);
                            try w.writeAll(" = ");
                            try w.writeAll(expr_str);
                            try w.writeAll(";\n");
                            try scope.put(vname, expr_type);
                        }
                    } else if (b.v.* == .list) {
                        const tmp = try std.fmt.allocPrint(aa, "_d{d}", .{tmp_count});
                        tmp_count += 1;
                        try w.writeAll("  let ");
                        try w.writeAll(tmp);
                        try w.writeAll(" = ");
                        try w.writeAll(expr_str);
                        try w.writeAll(";\n");

                        const components = [_][]const u8{ ".x", ".y", ".z", ".w" };
                        const seq = b.v.list.seq orelse continue;
                        for (seq, 0..) |elem, ci| {
                            if (elem.* == .literal and elem.literal == .@"var") {
                                const ename = elem.literal.@"var";
                                const comp = if (ci < components.len) components[ci] else ".x";
                                try w.writeAll("  var ");
                                try w.writeAll(ename);
                                try w.writeAll(" = ");
                                try w.writeAll(tmp);
                                try w.writeAll(comp);
                                try w.writeAll(";\n");
                                try scope.put(ename, .f32);
                            }
                        }
                    }

                    if (is_last) {
                        if (b.v.* == .literal and b.v.literal == .@"var") {
                            last_expr = b.v.literal.@"var";
                        } else {
                            last_expr = expr_str;
                        }
                        last_type = expr_type;
                    }
                },
                else => {
                    const expr_str = try self.emitExpr(stmt, scope, w, &tmp_count, aa);
                    last_expr = expr_str;
                    last_type = self.inferType(stmt, scope) catch .unknown;
                    if (!is_last) {
                        if (last_type != .void) {
                            const tmp = try std.fmt.allocPrint(aa, "_t{d}", .{tmp_count});
                            tmp_count += 1;
                            try w.writeAll("  let ");
                            try w.writeAll(tmp);
                            try w.writeAll(" = ");
                            try w.writeAll(expr_str);
                            try w.writeAll(";\n");
                        }
                    }
                },
            }
        }

        if (ret != .void) {
            if (last_expr) |e| {
                const actual = last_type;
                const need = ret;
                if (actual != need and need == .vec4f and actual == .vec3f) {
                    try w.writeAll("  return vec4<f32>(");
                    try w.writeAll(e);
                    try w.writeAll(", 1.0);\n");
                } else if (actual != need and need == .vec4f and actual == .f32) {
                    try w.writeAll("  return vec4<f32>(");
                    try w.writeAll(e);
                    try w.writeAll(", ");
                    try w.writeAll(e);
                    try w.writeAll(", ");
                    try w.writeAll(e);
                    try w.writeAll(", 1.0);\n");
                } else {
                    try w.writeAll("  return ");
                    try w.writeAll(e);
                    try w.writeAll(";\n");
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Expression emission
    // Returns a WGSL expression string. May emit `let` declarations for temps.
    // -----------------------------------------------------------------------

    fn emitExpr(self: *Transpiler, node: *ast.Node, scope: *Scope, w: ListWriter, tc: *u32, aa: std.mem.Allocator) Error![]const u8 {
        return switch (node.*) {
            .blank => "",

            .literal => |lit| switch (lit) {
                .i => |v| try std.fmt.allocPrint(aa, "{d}.0", .{v}),
                .f => |v| blk: {
                    if (v == @trunc(v) and @abs(v) < 1e10) {
                        break :blk try std.fmt.allocPrint(aa, "{d}.0", .{@as(i64, @intFromFloat(v))});
                    }
                    break :blk try std.fmt.allocPrint(aa, "{d}", .{v});
                },
                .I => |vals| blk: {
                    const n = vals.len;
                    if (n == 0) break :blk "";
                    var buf = try std.ArrayList(u8).initCapacity(aa, 0);
                    const bw = ListWriter{ .list = &buf, .alloc = aa };
                    try bw.print("vec{d}<f32>(", .{n});
                    for (vals, 0..) |v, i| {
                        if (i > 0) try bw.writeAll(", ");
                        try bw.print("{d}.0", .{v});
                    }
                    try bw.writeByte(')');
                    const res = try buf.toOwnedSlice(aa);
                    break :blk res;
                },
                .F => |vals| blk: {
                    const n = vals.len;
                    if (n == 0) break :blk "";
                    var buf = try std.ArrayList(u8).initCapacity(aa, 0);
                    const bw = ListWriter{ .list = &buf, .alloc = aa };
                    try bw.print("vec{d}<f32>(", .{n});
                    for (vals, 0..) |v, i| {
                        if (i > 0) try bw.writeAll(", ");
                        if (v == @trunc(v) and @abs(v) < 1e10)
                            try bw.print("{d}.0", .{@as(i64, @intFromFloat(v))})
                        else
                            try bw.print("{d}", .{v});
                    }
                    try bw.writeByte(')');
                    const res = try buf.toOwnedSlice(aa);
                    break :blk res;
                },
                .s => |name| blk: {
                    const rgba = colorFromName(name) orelse return error.UnknownColor;
                    break :blk try std.fmt.allocPrint(aa, "vec4<f32>({d:.4}, {d:.4}, {d:.4}, {d:.4})", .{
                        @as(f32, @floatFromInt(rgba.r)) / 255.0,
                        @as(f32, @floatFromInt(rgba.g)) / 255.0,
                        @as(f32, @floatFromInt(rgba.b)) / 255.0,
                        @as(f32, @floatFromInt(rgba.a)) / 255.0,
                    });
                },
                .@"var" => |name| name,
                else => return error.UnsupportedNode,
            },

            .group => |g| try self.emitExpr(g.stmt, scope, w, tc, aa),

            .transit => |t| blk: {
                const verb = if (t.v.* == .verb_op) t.v.verb_op
                else if (t.v.* == .verb_io) t.v.verb_io
                else break :blk error.UnsupportedVerb;

                if (std.mem.eql(u8, verb, ",")) {
                    const ta = try self.inferType(t.a, scope);
                    const tb = try self.inferType(t.b, scope);
                    const ea = try self.emitExpr(t.a, scope, w, tc, aa);
                    const eb = try self.emitExpr(t.b, scope, w, tc, aa);
                    if (ta == .vec4f and tb == .f32) {
                        break :blk try std.fmt.allocPrint(aa, "vec4<f32>(({s}).xyz, {s})", .{ ea, eb });
                    }
                    const n = ta.size() + tb.size();
                    break :blk try std.fmt.allocPrint(aa, "vec{d}<f32>({s}, {s})", .{ n, ea, eb });
                }

                const ea = try self.emitExpr(t.a, scope, w, tc, aa);
                const eb = try self.emitExpr(t.b, scope, w, tc, aa);

                if (dyadicInfix(verb)) |op| {
                    break :blk try std.fmt.allocPrint(aa, "({s} {s} {s})", .{ ea, op, eb });
                }
                if (dyadicFn(verb)) |fname| {
                    break :blk try std.fmt.allocPrint(aa, "{s}({s}, {s})", .{ fname, ea, eb });
                }
                break :blk try std.fmt.allocPrint(aa, "{s}({s}, {s})", .{ verb, ea, eb });
            },

            .intrans => |i| blk: {
                if (i.v.* == .verb_op or i.v.* == .verb_io) {
                    const verb = if (i.v.* == .verb_op) i.v.verb_op else i.v.verb_io;
                    const ea = try self.emitExpr(i.a, scope, w, tc, aa);
                    if (std.mem.eql(u8, verb, "-")) {
                        break :blk try std.fmt.allocPrint(aa, "(-{s})", .{ea});
                    }
                    if (monadicFn(verb)) |fname| {
                        break :blk try std.fmt.allocPrint(aa, "{s}({s})", .{ fname, ea });
                    }
                }
                const ef = try self.emitExpr(i.v, scope, w, tc, aa);
                const ea = try self.emitExpr(i.a, scope, w, tc, aa);
                break :blk try std.fmt.allocPrint(aa, "{s}({s})", .{ ef, ea });
            },

            .prefix => |p| blk: {
                if (std.mem.eql(u8, p.v, ".")) {
                    if (p.a.* == .literal and p.a.literal == .s) {
                        const sym = p.a.literal.s;
                        if (std.mem.eql(u8, sym, "resolution")) break :blk "u_view.viewSize";
                        if (std.mem.eql(u8, sym, "time")) break :blk "0.0";
                        const rgba = colorFromName(sym) orelse return error.UnknownColor;
                        break :blk try std.fmt.allocPrint(aa, "vec4<f32>({d:.4}, {d:.4}, {d:.4}, {d:.4})", .{
                            @as(f32, @floatFromInt(rgba.r)) / 255.0,
                            @as(f32, @floatFromInt(rgba.g)) / 255.0,
                            @as(f32, @floatFromInt(rgba.b)) / 255.0,
                            @as(f32, @floatFromInt(rgba.a)) / 255.0,
                        });
                    }
                }
                const ea = try self.emitExpr(p.a, scope, w, tc, aa);
                if (monadicFn(p.v)) |fname| {
                    break :blk try std.fmt.allocPrint(aa, "{s}({s})", .{ fname, ea });
                }
                if (std.mem.eql(u8, p.v, "-")) {
                    break :blk try std.fmt.allocPrint(aa, "(-{s})", .{ea});
                }
                break :blk try std.fmt.allocPrint(aa, "{s}({s})", .{ p.v, ea });
            },

            .apposit => |ap| blk: {
                // .`symbol — parser may produce apposit{f=verb_op("."), a=symbol} instead of prefix
                const f_is_dot = switch (ap.f.*) {
                    .literal => |lit| lit == .@"var" and std.mem.eql(u8, lit.@"var", "."),
                    .verb_op => |op| std.mem.eql(u8, op, "."),
                    .verb_io => |io| std.mem.eql(u8, io, "."),
                    else => false,
                };
                if (f_is_dot and ap.a.* == .literal and ap.a.literal == .s) {
                    const sym = ap.a.literal.s;
                    if (std.mem.eql(u8, sym, "resolution")) break :blk "u_view.viewSize";
                    if (std.mem.eql(u8, sym, "time")) break :blk "0.0";
                    const rgba = colorFromName(sym) orelse return error.UnknownColor;
                    break :blk try std.fmt.allocPrint(aa, "vec4<f32>({d:.4}, {d:.4}, {d:.4}, {d:.4})", .{
                        @as(f32, @floatFromInt(rgba.r)) / 255.0,
                        @as(f32, @floatFromInt(rgba.g)) / 255.0,
                        @as(f32, @floatFromInt(rgba.b)) / 255.0,
                        @as(f32, @floatFromInt(rgba.a)) / 255.0,
                    });
                }
                const tf = self.inferType(ap.f, scope) catch .unknown;
                const ta = self.inferType(ap.a, scope) catch .unknown;

                if (tf == .f32 and ta == .f32) {
                    const ef = try self.emitExpr(ap.f, scope, w, tc, aa);
                    const ea = try self.emitExpr(ap.a, scope, w, tc, aa);
                    break :blk try std.fmt.allocPrint(aa, "vec2<f32>({s}, {s})", .{ ef, ea });
                }
                if ((tf == .vec2f or tf == .vec3f) and ta == .f32) {
                    const n = tf.size() + 1;
                    const ef = try self.emitExpr(ap.f, scope, w, tc, aa);
                    const ea = try self.emitExpr(ap.a, scope, w, tc, aa);
                    break :blk try std.fmt.allocPrint(aa, "vec{d}<f32>({s}, {s})", .{ n, ef, ea });
                }

                const ef = try self.emitExpr(ap.f, scope, w, tc, aa);
                const ea = try self.emitExpr(ap.a, scope, w, tc, aa);
                break :blk try std.fmt.allocPrint(aa, "{s}({s})", .{ ef, ea });
            },

            .apply => |ap| blk: {
                if (ap.a) |args| {
                    if (args.len == 1 and args[0].* == .literal) {
                        const lit = args[0].literal;
                        if (lit == .I) {
                            const comps = [_]u8{ 'x', 'y', 'z', 'w' };
                            const ef = try self.emitExpr(ap.f, scope, w, tc, aa);
                            var swiz = try std.ArrayList(u8).initCapacity(aa, 0);
                            try swiz.append(aa, '.');
                            for (lit.I) |idx| {
                                if (idx >= 0 and idx < 4) try swiz.append(aa, comps[@intCast(idx)]);
                            }
                            const swiz_str = try swiz.toOwnedSlice(aa);
                            break :blk try std.fmt.allocPrint(aa, "{s}{s}", .{ ef, swiz_str });
                        } else if (lit == .i) {
                            const ef = try self.emitExpr(ap.f, scope, w, tc, aa);
                            break :blk try std.fmt.allocPrint(aa, "{s}[{d}]", .{ ef, lit.i });
                        }
                    }
                }

                const ef = try self.emitExpr(ap.f, scope, w, tc, aa);
                var buf = try std.ArrayList(u8).initCapacity(aa, 0);
                const bw = ListWriter{ .list = &buf, .alloc = aa };
                try bw.writeAll(ef);
                try bw.writeByte('(');
                if (ap.a) |args| {
                    for (args, 0..) |arg, i| {
                        if (i > 0) try bw.writeAll(", ");
                        const ea = try self.emitExpr(arg, scope, w, tc, aa);
                        try bw.writeAll(ea);
                    }
                }
                try bw.writeByte(')');
                const res = try buf.toOwnedSlice(aa);
                break :blk res;
            },

            .list => |l| blk: {
                const seq = l.seq orelse break :blk "vec2<f32>(0.0, 0.0)";
                if (seq.len == 0) break :blk "";
                var buf = try std.ArrayList(u8).initCapacity(aa, 0);
                const bw = ListWriter{ .list = &buf, .alloc = aa };
                try bw.print("vec{d}<f32>(", .{seq.len});
                for (seq, 0..) |elem, i| {
                    if (i > 0) try bw.writeAll(", ");
                    const ea = try self.emitExpr(elem, scope, w, tc, aa);
                    try bw.writeAll(ea);
                }
                try bw.writeByte(')');
                const res = try buf.toOwnedSlice(aa);
                break :blk res;
            },

            .cond => |c| blk: {
                if (c.stmts.len < 3) break :blk "false";
                const et = try self.emitExpr(c.stmts[0], scope, w, tc, aa);
                const ea = try self.emitExpr(c.stmts[1], scope, w, tc, aa);
                const eb = try self.emitExpr(c.stmts[2], scope, w, tc, aa);
                break :blk try std.fmt.allocPrint(aa, "select({s}, {s}, {s})", .{ eb, ea, et });
            },

            .bind => |b| blk: {
                break :blk if (b.a) |rhs| try self.emitExpr(rhs, scope, w, tc, aa) else "";
            },

            .right => |r| try self.emitExpr(r.clause, scope, w, tc, aa),
            .compose => |c| switch (c) {
                .v => |v| try self.emitExpr(v, scope, w, tc, aa),
                .fz => |fz| blk: {
                    _ = try self.emitExpr(fz.f, scope, w, tc, aa);
                    break :blk try self.emitExpr(fz.z, scope, w, tc, aa);
                },
            },

            .pending => |p| blk: {
                break :blk try self.emitExpr(p.a, scope, w, tc, aa);
            },

            else => blk: {
                _ = tc.*;
                tc.* += 1;
                break :blk "0.0 /* unsupported */";
            },
        };
    }
};

/// Convenience: parse terse source and transpile to WGSL.
/// Caller owns the returned slice.
pub fn transpileSource(alloc: std.mem.Allocator, source: []const u8) ![]const u8 {
    var parser = ast.Parser.init(alloc);
    defer parser.deinit();

    const root = try parser.parse(source);
    defer parser.free(root);

    var tr = Transpiler.init(alloc);
    defer tr.deinit();

    return try tr.transpile(root);
}

test "circle shader" {
    const alloc = std.testing.allocator;

    const source =
        \\circle: {[uv;pos;rad;color]
        \\  d: length[uv - pos] - rad;
        \\  color
        \\}
        \\{[color;coord]
        \\  uv: coord[0 1];
        \\  center: 0.5 0.5;
        \\  foreground: circle[uv;center;0.3;`red700]
        \\  foreground
        \\}
    ;

    const wgsl = try transpileSource(alloc, source);
    defer alloc.free(wgsl);

    // Basic sanity checks
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "fn circle(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "fn fs_main(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "ViewUniforms") != null);
}

test "color lookup" {
    const rgba = colorFromName("red700").?;
    try std.testing.expect(rgba.r > 100);
    try std.testing.expect(rgba.a == 255);

    const teal = colorFromName("teal200").?;
    try std.testing.expect(teal.b > 100); // teal has significant blue

    try std.testing.expect(colorFromName("notacolor") == null);
    try std.testing.expect(colorFromName("transparent") != null);
}

test "main circle shader" {
    const alloc = std.testing.allocator;
    const source =
        \\{[color;coord]
        \\  res: .`resolution;
        \\  uv: (coord[0 1] - 0.5 * res) % res[1];
        \\  $[0.3 > length[uv]; `Red600; 0 0 0 0]
        \\}
    ;

    const wgsl = try transpileSource(alloc, source);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "u_view.viewSize") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "select") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vec4<f32>(0.9059, 0.0000, 0.0431, 1.0000)") != null);
}
