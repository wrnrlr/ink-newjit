/ test/spacial.k — array-friendly spatial hashing for fixed-radius neighbour search
/
/ Goal: given n particles, find every pair (i;j) closer than a radius r, so the
/ cloth solver (test/cloth.k) can add self-collision constraints. Müller's JS
/ `Hash` class does this with a hand-rolled counting sort into a hash table plus a
/ per-particle 3×3×3 cell scan with explicit loops. None of that is needed in k —
/ the whole thing is a handful of whole-array operations.
/
/ The two ideas that make it array-friendly:
/
/  1. The hash table IS k's group `=`. Encode each particle's integer cell
/     (cx;cy;cz) as ONE integer key, then `=keys` groups particles by cell in O(n):
/     a dict cellKey -> indices-in-that-cell. No counting sort, no collisions —
/     exact cells, so no `tableSize`/`hashCoords` fantasy function either.
/
/  2. The 27-cell neighbourhood scan becomes 27 whole-array shifts. With cell size
/     = search radius, two particles within r live in cells differing by ≤1 on each
/     axis. For each of the 27 offset vectors o ∈ {-1,0,1}³ we shift EVERY
/     particle's key by enc(o) and look the shifted key up in the group — giving,
/     per particle, the list of candidates in that neighbour cell. Replicate +
/     raze turns the ragged lookup into flat (ci;cj) pair arrays. Filtering ci<cj
/     drops self-pairs and keeps each unordered pair once (it shows up as (a,b)
/     under offset o and (b,a) under -o).
/
/ Run: ink test/spacial.k

/ ── Cell-key encoding ─────────────────────────────────────────────────────────
/ Pack the signed integer cell coords into one i32. B is the per-axis span and OFF
/ recentres negatives into [0,B); ((cx*B+cy)*B+cz) is then collision-free and a
/ pure offset o just adds the constant enc(o)=((ox*B+oy)*B+oz) — no carry across
/ axes as long as cells stay well inside [−OFF,B−OFF). Fine for small scenes.
gRad:: 1.0                                       / search radius == cell size
B:: 1024; OFF:: 512
cellOf:{[x;y;z;r] cx:(_ x%r)+OFF; cy:(_ y%r)+OFF; cz:(_ z%r)+OFF; ((B*B)*cx)+(B*cy)+cz}

/ The 27 neighbour-offset encodings, built from a 3×3×3 odometer (cloth.k uses the
/ same `!(a;b)` trick). t@0/t@1/t@2 are the three coord streams, shifted to -1 0 1.
oTab:: !(3;3;3)
encOff:: ((B*B)*(oTab@0)-1)+(B*(oTab@1)-1)+(oTab@2)-1

/ ── One offset: per-particle candidate lists → flat (ci;cj) pair arrays ────────
/ Reads the globals set by `pairs` (lambdas don't capture parent scope; `::`
/ globals are visible). find→length: gKeys?tk yields the bucket index, or #gKeys
/ for an empty neighbour cell — which lands exactly on gVals' appended empty bucket,
/ so the lookup is total with no fixup. &#'nb replicates each particle's index once
/ per candidate; ,/nb razes the matching candidate indices in the same order.
shift:{[e]
  tk: gCell + e
  nb: gVals @ gKeys ? tk
  (&#'nb; ,/nb)}

/ ── pairs[px;py;pz;r] → (ci;cj): all unordered pairs closer than r ─────────────
pairs:{[px;py;pz;r]
  gCell:: cellOf[px;py;pz;r]                     / one cell key per particle
  grp:  = gCell                                  / dict cellKey -> indices (the hash table)
  gKeys:: !grp                                   / occupied cell keys
  gVals:: (.grp),,!0                             / their index lists + a trailing empty bucket for misses
  res:  shift' encOff                            / 27 (ci;cj) candidate batches
  ci:   ,/{x@0}'res                              / razed start indices
  cj:   ,/{x@1}'res                              / razed neighbour indices
  dx:(px@cj)-px@ci; dy:(py@cj)-py@ci; dz:(pz@cj)-pz@ci
  d2:(dx*dx)+(dy*dy)+(dz*dz)
  keep: &(ci<cj)*d2<r*r                          / i<j (dedup, no self) AND inside radius
  (ci@keep; cj@keep)}

/ ── Demo ──────────────────────────────────────────────────────────────────────
/ Two tight clusters plus a stray. Expect within-cluster pairs only, no cross.
px:: 0.0 0.4 0.9 5.0 5.3 5.1 9.9
py:: 0.0 0.1 0.0 0.0 0.2 0.1 0.0
pz:: 7#0.0
pr:: pairs[px;py;pz;gRad]
`"neighbour pairs (i;j) within r=1.0 — expect the two clusters, never across:"
pr@0
pr@1

/ ── Cloth integration: vectorized self-collision pass ─────────────────────────
/ Drop-in for test/cloth.k. After `applyPass'(hCons;...)` in clothSubstep, call
/ `selfCollide[]`. It reuses the same scatter-add-via-amend pattern as applyPass:
/ k=ci,cj indexes both ends of every overlapping pair, and amend-with-+ accumulates
/ a particle's many corrections in one pass. Push pairs closer than `thickness`
/ apart to `thickness`, split by inverse mass (pinned w=0 particles don't move).
/
/   thickness:: 0.02
/   selfCollide:{[]
/     px:g`px; py:g`py; pz:g`pz
/     pr:pairs[px;py;pz;thickness]; ci:pr@0; cj:pr@1
/     dx:(px@cj)-px@ci; dy:(py@cj)-py@ci; dz:(pz@cj)-pz@ci
/     d:sqrt[(dx*dx)+(dy*dy)+(dz*dz)]; dsc:d|0.0001
/     w0:gIm@ci; w1:gIm@cj; wt:w0+w1|0.0001
/     s:((thickness-d)*d>0.0001)%wt                 / per-pair correction magnitude / total weight
/     ndx:(dx%dsc)*s; ndy:(dy%dsc)*s; ndz:(dz%dsc)*s / unit separation * magnitude
/     k:ci,cj                                        / both ends; duplicates accumulate
/     g[`px]::@[px;k;+;(0.-ndx*w0),ndx*w1]           / ci moves back, cj moves forward
/     g[`py]::@[py;k;+;(0.-ndy*w0),ndy*w1]
/     g[`pz]::@[pz;k;+;(0.-ndz*w0),ndz*w1]}
