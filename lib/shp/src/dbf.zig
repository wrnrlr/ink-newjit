/// .dbf (dBASE) attribute parser → an ink table (dict-of-columns).
///
/// One column per field, named by the field descriptor. Deleted records (those
/// flagged 0x2A '*') are dropped. Field-type → ink-column mapping:
///   C            → S  (interned symbol, trailing whitespace trimmed)
///   N, decimals=0→ I  (i32; blank/overflow → null)
///   N, decimals>0→ F
///   F            → F
///   L (logical)  → I  (T/Y/1 → 1, else 0)
///   D (date)     → I  (YYYYMMDD as an integer; blank → null)
///   other (M…)   → S  (interned, trimmed)

const std = @import("std");
const k = @import("kbuild.zig");
const Cursor = @import("read.zig").Cursor;

const Alloc = std.mem.Allocator;
const INT_NULL: i32 = std.math.minInt(i32);

const Field = struct {
  name: []const u8, // trimmed
  ftype: u8,
  len: usize,
  dec: u8,
  off: usize, // byte offset within a record (after the 1-byte delete flag)
};

fn trimEnd(s: []const u8) []const u8 {
  var e = s.len;
  while (e > 0 and (s[e - 1] == ' ' or s[e - 1] == 0)) e -= 1;
  return s[0..e];
}
fn trim(s: []const u8) []const u8 {
  var b: usize = 0;
  var e = s.len;
  while (b < e and s[b] == ' ') b += 1;
  while (e > b and (s[e - 1] == ' ' or s[e - 1] == 0)) e -= 1;
  return s[b..e];
}

pub fn parse(alloc: Alloc, buf: []const u8) !?k.K {
  if (buf.len < 32) return null;
  var arena = std.heap.ArenaAllocator.init(alloc);
  defer arena.deinit();
  const aa = arena.allocator();

  var c = Cursor.init(buf);
  c.skip(4); // version + last-update date
  const declaredRecs: usize = @intCast(c.u32le());
  const headerSize: usize = c.u16le();
  const recSize: usize = c.u16le();

  // Field descriptors: 32 bytes each from offset 32, until a 0x0D terminator.
  var fields: std.ArrayList(Field) = .empty;
  var fc = Cursor.init(buf);
  fc.seek(32);
  var recOff: usize = 1; // skip the per-record deletion flag byte
  while (fc.pos < buf.len and buf[fc.pos] != 0x0D) {
    if (fc.remaining() < 32) break;
    const raw = fc.bytes(11);
    const name = trimEnd(raw);
    const ftype = buf[fc.pos];
    fc.skip(5); // type(1) + field-data-address(4)
    const flen: usize = buf[fc.pos];
    const dec: u8 = buf[fc.pos + 1];
    fc.skip(2);
    fc.skip(14); // reserved/work-area/etc.
    try fields.append(aa, .{
      .name = try aa.dupe(u8, name),
      .ftype = ftype,
      .len = flen,
      .dec = dec,
      .off = recOff,
    });
    recOff += flen;
  }
  const nfields = fields.items.len;
  if (nfields == 0) return null;

  // Collect valid (non-deleted) record start offsets.
  const rs = if (recSize > 0) recSize else recOff;
  var starts: std.ArrayList(usize) = .empty;
  var i: usize = 0;
  while (i < declaredRecs) : (i += 1) {
    const off = headerSize + i * rs;
    if (off + rs > buf.len) break;
    if (buf[off] == 0x2A) continue; // deleted
    try starts.append(aa, off);
  }
  const nrec = starts.items.len;

  // Build one column per field.
  const names = try aa.alloc([*:0]const u8, nfields);
  const cols = try aa.alloc(?k.K, nfields);
  for (fields.items, 0..) |f, fi| {
    names[fi] = (try aa.dupeZ(u8, f.name)).ptr;
    cols[fi] = try buildColumn(aa, buf, f, starts.items, nrec);
  }

  return k.table(names, cols);
}

fn cellOf(buf: []const u8, start: usize, f: Field) []const u8 {
  const lo = start + f.off;
  const hi = @min(lo + f.len, buf.len);
  if (lo >= hi) return "";
  return buf[lo..hi];
}

fn buildColumn(aa: Alloc, buf: []const u8, f: Field, starts: []const usize, nrec: usize) !?k.K {
  const asFloat = (f.ftype == 'F') or (f.ftype == 'N' and f.dec > 0);
  const asInt = (f.ftype == 'N' and f.dec == 0) or f.ftype == 'D' or f.ftype == 'L';

  if (asFloat) {
    const col = k.KF(nrec) orelse return null;
    const p = k.fp(col).?;
    for (starts, 0..) |s, ri| {
      const t = trim(cellOf(buf, s, f));
      p[ri] = std.fmt.parseFloat(f32, t) catch std.math.nan(f32);
    }
    return col;
  }

  if (asInt) {
    const col = k.KI(nrec) orelse return null;
    const p = k.ip(col).?;
    for (starts, 0..) |s, ri| {
      const t = trim(cellOf(buf, s, f));
      p[ri] = switch (f.ftype) {
        'L' => logical(t),
        'D' => std.fmt.parseInt(i32, t, 10) catch INT_NULL,
        else => std.fmt.parseInt(i32, t, 10) catch INT_NULL,
      };
    }
    return col;
  }

  // C / memo / other → interned symbol column.
  const col = k.KS(nrec) orelse return null;
  const p = k.sp(col).?;
  for (starts, 0..) |s, ri| {
    const t = trim(cellOf(buf, s, f));
    if (t.len == 0) {
      p[ri] = 0; // empty symbol
    } else {
      const zname = try aa.dupeZ(u8, t);
      p[ri] = k.intern(zname.ptr);
    }
  }
  return col;
}

fn logical(t: []const u8) i32 {
  if (t.len == 0) return 0;
  return switch (t[0]) {
    'T', 't', 'Y', 'y', '1' => 1,
    else => 0,
  };
}
