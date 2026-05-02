//! Cassowary constraint-based layout engine for ink.
//! Implements the Kiwi variant (Badros & Borning 1997, Mykyta 2013).
//!
//! Quick-start:
//!   var layout = try Layout.init(alloc);
//!   defer layout.deinit();
//!
//!   var root = try layout.addView();
//!   try layout.pin(&root.left,   0,   Strength.required);
//!   try layout.pin(&root.top,    0,   Strength.required);
//!   try layout.pin(&root.width,  800, Strength.required);
//!   try layout.pin(&root.height, 600, Strength.required);
//!
//!   var btn = try layout.addView();
//!   try layout.offset(&btn.left, &root.left,  20, Strength.strong);
//!   try layout.offset(&btn.top,  &root.top,   20, Strength.strong);
//!   try layout.pin(&btn.width,  120, Strength.strong);
//!   try layout.pin(&btn.height,  40, Strength.strong);
//!
//!   layout.solve();
//!   const r = layout.frame(btn);  // Rect{ .x=20, .y=20, .w=120, .h=40 }

const std = @import("std");
const Alloc = std.mem.Allocator;

const EPSILON: f64 = 1e-8;

// ── Strengths ────────────────────────────────────────────────────────────────

pub const Strength = struct {
    pub const required: f64 = 1_001_001_000.0;
    pub const strong:   f64 = 1_000_000.0;
    pub const medium:   f64 = 1_000.0;
    pub const weak:     f64 = 1.0;

    pub fn clip(s: f64) f64 {
        return @max(0.0, @min(s, required));
    }
};

// ── Internal symbol types ─────────────────────────────────────────────────────

const SymKind = enum(u2) {
    external, // user-facing variable (value = 0 when non-basic)
    slack,    // one per inequality constraint
    err,      // one per soft constraint (minimised in objective)
    dummy,    // one per required equality (never enters objective)
};

const Sym = packed struct(u32) {
    kind: SymKind,
    id:   u30,

    const nil: Sym = .{ .kind = .dummy, .id = 0 };

    fn isNil(s: Sym)        bool { return s.id == 0; }
    fn isPivotable(s: Sym)  bool { return s.kind == .slack or s.kind == .err; }
    fn isRestricted(s: Sym) bool { return s.kind != .external; }
};

const SymCtx = struct {
    pub fn hash(_: SymCtx, s: Sym) u64  { return @as(u32, @bitCast(s)); }
    pub fn eql(_: SymCtx, a: Sym, b: Sym) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

// ── Tableau row ───────────────────────────────────────────────────────────────
//
// Semantics: 0 = constant + Σ(cells[s] * s)
// The basic variable for this row is the key in Solver.rows — not in cells.

const Row = struct {
    cells:    std.HashMap(Sym, f64, SymCtx, 80),
    constant: f64,

    fn init(alloc: Alloc, constant: f64) Row {
        return .{ .cells = std.HashMap(Sym, f64, SymCtx, 80).init(alloc), .constant = constant };
    }

    fn deinit(self: *Row) void { self.cells.deinit(); }

    fn clone(self: *const Row, alloc: Alloc) !Row {
        var r = Row.init(alloc, self.constant);
        var it = self.cells.iterator();
        while (it.next()) |e| try r.cells.put(e.key_ptr.*, e.value_ptr.*);
        return r;
    }

    fn add(self: *Row, s: Sym, c: f64) !void {
        const gop = try self.cells.getOrPut(s);
        if (gop.found_existing) {
            gop.value_ptr.* += c;
            if (@abs(gop.value_ptr.*) < EPSILON) _ = self.cells.remove(s);
        } else {
            gop.value_ptr.* = c;
        }
    }

    fn insertRow(self: *Row, other: *const Row, coeff: f64) !void {
        self.constant += coeff * other.constant;
        var it = other.cells.iterator();
        while (it.next()) |e| try self.add(e.key_ptr.*, coeff * e.value_ptr.*);
    }

    fn reverseSign(self: *Row) void {
        self.constant = -self.constant;
        var it = self.cells.iterator();
        while (it.next()) |e| e.value_ptr.* = -e.value_ptr.*;
    }

    // Isolate s: row becomes the parametric expression for s.
    fn solveFor(self: *Row, s: Sym) void {
        const c = self.cells.get(s) orelse return;
        _ = self.cells.remove(s);
        const inv = -1.0 / c;
        self.constant *= inv;
        var it = self.cells.iterator();
        while (it.next()) |e| e.value_ptr.* *= inv;
    }

    // Pivot lhs out and rhs in: add lhs*1 to the row, then solve for rhs.
    fn pivot(self: *Row, lhs: Sym, rhs: Sym) !void {
        try self.add(lhs, 1.0);
        self.solveFor(rhs);
    }

    fn coeffFor(self: *const Row, s: Sym) f64 { return self.cells.get(s) orelse 0.0; }

    fn substitute(self: *Row, s: Sym, row: *const Row) !void {
        const c = self.cells.get(s) orelse return;
        _ = self.cells.remove(s);
        try self.insertRow(row, c);
    }
};

// ── Public types ──────────────────────────────────────────────────────────────

pub const Variable = struct {
    id:    u32,
    value: f64 = 0.0,
    name:  ?[]const u8 = null,
};

pub const Term = struct {
    variable:    *Variable,
    coefficient: f64 = 1.0,
};

pub const Expression = struct {
    terms:    []const Term,
    constant: f64 = 0.0,
};

pub const Relation = enum { eq, leq, geq };

pub const Constraint = struct {
    expression: Expression,
    relation:   Relation,
    strength:   f64,
};

const Tag = struct { marker: Sym, other: Sym };

// ── Solver ────────────────────────────────────────────────────────────────────

pub const SolverError = error{
    DuplicateConstraint,
    UnknownConstraint,
    UnsatisfiableConstraint,
    InternalError,
    OutOfMemory,
};

pub const Solver = struct {
    alloc:       Alloc,
    rows:        std.HashMap(Sym, Row, SymCtx, 80),
    vars:        std.AutoHashMap(*Variable, Sym),
    tags:        std.AutoHashMap(*const Constraint, Tag),
    infeasible:  std.ArrayList(Sym),
    objective:   Row,
    sym_id:      u32 = 0,

    pub fn init(alloc: Alloc) !Solver {
        return .{
            .alloc      = alloc,
            .rows       = std.HashMap(Sym, Row, SymCtx, 80).init(alloc),
            .vars       = std.AutoHashMap(*Variable, Sym).init(alloc),
            .tags       = std.AutoHashMap(*const Constraint, Tag).init(alloc),
            .infeasible = std.ArrayList(Sym).init(alloc),
            .objective  = Row.init(alloc, 0.0),
        };
    }

    pub fn deinit(self: *Solver) void {
        var it = self.rows.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        self.rows.deinit();
        self.vars.deinit();
        self.tags.deinit();
        self.infeasible.deinit();
        self.objective.deinit();
    }

    fn newSym(self: *Solver, kind: SymKind) Sym {
        self.sym_id += 1;
        return .{ .kind = kind, .id = @intCast(self.sym_id) };
    }

    fn getVarSym(self: *Solver, v: *Variable) !Sym {
        const gop = try self.vars.getOrPut(v);
        if (!gop.found_existing) gop.value_ptr.* = self.newSym(.external);
        return gop.value_ptr.*;
    }

    fn buildRow(self: *Solver, c: *const Constraint) !struct { row: Row, tag: Tag } {
        var row = Row.init(self.alloc, c.expression.constant);
        var tag = Tag{ .marker = Sym.nil, .other = Sym.nil };

        for (c.expression.terms) |t| {
            const sym = try self.getVarSym(t.variable);
            if (self.rows.getPtr(sym)) |basic|
                try row.insertRow(basic, t.coefficient)
            else
                try row.add(sym, t.coefficient);
        }

        switch (c.relation) {
            .leq, .geq => {
                const coeff: f64 = if (c.relation == .leq) 1.0 else -1.0;
                const slack = self.newSym(.slack);
                tag.marker = slack;
                try row.add(slack, coeff);
                if (c.strength < Strength.required) {
                    const err_sym = self.newSym(.err);
                    tag.other = err_sym;
                    try row.add(err_sym, -coeff);
                    try self.objective.add(err_sym, c.strength);
                }
            },
            .eq => {
                if (c.strength >= Strength.required) {
                    const dummy = self.newSym(.dummy);
                    tag.marker = dummy;
                    tag.other  = dummy;
                    try row.add(dummy, 1.0);
                } else {
                    const em = self.newSym(.err);
                    const ep = self.newSym(.err);
                    tag.marker = em;
                    tag.other  = ep;
                    try row.add(em, -1.0);
                    try row.add(ep,  1.0);
                    try self.objective.add(em, c.strength);
                    try self.objective.add(ep, c.strength);
                }
            },
        }

        if (row.constant < 0.0) {
            row.reverseSign();
            const tmp  = tag.marker;
            tag.marker = tag.other;
            tag.other  = tmp;
        }

        return .{ .row = row, .tag = tag };
    }

    // Prefer external variables, then restricted with negative coefficient.
    fn chooseSubject(self: *Solver, row: *const Row, tag: Tag) Sym {
        _ = self;
        var restricted: Sym = Sym.nil;
        var it = row.cells.iterator();
        while (it.next()) |e| {
            switch (e.key_ptr.kind) {
                .external              => return e.key_ptr.*,
                .slack, .err           => {
                    if (e.value_ptr.* < 0.0 and restricted.isNil())
                        restricted = e.key_ptr.*;
                },
                else                   => {},
            }
        }
        if (!restricted.isNil()) return restricted;
        if (tag.marker.isPivotable() and row.coeffFor(tag.marker) < 0.0) return tag.marker;
        if (tag.other.isPivotable()  and row.coeffFor(tag.other)  < 0.0) return tag.other;
        return Sym.nil;
    }

    fn allDummies(row: *const Row) bool {
        var it = row.cells.iterator();
        while (it.next()) |e| if (e.key_ptr.kind != .dummy) return false;
        return true;
    }

    fn substituteAll(self: *Solver, s: Sym, row: *const Row) !void {
        var it = self.rows.iterator();
        while (it.next()) |e| {
            try e.value_ptr.substitute(s, row);
            if (e.key_ptr.isRestricted() and e.value_ptr.constant < 0.0)
                try self.infeasible.append(e.key_ptr.*);
        }
        try self.objective.substitute(s, row);
    }

    // Simplex: minimise `objective` by pivoting restricted rows.
    // External variables never leave the basis.
    fn optimizeObj(self: *Solver, objective: *Row) !void {
        while (true) {
            var entering = Sym.nil;
            var min_c: f64 = -EPSILON;
            var oit = objective.cells.iterator();
            while (oit.next()) |e| {
                if (e.key_ptr.isPivotable() and e.value_ptr.* < min_c) {
                    min_c    = e.value_ptr.*;
                    entering = e.key_ptr.*;
                }
            }
            if (entering.isNil()) return;

            var leaving = Sym.nil;
            var min_r: f64 = std.math.floatMax(f64);
            var rit = self.rows.iterator();
            while (rit.next()) |e| {
                if (e.key_ptr.kind == .external) continue;
                const c = e.value_ptr.coeffFor(entering);
                if (c >= 0.0) continue;
                const r = -e.value_ptr.constant / c;
                if (r < min_r) { min_r = r; leaving = e.key_ptr.*; }
            }
            if (leaving.isNil()) return SolverError.InternalError;

            var prow = self.rows.fetchRemove(leaving).?.value;
            try prow.pivot(leaving, entering);
            try self.substituteAll(entering, &prow);
            try self.rows.put(entering, prow);
        }
    }

    fn optimize(self: *Solver) !void { try self.optimizeObj(&self.objective); }

    // Dual simplex to restore feasibility after edit-variable suggestions.
    fn dualOptimize(self: *Solver) !void {
        while (self.infeasible.items.len > 0) {
            const leaving = self.infeasible.pop();
            const row = self.rows.getPtr(leaving) orelse continue;
            if (row.constant >= 0.0) continue;

            var entering = Sym.nil;
            var min_r: f64 = std.math.floatMax(f64);
            var it = row.cells.iterator();
            while (it.next()) |e| {
                if (!e.key_ptr.isPivotable() or e.value_ptr.* <= 0.0) continue;
                const r = self.objective.coeffFor(e.key_ptr.*) / e.value_ptr.*;
                if (r < min_r) { min_r = r; entering = e.key_ptr.*; }
            }
            if (entering.isNil()) return SolverError.InternalError;

            var prow = self.rows.fetchRemove(leaving).?.value;
            try prow.pivot(leaving, entering);
            try self.substituteAll(entering, &prow);
            try self.rows.put(entering, prow);
        }
    }

    // Phase-1: add row via an artificial variable, return false if infeasible.
    fn addWithArtificial(self: *Solver, row: *Row) !bool {
        const art = self.newSym(.err);
        var art_obj = try row.clone(self.alloc);
        defer art_obj.deinit();

        // art becomes basic for this row
        try self.rows.put(art, row.*);
        row.* = Row.init(self.alloc, 0.0); // caller must not deinit the old cells

        try self.optimizeObj(&art_obj);
        const ok = @abs(art_obj.constant) < EPSILON;

        if (self.rows.fetchRemove(art)) |kv| {
            var art_row = kv.value;
            if (art_row.cells.count() != 0) {
                var it = art_row.cells.iterator();
                var ep: Sym = Sym.nil;
                while (it.next()) |e| {
                    if (e.key_ptr.isPivotable()) { ep = e.key_ptr.*; break; }
                }
                if (!ep.isNil()) {
                    try art_row.pivot(art, ep);
                    try self.substituteAll(ep, &art_row);
                    try self.rows.put(ep, art_row);
                } else {
                    art_row.deinit();
                }
            } else {
                art_row.deinit();
            }
        }

        // Scrub art from all remaining rows and objective
        {
            var it = self.rows.iterator();
            while (it.next()) |e| _ = e.value_ptr.cells.remove(art);
        }
        _ = self.objective.cells.remove(art);

        return ok;
    }

    pub fn addConstraint(self: *Solver, c: *const Constraint) !void {
        if (self.tags.contains(c)) return SolverError.DuplicateConstraint;

        const res = try self.buildRow(c);
        var row  = res.row;
        const tag = res.tag;

        var subject = self.chooseSubject(&row, tag);

        if (subject.isNil() and allDummies(&row)) {
            if (@abs(row.constant) > EPSILON) {
                row.deinit();
                return SolverError.UnsatisfiableConstraint;
            }
            subject = tag.marker;
        }

        if (subject.isNil()) {
            if (!try self.addWithArtificial(&row)) {
                row.deinit();
                return SolverError.UnsatisfiableConstraint;
            }
        } else {
            row.solveFor(subject);
            try self.substituteAll(subject, &row);
            try self.rows.put(subject, row);
        }

        try self.tags.put(c, tag);
        try self.optimize();
    }

    pub fn removeConstraint(self: *Solver, c: *const Constraint) !void {
        const tag = self.tags.get(c) orelse return SolverError.UnknownConstraint;
        _ = self.tags.remove(c);

        // Undo error contributions to the objective.
        if (tag.other.kind == .err) {
            if (self.rows.getPtr(tag.other)) |r| r.constant -= c.strength
            else try self.objective.add(tag.other, -c.strength);
        }
        const marker_is_err = tag.marker.kind == .err;
        const same = @as(u32, @bitCast(tag.marker)) == @as(u32, @bitCast(tag.other));
        if (marker_is_err and !same) {
            if (self.rows.getPtr(tag.marker)) |r| r.constant -= c.strength
            else try self.objective.add(tag.marker, -c.strength);
        }

        if (self.rows.fetchRemove(tag.marker)) |kv| {
            // Marker was basic — just drop its row.
            var r = kv.value;
            r.deinit();
        } else {
            // Find a row to pivot the marker out through.
            var leaving = Sym.nil;
            var min_r: f64 = std.math.floatMax(f64);
            var it = self.rows.iterator();
            while (it.next()) |e| {
                const c2 = e.value_ptr.coeffFor(tag.marker);
                if (c2 < 0.0) {
                    const r = -e.value_ptr.constant / c2;
                    if (r < min_r) { min_r = r; leaving = e.key_ptr.*; }
                }
            }
            if (leaving.isNil()) {
                var it2 = self.rows.iterator();
                while (it2.next()) |e| {
                    if (e.value_ptr.coeffFor(tag.marker) > 0.0) {
                        leaving = e.key_ptr.*;
                        break;
                    }
                }
            }
            if (leaving.isNil()) return SolverError.InternalError;

            var prow = self.rows.fetchRemove(leaving).?.value;
            try prow.pivot(leaving, tag.marker);
            try self.substituteAll(tag.marker, &prow);
            prow.deinit(); // marker is gone; row is discarded
        }

        try self.optimize();
    }

    /// Copy solved values back into all Variable structs.
    pub fn updateVariables(self: *Solver) void {
        var it = self.vars.iterator();
        while (it.next()) |e| {
            const v   = e.key_ptr.*;
            const sym = e.value_ptr.*;
            v.value = if (self.rows.get(sym)) |r| r.constant else 0.0;
        }
    }
};

// ── Rect and View ─────────────────────────────────────────────────────────────

pub const Rect = struct {
    x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0,

    pub fn right(r: Rect) f32  { return r.x + r.w; }
    pub fn bottom(r: Rect) f32 { return r.y + r.h; }
    pub fn cx(r: Rect) f32     { return r.x + r.w * 0.5; }
    pub fn cy(r: Rect) f32     { return r.y + r.h * 0.5; }
    pub fn inset(r: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w - dx * 2, .h = r.h - dy * 2 };
    }
};

/// A rectangular element. Each edge/dimension is a separate Variable so
/// any of them can participate in constraints directly.
pub const View = struct {
    left:   Variable,
    top:    Variable,
    width:  Variable,
    height: Variable,
    right:  Variable,  // constrained: right  = left  + width
    bottom: Variable,  // constrained: bottom = top   + height

    fn init(base_id: u32) View {
        return .{
            .left   = .{ .id = base_id + 0 },
            .top    = .{ .id = base_id + 1 },
            .width  = .{ .id = base_id + 2 },
            .height = .{ .id = base_id + 3 },
            .right  = .{ .id = base_id + 4 },
            .bottom = .{ .id = base_id + 5 },
        };
    }
};

// ── High-level Layout ─────────────────────────────────────────────────────────

pub const Layout = struct {
    alloc:       Alloc,
    solver:      Solver,
    views:       std.ArrayList(*View),
    constraints: std.ArrayList(*Constraint),
    var_id:      u32 = 0,

    pub fn init(alloc: Alloc) !Layout {
        return .{
            .alloc       = alloc,
            .solver      = try Solver.init(alloc),
            .views       = std.ArrayList(*View).init(alloc),
            .constraints = std.ArrayList(*Constraint).init(alloc),
        };
    }

    pub fn deinit(self: *Layout) void {
        for (self.views.items) |v| self.alloc.destroy(v);
        self.views.deinit();
        for (self.constraints.items) |c| {
            self.alloc.free(c.expression.terms);
            self.alloc.destroy(c);
        }
        self.constraints.deinit();
        self.solver.deinit();
    }

    fn nextId(self: *Layout) u32 {
        self.var_id += 6;
        return self.var_id - 5; // base: var_id was 0 → returns 1
    }

    fn addRaw(self: *Layout, c: Constraint) !void {
        const cp = try self.alloc.create(Constraint);
        cp.* = c;
        try self.constraints.append(cp);
        try self.solver.addConstraint(cp);
    }

    fn termsOf(self: *Layout, ts: []const Term) ![]const Term {
        return self.alloc.dupe(Term, ts);
    }

    /// Allocate a new view; derived edges are immediately constrained.
    pub fn addView(self: *Layout) !*View {
        const base = self.nextId();
        const v = try self.alloc.create(View);
        v.* = View.init(base);
        try self.views.append(v);

        // right = left + width
        try self.addRaw(.{
            .expression = .{
                .terms = try self.termsOf(&.{
                    .{ .variable = &v.right,  .coefficient =  1.0 },
                    .{ .variable = &v.left,   .coefficient = -1.0 },
                    .{ .variable = &v.width,  .coefficient = -1.0 },
                }),
                .constant = 0.0,
            },
            .relation = .eq,
            .strength = Strength.required,
        });

        // bottom = top + height
        try self.addRaw(.{
            .expression = .{
                .terms = try self.termsOf(&.{
                    .{ .variable = &v.bottom,  .coefficient =  1.0 },
                    .{ .variable = &v.top,     .coefficient = -1.0 },
                    .{ .variable = &v.height,  .coefficient = -1.0 },
                }),
                .constant = 0.0,
            },
            .relation = .eq,
            .strength = Strength.required,
        });

        return v;
    }

    /// v = value
    pub fn pin(self: *Layout, v: *Variable, value: f64, strength: f64) !void {
        try self.addRaw(.{
            .expression = .{
                .terms    = try self.termsOf(&.{.{ .variable = v, .coefficient = 1.0 }}),
                .constant = -value,
            },
            .relation = .eq,
            .strength = strength,
        });
    }

    /// a = b
    pub fn equal(self: *Layout, a: *Variable, b: *Variable, strength: f64) !void {
        try self.addRaw(.{
            .expression = .{
                .terms = try self.termsOf(&.{
                    .{ .variable = a, .coefficient =  1.0 },
                    .{ .variable = b, .coefficient = -1.0 },
                }),
                .constant = 0.0,
            },
            .relation = .eq,
            .strength = strength,
        });
    }

    /// a = b + off
    pub fn offset(self: *Layout, a: *Variable, b: *Variable, off: f64, strength: f64) !void {
        try self.addRaw(.{
            .expression = .{
                .terms = try self.termsOf(&.{
                    .{ .variable = a, .coefficient =  1.0 },
                    .{ .variable = b, .coefficient = -1.0 },
                }),
                .constant = -off,
            },
            .relation = .eq,
            .strength = strength,
        });
    }

    /// a.left = b.right + gap  (a is placed to the right of b)
    pub fn spaceRight(self: *Layout, a: *View, b: *View, gap: f64, strength: f64) !void {
        try self.offset(&a.left, &b.right, gap, strength);
    }

    /// a.top = b.bottom + gap  (a is placed below b)
    pub fn spaceBelow(self: *Layout, a: *View, b: *View, gap: f64, strength: f64) !void {
        try self.offset(&a.top, &b.bottom, gap, strength);
    }

    /// a.width = ratio * b.width
    pub fn widthRatio(self: *Layout, a: *View, ratio: f64, b: *View, strength: f64) !void {
        try self.addRaw(.{
            .expression = .{
                .terms = try self.termsOf(&.{
                    .{ .variable = &a.width, .coefficient =  1.0 },
                    .{ .variable = &b.width, .coefficient = -ratio },
                }),
                .constant = 0.0,
            },
            .relation = .eq,
            .strength = strength,
        });
    }

    /// a.height = ratio * b.height
    pub fn heightRatio(self: *Layout, a: *View, ratio: f64, b: *View, strength: f64) !void {
        try self.addRaw(.{
            .expression = .{
                .terms = try self.termsOf(&.{
                    .{ .variable = &a.height, .coefficient =  1.0 },
                    .{ .variable = &b.height, .coefficient = -ratio },
                }),
                .constant = 0.0,
            },
            .relation = .eq,
            .strength = strength,
        });
    }

    /// inner sits inside outer with uniform padding on all sides.
    pub fn contain(self: *Layout, inner: *View, outer: *View, pad: f64, strength: f64) !void {
        // inner.left >= outer.left + pad
        try self.addRaw(.{
            .expression = .{
                .terms    = try self.termsOf(&.{
                    .{ .variable = &inner.left, .coefficient =  1.0 },
                    .{ .variable = &outer.left, .coefficient = -1.0 },
                }),
                .constant = -pad,
            },
            .relation = .geq,
            .strength = strength,
        });
        // inner.top >= outer.top + pad
        try self.addRaw(.{
            .expression = .{
                .terms    = try self.termsOf(&.{
                    .{ .variable = &inner.top, .coefficient =  1.0 },
                    .{ .variable = &outer.top, .coefficient = -1.0 },
                }),
                .constant = -pad,
            },
            .relation = .geq,
            .strength = strength,
        });
        // outer.right >= inner.right + pad
        try self.addRaw(.{
            .expression = .{
                .terms    = try self.termsOf(&.{
                    .{ .variable = &outer.right,  .coefficient =  1.0 },
                    .{ .variable = &inner.right,  .coefficient = -1.0 },
                }),
                .constant = -pad,
            },
            .relation = .geq,
            .strength = strength,
        });
        // outer.bottom >= inner.bottom + pad
        try self.addRaw(.{
            .expression = .{
                .terms    = try self.termsOf(&.{
                    .{ .variable = &outer.bottom, .coefficient =  1.0 },
                    .{ .variable = &inner.bottom, .coefficient = -1.0 },
                }),
                .constant = -pad,
            },
            .relation = .geq,
            .strength = strength,
        });
    }

    /// Solve all constraints and update variable values.
    pub fn solve(self: *Layout) void {
        self.solver.updateVariables();
    }

    /// Solved frame of a view (call after solve()).
    pub fn frame(self: *const Layout, v: *const View) Rect {
        _ = self;
        return .{
            .x = @floatCast(v.left.value),
            .y = @floatCast(v.top.value),
            .w = @floatCast(v.width.value),
            .h = @floatCast(v.height.value),
        };
    }
};

// ── Gx integration ────────────────────────────────────────────────────────────

const Gx = @import("paint.zig").Gx;

/// Draw every view's frame as a rectangle path (caller sets fill/stroke).
pub fn drawViews(gx: *Gx, layout: *const Layout) !void {
    for (layout.views.items) |v| {
        const r = layout.frame(v);
        try gx.rect(r.x, r.y, r.w, r.h);
    }
}

/// Draw a single view frame.
pub fn drawView(gx: *Gx, layout: *const Layout, v: *const View) !void {
    const r = layout.frame(v);
    try gx.rect(r.x, r.y, r.w, r.h);
}
