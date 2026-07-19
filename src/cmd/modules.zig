const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../runtime/vm.zig").VM;

/// Automatic module loader: scans lib/*.k files for public identifiers — those
/// starting with an Uppercase letter, plus dotted names namespaced under the
/// file's stem (e.g. `regex.match` in regex.k) — and auto-loads the
/// corresponding file when that identifier appears in source.
pub const ModuleLoader = struct {
  alloc:  Alloc,
  /// identifier name → lib file path (owned slices)
  index:  std.StringHashMap([]const u8),
  /// set of already-loaded file paths
  loaded: std.StringHashMap(void),

  pub fn init(alloc: Alloc) ModuleLoader {
    return .{
      .alloc  = alloc,
      .index  = std.StringHashMap([]const u8).init(alloc),
      .loaded = std.StringHashMap(void).init(alloc),
    };
  }

  pub fn deinit(self: *ModuleLoader) void {
    var it = self.index.iterator();
    while (it.next()) |e| {
      self.alloc.free(e.key_ptr.*);
      self.alloc.free(e.value_ptr.*);
    }
    self.index.deinit();
    var lt = self.loaded.iterator();
    while (lt.next()) |e| {
      self.alloc.free(e.key_ptr.*);
    }
    self.loaded.deinit();
  }

  /// Scan all *.k files directly under lib_path, indexing each file's public
  /// identifiers (see scanText) to its path.
  pub fn scan(self: *ModuleLoader, lib_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, lib_path, .{ .iterate = true }) catch return;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
      if (entry.kind != .file) continue;
      if (!std.mem.endsWith(u8, entry.name, ".k")) continue;

      const file_path = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ lib_path, entry.name });
      defer self.alloc.free(file_path);
      const text = std.Io.Dir.cwd().readFileAlloc(io, file_path, self.alloc, std.Io.Limit.limited(1024 * 1024)) catch continue;
      defer self.alloc.free(text);

      try self.scanText(file_path, text);
    }
  }

  // Record `ident → path` in the index (skip if already present). Both slices
  // are duped and owned by self.alloc.
  fn addEntry(self: *ModuleLoader, ident: []const u8, path: []const u8) !void {
    if (self.index.contains(ident)) return;
    const key = try self.alloc.dupe(u8, ident);
    errdefer self.alloc.free(key);
    const val = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(val);
    try self.index.put(key, val);
  }

  /// Index the public identifiers defined in one module's `content`, mapping
  /// each to `path`.  A module's public surface is defined by its `\d`
  /// namespaces: `\d ns` exports every `ns.member`; `\d ns a b` exports only
  /// `ns.a`/`ns.b`.  The bare namespace name (`ns`) and every top-level name at
  /// global scope (outside any `\d`) are also indexed, so both `ns.member` and
  /// a bare `ns` / `2:"ns"` reference trigger the load.  Works the same whether
  /// the source comes from disk or an embedded bundle.
  pub fn scanText(self: *ModuleLoader, path: []const u8, content: []const u8) !void {
    var ns: ?[]const u8 = null;      // current namespace (slice into content)
    var all_public = true;           // bare `\d ns` → every member public
    var pubs: std.ArrayListUnmanaged([]const u8) = .empty; // explicit public members
    defer pubs.deinit(self.alloc);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
      var skip: usize = 0;
      while (skip < line.len and (line[skip] == ' ' or line[skip] == '\t')) skip += 1;
      const trimmed = line[skip..];
      if (trimmed.len == 0 or trimmed[0] == '/') continue;

      // `\d` namespace directive: `\d` (reset), `\d ns`, or `\d ns a b`.
      if (trimmed[0] == '\\' and trimmed.len >= 2 and trimmed[1] == 'd' and
          (trimmed.len == 2 or trimmed[2] == ' ' or trimmed[2] == '\t')) {
        pubs.clearRetainingCapacity();
        var it = std.mem.tokenizeAny(u8, trimmed[2..], " \t");
        if (it.next()) |name| {
          ns = name;
          try self.addEntry(name, path);
          all_public = true;
          while (it.next()) |p| { all_public = false; try pubs.append(self.alloc, p); }
        } else ns = null;
        continue;
      }

      if (!std.ascii.isAlphabetic(trimmed[0])) continue;

      // [A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)* — a def LHS may be dotted
      // (the `stem.member` convention used by the parser modules).
      var end: usize = 1;
      while (end < trimmed.len and std.ascii.isAlphanumeric(trimmed[end])) end += 1;
      while (end + 1 < trimmed.len and trimmed[end] == '.' and std.ascii.isAlphabetic(trimmed[end + 1])) {
        end += 1; // consume '.'
        while (end < trimmed.len and std.ascii.isAlphanumeric(trimmed[end])) end += 1;
      }
      const name = trimmed[0..end];

      var after = end;
      while (after < trimmed.len and (trimmed[after] == ' ' or trimmed[after] == '\t')) after += 1;
      if (after >= trimmed.len or trimmed[after] != ':') continue;

      if (ns != null and std.mem.indexOfScalar(u8, name, '.') == null) {
        // Unqualified member inside `\d ns` — index `ns.name` only when public.
        var is_pub = all_public;
        if (!is_pub) for (pubs.items) |p| { if (std.mem.eql(u8, p, name)) { is_pub = true; break; } };
        if (!is_pub) continue;
        var buf: [256]u8 = undefined;
        const q = std.fmt.bufPrint(&buf, "{s}.{s}", .{ ns.?, name }) catch continue;
        try self.addEntry(q, path);
      } else if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        // Explicit `stem.member` global (the dotted-convention parser modules):
        // index the full name and its namespace prefix so both `stem` and
        // `stem.member` references trigger the load.  Bare (undotted) global
        // names are NOT indexed — they are almost always private helpers
        // (`so`, `tmp`, …) and indexing them would flood autoload, pulling in
        // half the library on any common identifier.
        try self.addEntry(name, path);
        try self.addEntry(name[0..dot], path);
      }
    }
  }

  /// Look up `ident` in the index, falling back from a qualified name to its
  /// namespace: `csv.read` → try `csv.read`, then `csv`.
  fn indexLookup(self: *ModuleLoader, ident: []const u8) ?[]const u8 {
    if (self.index.get(ident)) |p| return p;
    if (std.mem.indexOfScalar(u8, ident, '.')) |dot|
      if (self.index.get(ident[0..dot])) |p| return p;
    return null;
  }

  /// Scan source for identifier tokens (skipping comments and strings),
  /// including dotted module names like `regex.match`.
  /// For each token found in self.index that hasn't been loaded yet:
  ///   mark as loaded (before vm.load, prevents recursion), then call vm.load.
  // Explicit error set (only allocation can fail; loadModule errors are caught)
  // to break the autoLoad↔loadModule inferred-error-set recursion loop.
  pub fn autoLoad(self: *ModuleLoader, vm: *VM, source: []const u8) Alloc.Error!void {
    var i: usize = 0;
    while (i < source.len) {
      const c = source[i];

      // Skip line comments: / ... \n
      if (c == '/') {
        // only a comment if preceded by whitespace/start or is at column 0
        // simpler: treat '/' as comment start when not inside a string
        while (i < source.len and source[i] != '\n') i += 1;
        continue;
      }

      // Skip character literals/strings: "..."
      if (c == '"') {
        i += 1;
        while (i < source.len and source[i] != '"') {
          if (source[i] == '\\') i += 1;
          i += 1;
        }
        if (i < source.len) i += 1;
        continue;
      }

      // Identifier (uppercase, or a dotted module name like `regex.match`).
      if (std.ascii.isAlphabetic(c)) {
        var end = i + 1;
        while (end < source.len and std.ascii.isAlphanumeric(source[end])) end += 1;
        while (end + 1 < source.len and source[end] == '.' and std.ascii.isAlphabetic(source[end + 1])) {
          end += 1; // consume '.'
          while (end < source.len and std.ascii.isAlphanumeric(source[end])) end += 1;
        }
        const ident = source[i..end];
        i = end;

        if (self.indexLookup(ident)) |path| {
          if (!self.loaded.contains(path)) {
            const path_key = try self.alloc.dupe(u8, path);
            errdefer self.alloc.free(path_key);
            try self.loaded.put(path_key, {});
            self.loadModule(vm, path) catch |err| {
              std.debug.print("autoLoad: failed to load {s}: {}\n", .{ path, err });
            };
          }
        }
        continue;
      }

      i += 1;
    }
  }

  /// Load one module by path, first auto-loading the modules it itself
  /// references (transitive dependencies, in dependency order).  The path is
  /// read through vm.readFileText, so embedded-bundle modules resolve too.
  fn loadModule(self: *ModuleLoader, vm: *VM, path: []const u8) !void {
    const text = try vm.readFileText(path);
    self.autoLoad(vm, text) catch {};
    const id = try vm.fs.addFile(path, text);
    // A module's `\d` namespace must not leak into the scope that triggered the
    // autoload (or into the next module scanned in the same batch).
    const saved_ns = vm.compiler.namespace;
    defer vm.compiler.namespace = saved_ns;
    _ = try vm.interpret(text, id);
  }

  /// Transitively gather the lib files `source` depends on — via module
  /// identifiers (the autoload index) and explicit `2:"path.k"` loads — into
  /// `out` (path → content, both owned by self.alloc; caller frees).  Files are
  /// read from the current directory.  Used by `ink bundle`.
  pub fn collectDeps(self: *ModuleLoader, source: []const u8, out: *std.StringHashMap([]const u8)) !void {
    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(self.alloc);
    try self.scanDeps(source, out, &queue);
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
      const content = out.get(queue.items[i]) orelse continue;
      try self.scanDeps(content, out, &queue);
    }
  }

  // Read `path` from disk and record it in `out` (+ enqueue for scanning),
  // skipping files already present or unreadable.
  fn addDep(self: *ModuleLoader, out: *std.StringHashMap([]const u8), queue: *std.ArrayListUnmanaged([]const u8), path: []const u8) !void {
    if (out.contains(path)) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, std.Io.Limit.limited(1024 * 1024)) catch return;
    errdefer self.alloc.free(content);
    const key = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(key);
    try out.put(key, content);
    try queue.append(self.alloc, key);
  }

  // Find the direct dependencies in `source`: index-registered identifiers and
  // explicit `2:"...k"` file loads (skipping comments and strings).
  fn scanDeps(self: *ModuleLoader, source: []const u8, out: *std.StringHashMap([]const u8), queue: *std.ArrayListUnmanaged([]const u8)) !void {
    var i: usize = 0;
    while (i < source.len) {
      const c = source[i];
      if (c == '/') { while (i < source.len and source[i] != '\n') i += 1; continue; }

      // Explicit module load: monadic 2: applied to a "...k" string literal.
      if (c == '2' and i + 1 < source.len and source[i + 1] == ':') {
        var j = i + 2;
        while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
        if (j < source.len and source[j] == '"') {
          const start = j + 1;
          var k = start;
          while (k < source.len and source[k] != '"') k += 1;
          const pathstr = source[start..k];
          if (std.mem.endsWith(u8, pathstr, ".k")) {
            try self.addDep(out, queue, pathstr);
          } else if (std.mem.indexOfScalar(u8, pathstr, '/') == null and
                     std.mem.indexOfScalar(u8, pathstr, '.') == null and pathstr.len > 0) {
            // Std-lib shorthand: `2:"math"` → lib/math.k.
            var buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "lib/{s}.k", .{pathstr})) |lib|
              try self.addDep(out, queue, lib) else |_| {}
          }
          i = if (k < source.len) k + 1 else k;
          continue;
        }
        i += 2;
        continue;
      }

      if (c == '"') {
        i += 1;
        while (i < source.len and source[i] != '"') { if (source[i] == '\\') i += 1; i += 1; }
        if (i < source.len) i += 1;
        continue;
      }

      if (std.ascii.isAlphabetic(c)) {
        var end = i + 1;
        while (end < source.len and std.ascii.isAlphanumeric(source[end])) end += 1;
        while (end + 1 < source.len and source[end] == '.' and std.ascii.isAlphabetic(source[end + 1])) {
          end += 1;
          while (end < source.len and std.ascii.isAlphanumeric(source[end])) end += 1;
        }
        const ident = source[i..end];
        i = end;
        if (self.indexLookup(ident)) |path| try self.addDep(out, queue, path);
        continue;
      }

      i += 1;
    }
  }
};
