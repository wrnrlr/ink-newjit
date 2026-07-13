# Bug log

Pre-existing bugs found incidentally, unrelated to the task at hand.

## `` `c$-1 `` panics instead of erroring (cast to char from negative int)

`` `c$<neg> `` (and `` `c$<neg vector> ``) reaches `numCast(i32, u8, v)` →
`@intCast`, which panics ("integer does not fit in destination type") in a
Debug build for any value outside `0..255`; in ReleaseFast it silently
wraps/UB. Present on `main` too (was `.{ .c = @intCast(y.i) }` in `castInt`).
Fix sketch: clamp/mask like the u32→u8 path (`@truncate`), or return
`.{ .err = .domain }` for out-of-range. Applies to both scalar and vector
char casts in `src/primitive/verb/cast.zig`.
