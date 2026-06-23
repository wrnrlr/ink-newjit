/// JSTF — Justification Table.
/// doc/otf/table-JSTF.md
///
/// Normalized to:
///   version : F (major.minor)
///   scripts : L, one per JstfScriptRecord; each a dict
///     { tag (4-char string);
///       extenderGlyphs (I — glyphs that can be inserted to extend a line);
///       langSys : columns {tag (L of 4-char strings, "dflt" for the default
///                 JstfLangSys); priorityCount (I)} }
///
/// The JstfPriority bodies (GSUB/GPOS lookup enable/disable lists + JstfMax)
/// are deferred — only the per-langsys priority count is surfaced.

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Reader = reader.Reader;
const alloc = std.heap.c_allocator;

fn rdU16(data: []const u8, pos: usize) u16 {
  if (pos + 2 > data.len) return 0;
  return std.mem.readInt(u16, data[pos..][0..2], .big);
}

/// JstfLangSys at `base` → jstfPriorityCount.
fn priorityCount(data: []const u8, base: usize) i32 {
  return rdU16(data, base);
}

fn jstfScript(data: []const u8, base: usize) ?k.K {
  var r = Reader.at(data, base);
  const extenderOff = r.uint16() catch 0;
  const defLangSysOff = r.uint16() catch 0;
  const langSysCount = r.uint16() catch 0;

  // extender glyph list
  var extender = k.KI(0);
  if (extenderOff != 0) {
    const gc = rdU16(data, base + extenderOff);
    extender = k.KI(gc);
    if (k.ip(extender)) |p| {
      var i: usize = 0;
      while (i < gc) : (i += 1) p[i] = rdU16(data, base + extenderOff + 2 + 2 * i);
    }
  }

  // langsys: default ("dflt") plus the named records
  var tags: std.ArrayList(?k.K) = .empty;
  var counts: std.ArrayList(i32) = .empty;
  defer tags.deinit(alloc);
  defer counts.deinit(alloc);
  if (defLangSysOff != 0) {
    tags.append(alloc, k.str("dflt")) catch {};
    counts.append(alloc, priorityCount(data, base + defLangSysOff)) catch {};
  }
  var i: usize = 0;
  while (i < langSysCount) : (i += 1) {
    const recBase = base + 6 + i * 6; // after the 3 header uint16s
    const tagVal = std.mem.readInt(u32, if (recBase + 4 <= data.len) data[recBase..][0..4] else &[_]u8{ 0, 0, 0, 0 }, .big);
    const lsOff = rdU16(data, recBase + 4);
    const tb = reader.tagBytes(tagVal);
    tags.append(alloc, k.str(&tb)) catch {};
    counts.append(alloc, if (lsOff != 0) priorityCount(data, base + lsOff) else 0) catch {};
  }

  const tagList = k.KL(tags.items.len) orelse return null;
  for (tags.items, 0..) |t, j| k.listSet(tagList, j, t);
  const langSys = k.dict(
    &[_][*:0]const u8{ "tag", "priorityCount" },
    &[_]?k.K{ tagList, k.ints(i32, counts.items) },
  );

  return k.dict(
    &[_][*:0]const u8{ "extenderGlyphs", "langSys" },
    &[_]?k.K{ extender, langSys },
  );
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = Reader.init(data);
  const major = try r.uint16();
  const minor = try r.uint16();
  const scriptCount = try r.uint16();

  const scripts = k.KL(scriptCount) orelse return null;
  var i: usize = 0;
  while (i < scriptCount) : (i += 1) {
    const tagVal = try r.uint32();
    const scriptOff = try r.uint16();
    const sk = if (scriptOff != 0) jstfScript(data, scriptOff) else null;
    // attach the script tag onto the returned dict by rebuilding it
    if (sk) |sdict| {
      const tb = reader.tagBytes(tagVal);
      // jstfScript already includes a placeholder "tag" key (the extender); replace
      // by wrapping: build {tag; script}. Simpler: store as {tag; data:sdict}.
      k.listSet(scripts, i, k.dict(
        &[_][*:0]const u8{ "tag", "script" },
        &[_]?k.K{ k.str(&tb), sdict },
      ));
    } else {
      const tb = reader.tagBytes(tagVal);
      k.listSet(scripts, i, k.dict(
        &[_][*:0]const u8{ "tag", "script" },
        &[_]?k.K{ k.str(&tb), k.KL(0) },
      ));
    }
  }

  const version: f32 = @as(f32, @floatFromInt(major)) + @as(f32, @floatFromInt(minor)) / 10.0;
  return k.dict(
    &[_][*:0]const u8{ "version", "scripts" },
    &[_]?k.K{ k.kf(version), scripts },
  );
}
