/// fvar — Font Variations Table.
/// doc/otf/table-fvar.md
///
/// Normalized to a dict with two column-tables:
///   axes      : one row per variation axis — tag (L of 4-char strings),
///               min/def/max (F, user-scale Fixed), flags (I), nameID (I).
///   instances : one row per named instance — nameID (I subfamilyNameID),
///               postNameID (I postScriptNameID, 0 when the instance omits it),
///               coords (L of F vectors, length axisCount each).
/// axesArrayOffset, axisSize and instanceSize are honored for forward-compat
/// striding; reserved/flags-padding fields are dropped.

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = reader.Reader.init(data);
  _ = try r.uint16(); // majorVersion
  _ = try r.uint16(); // minorVersion
  const axesArrayOffset = try r.uint16();
  _ = try r.uint16(); // reserved (set to 2)
  const axisCount = try r.uint16();
  const axisSize = try r.uint16();
  const instanceCount = try r.uint16();
  const instanceSize = try r.uint16();

  // ── axes column-table ──
  const tag = k.KL(axisCount) orelse return null;
  const min = k.KF(axisCount) orelse return null;
  const def = k.KF(axisCount) orelse return null;
  const max = k.KF(axisCount) orelse return null;
  const flags = k.KI(axisCount) orelse return null;
  const nameID = k.KI(axisCount) orelse return null;
  const minp = k.fp(min) orelse return null;
  const defp = k.fp(def) orelse return null;
  const maxp = k.fp(max) orelse return null;
  const flagsp = k.ip(flags) orelse return null;
  const namep = k.ip(nameID) orelse return null;

  var ai: usize = 0;
  while (ai < axisCount) : (ai += 1) {
    var ar = reader.Reader.at(data, @as(usize, axesArrayOffset) + ai * @as(usize, axisSize));
    const t = try ar.tag();
    k.listSet(tag, ai, k.str(&reader.tagBytes(t)));
    minp[ai] = try ar.fixed();
    defp[ai] = try ar.fixed();
    maxp[ai] = try ar.fixed();
    flagsp[ai] = try ar.uint16();
    namep[ai] = try ar.uint16();
  }

  const axes = k.dict(
    &[_][*:0]const u8{ "tag", "min", "def", "max", "flags", "nameID" },
    &[_]?k.K{ tag, min, def, max, flags, nameID },
  );

  // ── instances column-table ──
  const subID = k.KI(instanceCount) orelse return null;
  const postID = k.KI(instanceCount) orelse return null;
  const coords = k.KL(instanceCount) orelse return null;
  const subp = k.ip(subID) orelse return null;
  const postp = k.ip(postID) orelse return null;

  // An instance carries a postScriptNameID when its record is large enough to
  // hold the extra uint16 beyond subfamilyNameID + flags + axisCount Fixed.
  const baseSize: usize = 4 + @as(usize, axisCount) * 4;
  const hasPost = instanceSize >= baseSize + 2;

  const instancesBase = @as(usize, axesArrayOffset) + @as(usize, axisCount) * @as(usize, axisSize);
  var ii: usize = 0;
  while (ii < instanceCount) : (ii += 1) {
    var ir = reader.Reader.at(data, instancesBase + ii * @as(usize, instanceSize));
    subp[ii] = try ir.uint16();
    _ = try ir.uint16(); // flags (reserved)
    const cv = k.KF(axisCount) orelse return null;
    if (k.fp(cv)) |cp| {
      var ci: usize = 0;
      while (ci < axisCount) : (ci += 1) cp[ci] = try ir.fixed();
    }
    k.listSet(coords, ii, cv);
    postp[ii] = if (hasPost) try ir.uint16() else 0;
  }

  const instances = k.dict(
    &[_][*:0]const u8{ "nameID", "postNameID", "coords" },
    &[_]?k.K{ subID, postID, coords },
  );

  const keys = [_][*:0]const u8{ "axes", "instances" };
  const vals = [_]?k.K{ axes, instances };
  return k.dict(&keys, &vals);
}
