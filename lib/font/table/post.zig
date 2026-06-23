/// post — PostScript / glyph-name table.
/// doc/otf/table-post.md
///
/// The header is parsed for every version (scalar dict: version, italicAngle,
/// underlinePos, underlineThick, fixedPitch). For version 2.0 a `names` key is
/// added — an L of length numGlyphs of C strings, each glyph's PostScript name.
///
/// Version 2.0 layout (after the 32-byte header): numGlyphs(u16),
/// glyphNameIndex[numGlyphs](u16), then a run of Pascal strings (1 length byte
/// + that many ASCII bytes). For glyph i: index < 258 → the standard Macintosh
/// glyph name #index; otherwise → customNames[index - 258], the (index-258)-th
/// Pascal string in the string data. Out-of-range indices emit "".

const std = @import("std");
const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const alloc = std.heap.c_allocator;

/// The 258 standard Macintosh glyph-ordering names (Apple 'post' Format 1 /
/// OpenType standard Macintosh glyph ordering). Indices 0..257 map directly.
const MAC_GLYPHS = [_][]const u8{
  ".notdef",        ".null",          "nonmarkingreturn", "space",
  "exclam",         "quotedbl",       "numbersign",       "dollar",
  "percent",        "ampersand",      "quotesingle",      "parenleft",
  "parenright",     "asterisk",       "plus",             "comma",
  "hyphen",         "period",         "slash",            "zero",
  "one",            "two",            "three",            "four",
  "five",           "six",            "seven",            "eight",
  "nine",           "colon",          "semicolon",        "less",
  "equal",          "greater",        "question",         "at",
  "A",              "B",              "C",                "D",
  "E",              "F",              "G",                "H",
  "I",              "J",              "K",                "L",
  "M",              "N",              "O",                "P",
  "Q",              "R",              "S",                "T",
  "U",              "V",              "W",                "X",
  "Y",              "Z",              "bracketleft",      "backslash",
  "bracketright",   "asciicircum",    "underscore",       "grave",
  "a",              "b",              "c",                "d",
  "e",              "f",              "g",                "h",
  "i",              "j",              "k",                "l",
  "m",              "n",              "o",                "p",
  "q",              "r",              "s",                "t",
  "u",              "v",              "w",                "x",
  "y",              "z",              "braceleft",        "bar",
  "braceright",     "asciitilde",     "Adieresis",        "Aring",
  "Ccedilla",       "Eacute",         "Ntilde",           "Odieresis",
  "Udieresis",      "aacute",         "agrave",           "acircumflex",
  "adieresis",      "atilde",         "aring",            "ccedilla",
  "eacute",         "egrave",         "ecircumflex",      "edieresis",
  "iacute",         "igrave",         "icircumflex",      "idieresis",
  "ntilde",         "oacute",         "ograve",           "ocircumflex",
  "odieresis",      "otilde",         "uacute",           "ugrave",
  "ucircumflex",    "udieresis",      "dagger",           "degree",
  "cent",           "sterling",       "section",          "bullet",
  "paragraph",      "germandbls",     "registered",       "copyright",
  "trademark",      "acute",          "dieresis",         "notequal",
  "AE",             "Oslash",         "infinity",         "plusminus",
  "lessequal",      "greaterequal",   "yen",              "mu",
  "partialdiff",    "summation",      "product",          "pi",
  "integral",       "ordfeminine",    "ordmasculine",     "Omega",
  "ae",             "oslash",         "questiondown",     "exclamdown",
  "logicalnot",     "radical",        "florin",           "approxequal",
  "Delta",          "guillemotleft",  "guillemotright",   "ellipsis",
  "nonbreakingspace", "Agrave",       "Atilde",           "Otilde",
  "OE",             "oe",             "endash",           "emdash",
  "quotedblleft",   "quotedblright",  "quoteleft",        "quoteright",
  "divide",         "lozenge",        "ydieresis",        "Ydieresis",
  "fraction",       "currency",       "guilsinglleft",    "guilsinglright",
  "fi",             "fl",             "daggerdbl",        "periodcentered",
  "quotesinglbase", "quotedblbase",   "perthousand",      "Acircumflex",
  "Ecircumflex",    "Aacute",         "Edieresis",        "Egrave",
  "Iacute",         "Icircumflex",    "Idieresis",        "Igrave",
  "Oacute",         "Ocircumflex",    "apple",            "Ograve",
  "Uacute",         "Ucircumflex",    "Ugrave",           "dotlessi",
  "circumflex",     "tilde",          "macron",           "breve",
  "dotaccent",      "ring",           "cedilla",          "hungarumlaut",
  "ogonek",         "caron",          "Lslash",           "lslash",
  "Scaron",         "scaron",         "Zcaron",           "zcaron",
  "brokenbar",      "Eth",            "eth",              "Yacute",
  "yacute",         "Thorn",          "thorn",            "minus",
  "multiply",       "onesuperior",    "twosuperior",      "threesuperior",
  "onehalf",        "onequarter",     "threequarters",    "franc",
  "Gbreve",         "gbreve",         "Idotaccent",       "Scedilla",
  "scedilla",       "Cacute",         "cacute",           "Ccaron",
  "ccaron",         "dcroat",
};

/// Walk the Pascal-string region, building a list of slices into `data`.
/// Stops at the first malformed length (a length that runs past the buffer).
fn collectCustom(data: []const u8) std.ArrayList([]const u8) {
  var list: std.ArrayList([]const u8) = .empty;
  var pos: usize = 0;
  while (pos < data.len) {
    const len: usize = data[pos];
    pos += 1;
    if (pos + len > data.len) break;
    list.append(alloc, data[pos .. pos + len]) catch break;
    pos += len;
  }
  return list;
}

fn parseNames(r: *reader.Reader, data: []const u8) reader.Error!?k.K {
  const numGlyphs = try r.uint16();
  if (numGlyphs == 0) return k.KL(0);

  // glyphNameIndex[numGlyphs]
  const indices = alloc.alloc(u16, numGlyphs) catch return null;
  defer alloc.free(indices);
  var i: usize = 0;
  while (i < numGlyphs) : (i += 1) indices[i] = try r.uint16();

  // The remaining bytes are the Pascal-string storage.
  const storeOff = r.pos;
  const store: []const u8 = if (storeOff <= data.len) data[storeOff..] else &.{};
  var custom = collectCustom(store);
  defer custom.deinit(alloc);

  const names = k.KL(numGlyphs) orelse return null;
  i = 0;
  while (i < numGlyphs) : (i += 1) {
    const idx = indices[i];
    var name: []const u8 = "";
    if (idx < 258) {
      name = MAC_GLYPHS[idx];
    } else {
      const ci: usize = @as(usize, idx) - 258;
      if (ci < custom.items.len) name = custom.items[ci];
    }
    k.listSet(names, i, k.str(name));
  }
  return names;
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);

  const version = try r.fixed();
  const italicAngle = try r.fixed();
  const underlinePos = try r.int16();
  const underlineThick = try r.int16();
  const isFixedPitch = try r.uint32();

  // Skip the four memory-usage uint32 fields to reach the v2 appendix.
  _ = try r.uint32(); // minMemType42
  _ = try r.uint32(); // maxMemType42
  _ = try r.uint32(); // minMemType1
  _ = try r.uint32(); // maxMemType1

  if (version == 2.0) {
    const names = parseNames(&r, data) catch null;
    if (names) |n| {
      const keys = [_][*:0]const u8{
        "version",        "italicAngle", "underlinePos",
        "underlineThick", "fixedPitch",  "names",
      };
      const vals = [_]?k.K{
        k.kf(version),    k.kf(italicAngle),  k.ki(underlinePos),
        k.ki(underlineThick), k.ki(if (isFixedPitch != 0) 1 else 0), n,
      };
      return k.dict(&keys, &vals);
    }
  }

  const keys = [_][*:0]const u8{
    "version", "italicAngle", "underlinePos", "underlineThick", "fixedPitch",
  };
  const vals = [_]?k.K{
    k.kf(version), k.kf(italicAngle), k.ki(underlinePos), k.ki(underlineThick),
    k.ki(if (isFixedPitch != 0) 1 else 0),
  };
  return k.dict(&keys, &vals);
}
