const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../noun/value.zig");
const Pool = @import("../noun/symbol.zig").Pool;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const Dict = @import("../noun/dict.zig").Dict;

// --- Forward-star XML representation ---
//
// Returns a Table with 5 columns:
//   id     : I  — row index (0-based)
//   parent : I  — parent node id, 0N for roots
//   kind   : S  — `elem `attr `text `comment `cdata
//   name   : S  — tag/attribute name (empty symbol for text/comment/cdata)
//   value  : L  — attribute value or text content (.C), .blank for elements
//
// Nodes are stored in DFS pre-order. Attribute nodes immediately follow
// their element. This lets you find all children of node i with:
//   select from T where parent=i
// and all attributes of element e with:
//   select from T where parent=e, kind=`attr

const NULL_PARENT: i32 = std.math.minInt(i32); // == V.@"0N"

// --- Tokenizer ---

const Attr = struct { name: []const u8, val: []const u8 };

const TokTag = enum { elem_start, elem_end, elem_self, text, comment, cdata, proc_inst };

const Tok = struct {
  tag:   TokTag,
  name:  []const u8 = "",
  text:  []const u8 = "",
  attrs: []Attr = &.{},
};

const Tokenizer = struct {
  src:      []const u8,
  pos:      usize,
  alloc:    Alloc,
  attr_buf: std.ArrayList(Attr),

  fn init(alloc: Alloc, src: []const u8) !Tokenizer {
    return .{
      .src      = src,
      .pos      = 0,
      .alloc    = alloc,
      .attr_buf = try std.ArrayList(Attr).initCapacity(alloc, 8),
    };
  }

  fn deinit(self: *Tokenizer) void { self.attr_buf.deinit(self.alloc); }

  fn skipWS(self: *Tokenizer) void {
    while (self.pos < self.src.len) : (self.pos += 1) {
      const c = self.src[self.pos];
      if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
    }
  }

  fn consume(self: *Tokenizer, prefix: []const u8) bool {
    if (self.pos + prefix.len > self.src.len) return false;
    if (!std.mem.startsWith(u8, self.src[self.pos..], prefix)) return false;
    self.pos += prefix.len;
    return true;
  }

  /// Scan until `sentinel` is found, return the content before it and
  /// advance past the sentinel. Returns null on unterminated input.
  fn scanUntil(self: *Tokenizer, sentinel: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, self.src[self.pos..], sentinel) orelse return null;
    const slice = self.src[self.pos .. self.pos + idx];
    self.pos += idx + sentinel.len;
    return slice;
  }

  fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':';
  }

  fn scanName(self: *Tokenizer) []const u8 {
    const start = self.pos;
    while (self.pos < self.src.len and isNameChar(self.src[self.pos])) self.pos += 1;
    return self.src[start..self.pos];
  }

  fn scanAttrVal(self: *Tokenizer, quote: u8) []const u8 {
    const start = self.pos;
    while (self.pos < self.src.len and self.src[self.pos] != quote) self.pos += 1;
    const s = self.src[start..self.pos];
    if (self.pos < self.src.len) self.pos += 1; // consume closing quote
    return s;
  }

  fn parseAttrs(self: *Tokenizer) !void {
    self.attr_buf.clearRetainingCapacity();
    while (true) {
      self.skipWS();
      if (self.pos >= self.src.len) break;
      const c = self.src[self.pos];
      if (c == '>' or c == '/') break;

      const name = self.scanName();
      if (name.len == 0) { self.pos += 1; continue; } // skip stray chars

      self.skipWS();
      if (self.pos >= self.src.len or self.src[self.pos] != '=') {
        try self.attr_buf.append(self.alloc, .{ .name = name, .val = "" });
        continue;
      }
      self.pos += 1; // consume '='
      self.skipWS();
      if (self.pos >= self.src.len) break;

      const q = self.src[self.pos];
      if (q == '"' or q == '\'') {
        self.pos += 1;
        const v = self.scanAttrVal(q);
        try self.attr_buf.append(self.alloc, .{ .name = name, .val = v });
      } else {
        // Unquoted value (non-standard but encountered in practice).
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
          const ch = self.src[self.pos];
          if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '>' or ch == '/') break;
        }
        try self.attr_buf.append(self.alloc, .{ .name = name, .val = self.src[start..self.pos] });
      }
    }
  }

  fn next(self: *Tokenizer) !?Tok {
    while (true) {
      if (self.pos >= self.src.len) return null;

      if (self.src[self.pos] != '<') {
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '<') self.pos += 1;
        const text = std.mem.trim(u8, self.src[start..self.pos], " \t\n\r");
        if (text.len == 0) continue; // skip whitespace-only runs
        return .{ .tag = .text, .text = text };
      }

      self.pos += 1; // eat '<'

      if (self.consume("!--")) {
        const content = self.scanUntil("-->") orelse return null;
        return .{ .tag = .comment, .text = content };
      }
      if (self.consume("![CDATA[")) {
        const content = self.scanUntil("]]>") orelse return null;
        return .{ .tag = .cdata, .text = content };
      }
      if (self.consume("?")) {
        _ = self.scanUntil("?>"); // skip proc inst / XML declaration
        continue;
      }
      if (self.consume("/")) {
        self.skipWS();
        const name = self.scanName();
        while (self.pos < self.src.len and self.src[self.pos] != '>') self.pos += 1;
        if (self.pos < self.src.len) self.pos += 1;
        return .{ .tag = .elem_end, .name = std.mem.trim(u8, name, " \t\n\r") };
      }

      const name = self.scanName();
      try self.parseAttrs();

      var self_closing = false;
      if (self.pos < self.src.len and self.src[self.pos] == '/') {
        self_closing = true;
        self.pos += 1;
      }
      if (self.pos < self.src.len and self.src[self.pos] == '>') self.pos += 1;

      return .{
        .tag   = if (self_closing) .elem_self else .elem_start,
        .name  = name,
        .attrs = self.attr_buf.items,
      };
    }
  }
};

// --- Parser ---

pub fn parse(alloc: Alloc, pool: *Pool, text: []const u8) !V {
  if (text.len == 0) return .{ .err = .domain };

  // Intern kind symbols once.
  const sym_elem    = try pool.intern("elem");
  const sym_attr    = try pool.intern("attr");
  const sym_text    = try pool.intern("text");
  const sym_comment = try pool.intern("comment");
  const sym_cdata   = try pool.intern("cdata");
  const sym_empty   = try pool.intern("");

  // Per-row column data (grown dynamically).
  var parents  = try std.ArrayList(i32).initCapacity(alloc, 64);
  defer parents.deinit(alloc);
  var kinds    = try std.ArrayList(u32).initCapacity(alloc, 64);
  defer kinds.deinit(alloc);
  var names    = try std.ArrayList(u32).initCapacity(alloc, 64);
  defer names.deinit(alloc);
  var vals_raw = try std.ArrayList(V).initCapacity(alloc, 64);
  defer { for (vals_raw.items) |v| v.deinit(alloc); vals_raw.deinit(alloc); }

  var stack = try std.ArrayList(i32).initCapacity(alloc, 32);
  defer stack.deinit(alloc);

  var tok = try Tokenizer.init(alloc, text);
  defer tok.deinit();

  while (try tok.next()) |token| {
    const cur_id: i32    = @intCast(parents.items.len);
    const parent_id: i32 = if (stack.items.len == 0) NULL_PARENT
                           else stack.items[stack.items.len - 1];

    switch (token.tag) {
      .elem_start, .elem_self => {
        try parents.append(alloc, parent_id);
        try kinds.append(alloc, sym_elem);
        try names.append(alloc, try pool.intern(token.name));
        try vals_raw.append(alloc, .blank);

        for (token.attrs) |attr| {
          try parents.append(alloc, cur_id);
          try kinds.append(alloc, sym_attr);
          try names.append(alloc, try pool.intern(attr.name));
          try vals_raw.append(alloc, try V.Chars(alloc, attr.val));
        }

        if (token.tag == .elem_start) try stack.append(alloc, cur_id);
      },
      .elem_end => { if (stack.items.len > 0) _ = stack.pop(); },
      .text => {
        try parents.append(alloc, parent_id);
        try kinds.append(alloc, sym_text);
        try names.append(alloc, sym_empty);
        try vals_raw.append(alloc, try V.Chars(alloc, token.text));
      },
      .comment => {
        try parents.append(alloc, parent_id);
        try kinds.append(alloc, sym_comment);
        try names.append(alloc, sym_empty);
        try vals_raw.append(alloc, try V.Chars(alloc, token.text));
      },
      .cdata => {
        try parents.append(alloc, parent_id);
        try kinds.append(alloc, sym_cdata);
        try names.append(alloc, sym_empty);
        try vals_raw.append(alloc, try V.Chars(alloc, token.text));
      },
      .proc_inst => unreachable, // consumed in tokenizer
    }
  }

  const n = parents.items.len;
  if (n == 0) return .{ .err = .domain };

  // Build typed column vectors.
  const id_n     = try N(i32).fromRange(alloc, 0, 1, n);
  const parent_n = try N(i32).init(alloc, n);
  @memcpy(parent_n.slice(), parents.items);
  const kind_n = try N(u32).init(alloc, n);
  @memcpy(kind_n.slice(), kinds.items);
  const name_n = try N(u32).init(alloc, n);
  @memcpy(name_n.slice(), names.items);

  // value column: L of (.C or .blank).
  const val_n = try N(V).init(alloc, n);
  for (vals_raw.items, val_n.slice()) |v, *dst| dst.* = v.ref();

  // Assemble the table.
  const col_names = [_][]const u8{ "id", "parent", "kind", "name", "value" };
  const sk_n = try N(u32).init(alloc, col_names.len);
  for (col_names, sk_n.slice()) |cn, *dst| dst.* = try pool.intern(cn);

  const sv_n = try N(V).init(alloc, col_names.len);
  sv_n.slice()[0] = V{ .I = id_n };
  sv_n.slice()[1] = V{ .I = parent_n };
  sv_n.slice()[2] = V{ .S = kind_n };
  sv_n.slice()[3] = V{ .S = name_n };
  sv_n.slice()[4] = V{ .L = val_n };

  return V{ .M = try Dict.init(alloc, .{ .S = sk_n }, V{ .L = sv_n }) };
}
