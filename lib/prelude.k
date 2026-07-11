/ lib/prelude.k — CPU builtins, loaded into every VM at init (see VM.create).
/
/ Phase 1 removed the math functions from the grammar (they were lexer keyword
/ verbs). They are re-exposed here as ordinary names bound to lambdas that apply
/ the corresponding callable symbol by JUXTAPOSITION (`` `sin x ``). That routes
/ through Call.apply → syms.apply → the SAME Op1 kernel the old `sin` verb used,
/ so `sin x` / `sqrt 4 9` behave exactly as before and integer-closed `sqr`/`abs`
/ stay integer (`abs 3` → 3, `sqr 2 3` → 4 9). The canonical registry is
/ src/primitive/intrinsic.zig. See doc/design/dye.md.
/
/ Juxtaposition (not the `` `sin@ `` projection) is deliberate: `` `sym@<int-scalar> ``
/ mis-dispatches in the VM (a pre-existing `@`-dyad bug, see doc/bug.md), whereas
/ the juxtaposition apply path handles every int/float scalar and vector.
/
/ Because these are names (nouns), not verbs, a bare `-` directly after one is
/ dyadic subtract: write `abs[-4]` / `abs(0-4)`, not `abs -4`. And `sin x` does not
/ yet fuse into an elementwise KOp kernel (Phase 3 restores that via the IR seam).

/ ── math (Op1 kernels: type-preserving) ──
sin:  {`sin x}
cos:  {`cos x}
sqrt: {`sqrt x}
sqr:  {`sqr x}
exp:  {`exp x}
log:  {`log x}
abs:  {`abs x}

/ ── inverse trig (syms.zig std.math; f32) ──
asin: {`asin x}
acos: {`acos x}
atan: {`atan x}
atan2:{`atan2(x;y)}

/ ── misc conveniences ──
sort: {x@<x}
