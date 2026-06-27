---
name: primitives-cleanup-2026-06
description: Primitive cleanup session: bugs fixed, dead code removed, structural simplifications applied
metadata:
  type: project
---

Cleanup of `src/primitive/` in June 2026 — reduced from 8266 → 7534 lines (-732, -8.9%). All 183 tests pass.

**Why:** User asked to identify dead code and structural simplifications without regressing performance.

**Changes made:**

- **Bug fixed**: `adverbs.zig` — `eachright` was importing `eachleft` (copy-paste bug). Fixed to import `eachright`.
- **Dead code removed**: `find.zig` — three empty never-called generator functions (`find_vec_atom`, `find_vec_vec`, `find_list`); bool find implementations that were commented out in the dispatch struct.
- **Dead code removed**: `flip.zig` — `FlipOp` struct (implemented division, named FlipOp, never used).
- **Dead code removed**: `values.zig` — duplicate `GetSymbol` definition (verbs.zig imports from `get.zig`, not `values.zig`); removed unused imports.
- **floor.zig simplified**: Deleted the hand-written `Floor` struct and `floor_f`/`floor_F` functions. Now only exposes `FloorOp` with correct `i32` return type. `verbs.zig` uses `h.makeMonad(.@"_", h.Float1, h.Int1, FloorOp, &.{.f, .F})` — same dispatch coverage, gains the in-place mutation fast path for float vectors.
- **tally.zig simplified**: `Tally` and `Count_Name` were identical structs with different `op`. Now share `TallyImpl` via `h._X(Op1, op, TallyImpl)`.
- **first.zig simplified**: `First` and `First_Name` were identical. Now share `FirstImpl` via `h._X(Op1, op, FirstImpl)`.
- **weedout tests migrated**: Unit tests removed from `weedout.zig`; equivalent expression-level tests added to `test.zig`. Output formats: empty I vec = `&0`, single-elem F vec = `,2.0`.

**How to apply:** Next cleanup session can look at: `apply1.zig` (Apply1 struct has no defaults, not in verbs.zig), `lowercase.zig` (could use makeMonad if `Char1` helper added to `helper.zig`), the four derived verb files (sum/product/min/max share a pattern that could be unified).
