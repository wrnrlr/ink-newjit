/// BASE — Baseline Table.
/// doc/otf/table-BASE.md
///
/// Normalized to a dict:
///   version   : F (major.minor)
///   horizAxis : dict (present when horizAxisOffset != 0)
///   vertAxis  : dict (present when vertAxisOffset != 0)
///
/// Each axis dict has:
///   baselineTags : L of 4-char strings (the BaseTagList), or empty
///   scripts      : columns over the BaseScriptList:
///                    script          (L of 4-char strings)
///                    defaultBaseline (I, defaultBaselineIndex)
///                    coords          (L of I vectors — one int per baseline
///                                     tag, decoded from each BaseCoord; all
///                                     three BaseCoord formats yield a FWORD
///                                     coordinate, pointIndex/device ignored)
///
/// MinMax / feature-specific min-max extents are deferred (not exposed).

const reader = @import("../reader.zig");
const k = @import("../kbuild.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Reader = reader.Reader;

/// All three BaseCoord formats begin with a uint16 format then an int16
/// coordinate (FWORD). Formats 2/3 carry extra fields (pointIndex / device
/// offset) which we ignore — only the design-unit coordinate is taken.
fn baseCoord(data: []const u8, off: usize) i32 {
  var r = Reader.at(data, off);
  _ = r.uint16() catch return 0; // format (1/2/3)
  return r.int16() catch 0;
}

/// Decode one Axis table (offset relative to the BASE table). Returns its dict.
fn axis(data: []const u8, axisOff: usize) ?k.K {
  var r = Reader.at(data, axisOff);
  const baseTagListOffset = r.uint16() catch 0;
  const baseScriptListOffset = r.uint16() catch 0;

  // ── BaseTagList → L of 4-char tag strings ──────────────────────────────────
  var tags: ?k.K = k.KL(0);
  var baseTagCount: usize = 0;
  if (baseTagListOffset != 0) {
    var tr = Reader.at(data, axisOff + baseTagListOffset);
    baseTagCount = tr.uint16() catch 0;
    const list = k.KL(baseTagCount) orelse return null;
    var i: usize = 0;
    while (i < baseTagCount) : (i += 1) {
      const t = tr.uint32() catch 0;
      k.listSet(list, i, k.str(&reader.tagBytes(t)));
    }
    tags = list;
  }

  // ── BaseScriptList → columns {script; defaultBaseline; coords} ──────────────
  var scriptCount: usize = 0;
  if (baseScriptListOffset != 0) {
    var sr = Reader.at(data, axisOff + baseScriptListOffset);
    scriptCount = sr.uint16() catch 0;
  }
  const scriptCol = k.KL(scriptCount) orelse return null;
  const defBase = k.KI(scriptCount) orelse return null;
  const coordsCol = k.KL(scriptCount) orelse return null;
  const dbp = k.ip(defBase) orelse return null;

  if (baseScriptListOffset != 0 and scriptCount != 0) {
    const listBase = axisOff + baseScriptListOffset;
    var rec = Reader.at(data, listBase);
    _ = rec.uint16() catch 0; // baseScriptCount (already read)
    var i: usize = 0;
    while (i < scriptCount) : (i += 1) {
      const scriptTag = rec.uint32() catch 0;
      const baseScriptOffset = rec.uint16() catch 0;
      k.listSet(scriptCol, i, k.str(&reader.tagBytes(scriptTag)));

      var coords: ?k.K = k.KI(0);
      var defaultBaselineIndex: i32 = 0;
      if (baseScriptOffset != 0) {
        const scriptBase = listBase + baseScriptOffset;
        var bs = Reader.at(data, scriptBase);
        const baseValuesOffset = bs.uint16() catch 0;
        // (defaultMinMaxOffset, baseLangSysCount, records follow — deferred)
        if (baseValuesOffset != 0) {
          const valuesBase = scriptBase + baseValuesOffset;
          var bv = Reader.at(data, valuesBase);
          defaultBaselineIndex = bv.uint16() catch 0;
          const baseCoordCount = bv.uint16() catch 0;
          const cv = k.KI(baseCoordCount) orelse return null;
          if (k.ip(cv)) |cp| {
            var j: usize = 0;
            while (j < baseCoordCount) : (j += 1) {
              const coordOff = bv.uint16() catch 0;
              cp[j] = if (coordOff != 0) baseCoord(data, valuesBase + coordOff) else 0;
            }
          }
          coords = cv;
        }
      }
      dbp[i] = defaultBaselineIndex;
      k.listSet(coordsCol, i, coords);
    }
  }

  const skeys = [_][*:0]const u8{ "script", "defaultBaseline", "coords" };
  const svals = [_]?k.K{ scriptCol, defBase, coordsCol };
  const scripts = k.dict(&skeys, &svals);

  const keys = [_][*:0]const u8{ "baselineTags", "scripts" };
  const vals = [_]?k.K{ tags, scripts };
  return k.dict(&keys, &vals);
}

pub fn parse(ctx: *const Ctx, data: []const u8) reader.Error!?k.K {
  _ = ctx;
  var r = Reader.init(data);
  const major = try r.uint16();
  const minor = try r.uint16();
  const horizAxisOffset = try r.uint16();
  const vertAxisOffset = try r.uint16();

  const version = @as(f32, @floatFromInt(major)) + @as(f32, @floatFromInt(minor)) / 10.0;

  var keys: [3][*:0]const u8 = undefined;
  var vals: [3]?k.K = undefined;
  var n: usize = 0;
  keys[n] = "version";
  vals[n] = k.kf(version);
  n += 1;
  if (horizAxisOffset != 0) {
    keys[n] = "horizAxis";
    vals[n] = axis(data, horizAxisOffset);
    n += 1;
  }
  if (vertAxisOffset != 0) {
    keys[n] = "vertAxis";
    vals[n] = axis(data, vertAxisOffset);
    n += 1;
  }
  return k.dict(keys[0..n], vals[0..n]);
}
