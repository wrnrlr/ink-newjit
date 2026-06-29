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

  /// Scan all *.k files directly under lib_path.
  /// For each file, find lines where the first token matches [A-Z][A-Za-z0-9]*:
  /// and register identifier → file_path in self.index.
  pub fn scan(self: *ModuleLoader, lib_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, lib_path, .{ .iterate = true }) catch return;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
      if (entry.kind != .file) continue;
      if (!std.mem.endsWith(u8, entry.name, ".k")) continue;

      // Build path: lib_path + "/" + name
      const file_path = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ lib_path, entry.name });
      errdefer self.alloc.free(file_path);

      const text = std.Io.Dir.cwd().readFileAlloc(io, file_path, self.alloc, std.Io.Limit.limited(1024 * 1024)) catch {
        self.alloc.free(file_path);
        continue;
      };
      defer self.alloc.free(text);

      // Module name = file stem (the name minus the ".k" extension).
      const stem = entry.name[0 .. entry.name.len - 2];

      var found_any = false;
      var lines = std.mem.splitScalar(u8, text, '\n');
      while (lines.next()) |line| {
        var skip: usize = 0;
        while (skip < line.len and (line[skip] == ' ' or line[skip] == '\t')) skip += 1;
        const trimmed = line[skip..];
        // Skip comments
        if (trimmed.len == 0 or trimmed[0] == '/') continue;
        // Must start with a letter
        if (!std.ascii.isAlphabetic(trimmed[0])) continue;

        // Find the (possibly dotted) identifier:
        //   [A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)*
        var end: usize = 1;
        while (end < trimmed.len and std.ascii.isAlphanumeric(trimmed[end])) end += 1;
        while (end + 1 < trimmed.len and trimmed[end] == '.' and std.ascii.isAlphabetic(trimmed[end + 1])) {
          end += 1; // consume '.'
          while (end < trimmed.len and std.ascii.isAlphanumeric(trimmed[end])) end += 1;
        }
        const ident = trimmed[0..end];

        // Next non-space must be ':'
        var after = end;
        while (after < trimmed.len and (trimmed[after] == ' ' or trimmed[after] == '\t')) after += 1;
        if (after >= trimmed.len or trimmed[after] != ':') continue;
        // Must not be '::' (global assignment uses '::') — allow both

        // Public if it starts with an uppercase letter, or is a dotted name
        // namespaced under this file's stem (e.g. `regex.match` in regex.k).
        const is_upper = std.ascii.isUpper(ident[0]);
        const is_module = ident.len > stem.len + 1 and
          std.mem.startsWith(u8, ident, stem) and ident[stem.len] == '.';
        if (!is_upper and !is_module) continue;

        // Register if not already in index
        if (self.index.contains(ident)) continue;

        const key = try self.alloc.dupe(u8, ident);
        errdefer self.alloc.free(key);
        const val = if (!found_any) file_path else try self.alloc.dupe(u8, file_path);
        found_any = true;
        try self.index.put(key, val);
      }

      if (!found_any) self.alloc.free(file_path);
    }
  }

  /// Scan source for identifier tokens (skipping comments and strings),
  /// including dotted module names like `regex.match`.
  /// For each token found in self.index that hasn't been loaded yet:
  ///   mark as loaded (before vm.load, prevents recursion), then call vm.load.
  pub fn autoLoad(self: *ModuleLoader, vm: *VM, source: []const u8) !void {
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

        if (self.index.get(ident)) |path| {
          if (!self.loaded.contains(path)) {
            const path_key = try self.alloc.dupe(u8, path);
            errdefer self.alloc.free(path_key);
            try self.loaded.put(path_key, {});
            _ = vm.load(path) catch |err| {
              std.debug.print("autoLoad: failed to load {s}: {}\n", .{ path, err });
            };
          }
        }
        continue;
      }

      i += 1;
    }
  }
};
