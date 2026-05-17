//! AOT stencil extractor for the copy-and-patch JIT.
//!
//! Reads a relocatable Mach-O object file (compiled at ReleaseFast),
//! walks the __text section's symbol table and relocation entries,
//! and emits a generated Zig file containing the raw machine code of
//! every `stencil_*` symbol along with the offsets and kinds of every
//! relocation ("hole") inside it.
//!
//! Invocation:
//!     extract_stencils <input.o> <output.zig>
//!
//! The output file is consumed by the JIT runtime; it has no dependency
//! on the rest of the build other than `std`.
//!
//! ELF (x86_64, linux) support is structured-but-stubbed: the
//! `Backend` interface lets us add an ELF parser without touching the
//! emit/run path. The arm64-macos path is exercised end-to-end first.

const std = @import("std");

const Hole = struct {
    /// Byte offset of the hole within the stencil's machine code.
    offset: u32,
    /// What kind of patch this is. Maps directly to the ARM64 (or x86_64)
    /// relocation type. Each kind determines how the JIT writes the patch.
    kind: Kind,
    /// What the hole points at: a chain continuation, an operand slot,
    /// or a runtime helper function.
    target: Target,
    /// Symbol name from the object file. For Target.external this is the
    /// name of a runtime function to look up. For hole targets it is the
    /// raw symbol from stencils_src.zig (informational).
    symbol: []const u8,

    const Kind = enum {
        /// arm64: 26-bit PC-relative signed displacement (`b` / `bl`).
        branch26,
        /// arm64: ADRP page21 — top 21 bits of a PC-relative page address.
        page21,
        /// arm64: LDR / ADD pageoff12 — bottom 12 bits within the page.
        pageoff12,
    };

    const Target = enum {
        next,     // __ink_hole_next
        taken,    // __ink_hole_taken
        operand,  // __ink_hole_operand (Option A data slot)
        external, // a real runtime function the JIT links at patch time
    };
};

const Stencil = struct {
    name: []const u8,           // user-visible (no leading _ or stencil_ prefix)
    raw_symbol: []const u8,     // exact Mach-O symbol (e.g. "_stencil_add_ii")
    bytes: []const u8,          // raw machine code from __text
    holes: []const Hole,
    is_terminal: bool,
};

// ── Mach-O reader ─────────────────────────────────────────────────────────────

const macho = std.macho;

const TextSection = struct {
    /// File offset of __text's content.
    file_offset: u32,
    /// Size of __text in bytes.
    size: u32,
    /// File offset of __text's relocation array.
    reloff: u32,
    /// Number of relocation entries.
    nreloc: u32,
};

const SymTab = struct {
    string_table: []const u8,
    symbols: []const macho.nlist_64,
};

const MachoView = struct {
    bytes: []const u8,
    header: *const macho.mach_header_64,

    fn init(bytes: []const u8) !MachoView {
        if (bytes.len < @sizeOf(macho.mach_header_64)) return error.TooSmall;
        const h: *const macho.mach_header_64 = @ptrCast(@alignCast(bytes.ptr));
        if (h.magic != macho.MH_MAGIC_64) return error.NotMacho64;
        if (h.filetype != macho.MH_OBJECT) return error.NotObjectFile;
        return .{ .bytes = bytes, .header = h };
    }

    /// Walk LC_SEGMENT_64 / __TEXT / __text section to find code + relocs.
    fn findTextSection(self: MachoView) !TextSection {
        var cmd_offset: usize = @sizeOf(macho.mach_header_64);
        var i: u32 = 0;
        while (i < self.header.ncmds) : (i += 1) {
            const lc: *const macho.load_command = @ptrCast(@alignCast(self.bytes.ptr + cmd_offset));
            if (lc.cmd == macho.LC.SEGMENT_64) {
                const seg: *const macho.segment_command_64 =
                    @ptrCast(@alignCast(self.bytes.ptr + cmd_offset));
                const sections_offset = cmd_offset + @sizeOf(macho.segment_command_64);
                var s: u32 = 0;
                while (s < seg.nsects) : (s += 1) {
                    const sect: *const macho.section_64 =
                        @ptrCast(@alignCast(self.bytes.ptr + sections_offset +
                            s * @sizeOf(macho.section_64)));
                    if (sectionNameEq(&sect.sectname, "__text") and
                        sectionNameEq(&sect.segname, "__TEXT"))
                    {
                        return .{
                            .file_offset = sect.offset,
                            .size = @intCast(sect.size),
                            .reloff = sect.reloff,
                            .nreloc = sect.nreloc,
                        };
                    }
                }
            }
            cmd_offset += lc.cmdsize;
        }
        return error.NoTextSection;
    }

    fn findSymtab(self: MachoView) !SymTab {
        var cmd_offset: usize = @sizeOf(macho.mach_header_64);
        var i: u32 = 0;
        while (i < self.header.ncmds) : (i += 1) {
            const lc: *const macho.load_command = @ptrCast(@alignCast(self.bytes.ptr + cmd_offset));
            if (lc.cmd == macho.LC.SYMTAB) {
                const sc: *const macho.symtab_command =
                    @ptrCast(@alignCast(self.bytes.ptr + cmd_offset));
                const string_table = self.bytes[sc.stroff .. sc.stroff + sc.strsize];
                const sym_bytes = self.bytes[sc.symoff..];
                const sym_count = sc.nsyms;
                const symbols_ptr: [*]const macho.nlist_64 =
                    @ptrCast(@alignCast(sym_bytes.ptr));
                return .{
                    .string_table = string_table,
                    .symbols = symbols_ptr[0..sym_count],
                };
            }
            cmd_offset += lc.cmdsize;
        }
        return error.NoSymtab;
    }

    fn readRelocs(self: MachoView, ts: TextSection) []const macho.relocation_info {
        const base = self.bytes.ptr + ts.reloff;
        const relocs: [*]const macho.relocation_info = @ptrCast(@alignCast(base));
        return relocs[0..ts.nreloc];
    }

    fn symbolName(self: MachoView, st: SymTab, sym: macho.nlist_64) []const u8 {
        _ = self;
        const start = sym.n_strx;
        if (start >= st.string_table.len) return "";
        const end = std.mem.indexOfScalarPos(u8, st.string_table, start, 0) orelse st.string_table.len;
        return st.string_table[start..end];
    }
};

fn sectionNameEq(name: *const [16]u8, expected: []const u8) bool {
    if (expected.len > 16) return false;
    if (!std.mem.eql(u8, name[0..expected.len], expected)) return false;
    if (expected.len < 16 and name[expected.len] != 0) return false;
    return true;
}

// ── Symbol → Hole.Target mapping ──────────────────────────────────────────────

fn classifyTarget(symbol: []const u8) Hole.Target {
    if (std.mem.eql(u8, symbol, "___ink_hole_next") or
        std.mem.eql(u8, symbol, "__ink_hole_next")) return .next;
    if (std.mem.eql(u8, symbol, "___ink_hole_taken") or
        std.mem.eql(u8, symbol, "__ink_hole_taken")) return .taken;
    if (std.mem.eql(u8, symbol, "___ink_hole_operand") or
        std.mem.eql(u8, symbol, "__ink_hole_operand")) return .operand;
    return .external;
}

fn classifyKind(rt: macho.reloc_type_arm64) !Hole.Kind {
    return switch (rt) {
        .ARM64_RELOC_BRANCH26 => .branch26,
        .ARM64_RELOC_PAGE21, .ARM64_RELOC_GOT_LOAD_PAGE21 => .page21,
        .ARM64_RELOC_PAGEOFF12, .ARM64_RELOC_GOT_LOAD_PAGEOFF12 => .pageoff12,
        else => error.UnsupportedRelocType,
    };
}

// ── Main extraction ───────────────────────────────────────────────────────────

const Found = struct {
    raw: []const u8,         // exact Mach-O symbol incl. leading _
    name: []const u8,        // user-facing (raw with "_stencil_" stripped)
    start: u32,              // byte offset in section
    end: u32,                // exclusive
};

fn extract(alloc: std.mem.Allocator, view: MachoView) ![]Stencil {
    const ts = try view.findTextSection();
    const st = try view.findSymtab();
    const relocs = view.readRelocs(ts);

    // Step 1: collect every exported `_stencil_*` symbol from __text.
    var found_list = try std.ArrayList(Found).initCapacity(alloc, 16);
    defer found_list.deinit(alloc);

    for (st.symbols) |sym| {
        // External, section-defined symbols only.
        if (!sym.n_type.bits.ext) continue;
        if (sym.n_type.bits.type != .sect) continue;
        const name = view.symbolName(st, sym);
        if (!std.mem.startsWith(u8, name, "_stencil_")) continue;
        const offset: u32 = @intCast(sym.n_value);
        try found_list.append(alloc, .{
            .raw = name,
            .name = name["_stencil_".len..],
            .start = offset,
            .end = 0, // computed in step 2
        });
    }

    // Step 2: sort by start offset, fill in `end` as next start (or section end).
    std.mem.sort(Found, found_list.items, {}, struct {
        fn lt(_: void, a: Found, b: Found) bool { return a.start < b.start; }
    }.lt);
    for (found_list.items, 0..) |*f, i| {
        f.end = if (i + 1 < found_list.items.len)
            found_list.items[i + 1].start
        else
            ts.size;
    }

    // Step 3: for each stencil, slice its bytes from the file at section_offset+start.
    //         Then walk relocations whose r_address is within [start, end) and record holes.
    var stencils_list = try std.ArrayList(Stencil).initCapacity(alloc, found_list.items.len);
    errdefer stencils_list.deinit(alloc);

    for (found_list.items) |f| {
        const code_start = ts.file_offset + f.start;
        const code_end = ts.file_offset + f.end;
        const bytes = try alloc.dupe(u8, view.bytes[code_start..code_end]);

        var holes = try std.ArrayList(Hole).initCapacity(alloc, 8);
        errdefer holes.deinit(alloc);

        for (relocs) |r| {
            const addr: u32 = @bitCast(r.r_address);
            if (addr < f.start or addr >= f.end) continue;
            if (r.r_extern != 1) continue;

            const sym = st.symbols[r.r_symbolnum];
            const sym_name = view.symbolName(st, sym);
            const target = classifyTarget(sym_name);
            const rt: macho.reloc_type_arm64 = @enumFromInt(r.r_type);
            const kind = try classifyKind(rt);

            try holes.append(alloc, .{
                .offset = addr - f.start,
                .kind = kind,
                .target = target,
                .symbol = try alloc.dupe(u8, sym_name),
            });
        }

        // Sort holes by offset for stable, easily-inspectable output.
        std.mem.sort(Hole, holes.items, {}, struct {
            fn lt(_: void, a: Hole, b: Hole) bool { return a.offset < b.offset; }
        }.lt);

        // Heuristic: terminal stencils have zero relocations and end with RET
        // (0xD65F03C0 little-endian = 0xC0 0x03 0x5F 0xD6).
        const is_terminal = bytes.len >= 4 and
            bytes[bytes.len - 4] == 0xC0 and
            bytes[bytes.len - 3] == 0x03 and
            bytes[bytes.len - 2] == 0x5F and
            bytes[bytes.len - 1] == 0xD6;

        try stencils_list.append(alloc, .{
            .name = try alloc.dupe(u8, f.name),
            .raw_symbol = try alloc.dupe(u8, f.raw),
            .bytes = bytes,
            .holes = try holes.toOwnedSlice(alloc),
            .is_terminal = is_terminal,
        });
    }

    return stencils_list.toOwnedSlice(alloc);
}

// ── Output emission ───────────────────────────────────────────────────────────

fn writeOutput(w: anytype, stencils: []const Stencil) !void {
    try w.writeAll(
        \\// AUTO-GENERATED by tools/extract_stencils.zig — do not edit.
        \\//
        \\// Stencils extracted from a ReleaseFast object file of
        \\// src/runtime/jit/stencils_src.zig. The JIT runtime copies
        \\// each .bytes blob into executable memory and applies the
        \\// listed .holes to chain stencils together.
        \\
        \\pub const HoleKind = enum { branch26, page21, pageoff12 };
        \\pub const HoleTarget = enum { next, taken, operand, external };
        \\
        \\pub const Hole = struct {
        \\    offset: u32,
        \\    kind: HoleKind,
        \\    target: HoleTarget,
        \\    symbol: []const u8,
        \\};
        \\
        \\pub const Stencil = struct {
        \\    name: []const u8,
        \\    bytes: []const u8,
        \\    holes: []const Hole,
        \\    is_terminal: bool,
        \\};
        \\
        \\pub const stencils = [_]Stencil{
        \\
    );
    for (stencils) |s| {
        try w.print("    .{{ .name = \"{s}\", .is_terminal = {s},\n", .{ s.name, if (s.is_terminal) "true" else "false" });
        try w.writeAll("      .bytes = &.{");
        for (s.bytes, 0..) |b, i| {
            if (i % 12 == 0) try w.writeAll("\n        ");
            try w.print("0x{x:0>2}, ", .{b});
        }
        try w.writeAll("\n      },\n");
        try w.writeAll("      .holes = &.{\n");
        for (s.holes) |h| {
            try w.print("        .{{ .offset = 0x{x}, .kind = .{s}, .target = .{s}, .symbol = \"{s}\" }},\n",
                .{ h.offset, @tagName(h.kind), @tagName(h.target), h.symbol });
        }
        try w.writeAll("      },\n");
        try w.writeAll("    },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\pub fn get(name: []const u8) ?*const Stencil {
        \\    inline for (&stencils) |*s| {
        \\        if (@import("std").mem.eql(u8, s.name, name)) return s;
        \\    }
        \\    return null;
        \\}
        \\
    );
}

// ── Driver ────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arg_iter = try init.args.iterateAllocator(alloc);
    defer arg_iter.deinit();
    _ = arg_iter.next(); // exe
    const in_path = arg_iter.next() orelse return die("expected <input.o>");
    const out_path = arg_iter.next() orelse return die("expected <output.zig>");

    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, in_path, alloc,
        std.Io.Limit.limited(64 * 1024 * 1024));
    defer alloc.free(bytes);

    const view = try MachoView.init(bytes);
    const stencils = try extract(alloc, view);
    defer {
        for (stencils) |s| {
            alloc.free(s.name);
            alloc.free(s.raw_symbol);
            alloc.free(s.bytes);
            for (s.holes) |h| alloc.free(h.symbol);
            alloc.free(s.holes);
        }
        alloc.free(stencils);
    }

    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = out_file.writer(io, &buf);
    try writeOutput(&fw.interface, stencils);
    try fw.interface.flush();

    std.debug.print("extract_stencils: {d} stencils → {s}\n", .{ stencils.len, out_path });
}

fn die(msg: []const u8) noreturn {
    std.debug.print("extract_stencils: {s}\n", .{msg});
    std.process.exit(2);
}
