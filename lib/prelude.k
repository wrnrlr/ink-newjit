/ lib/prelude.k — CPU builtins, loaded into every VM at init (see VM.create).
/
/ The math functions AND the non-glyph monadic verbs (first last count parse exec
/ depth epoch) were removed from the grammar (lexer KEYWORD_OPS now keeps only the
/ genuinely-dyadic `in has mod div`). They are re-exposed here as ordinary names
/ bound to lambdas that apply the corresponding callable symbol by JUXTAPOSITION
/ (`` `sin x ``). Any monadic primitive is now callable as a symbol — syms.apply /
/ the compiler peephole route `` `NAME x `` to the SAME Op1 kernel the old keyword
/ verb used, so `first 1 2 3`, `sqrt 4 9`, `parse "1+2"` behave exactly as before and
/ integer-closed ops (`sqr`/`abs`) stay integer. See doc/design/dye.md.
/
/ Because these are names (nouns), not verbs, a bare `-` directly after one is
/ dyadic subtract: write `abs[-4]` / `abs(0-4)`, not `abs -4`.

/ ── math (Op1 kernels: type-preserving) ──
sin:{`sin x};cos:{`cos x};sqrt:{`sqrt x};sqr:{`sqr x}
exp:{`exp x};log:{`log x};abs:{`abs x}

/ ── inverse trig (syms.zig std.math; f32) ──
asin:{`asin x};acos:{`acos x};atan:{`atan x};atan2:{`atan2(x;y)}

/ ── cube root (syms.zig std.math.cbrt; f32-widening, signed) ──
cbrt:{`cbrt x}

/ ── ex-keyword monadic verbs with a glyph form ──
first:{*x};last:{*|x};count:{#x}
/ ── ex-keyword monadic verbs with no glyph (routed to their Op1 kernel by symbol) ──
parse:{`parse x};exec:{`exec x};depth:{`depth x};epoch:{`epoch x}

/ ── misc conveniences ──
sort:{x@<x}
