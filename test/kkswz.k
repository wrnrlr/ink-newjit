/ test/kkswz.k — swizzle lowering (dye.k): `v`x`z` selects vector lanes by name.
/
/ Sections 1-7 assert at the SPIR-V WORD level and need no device: each locates the
/ emitted OpVectorShuffle (or proves none was emitted) and reads its lane operands
/ straight out of the module. The spirv-val rung in test/oracles.sh covers module
/ validity; the lanes themselves are what validity CANNOT catch — a shuffle with
/ any permutation validates perfectly. Section 8 then dispatches on the real device
/ and checks the returned values, so the two rungs together pin encoding and effect.
/
/ Run: ink test/kkswz.k        (section 8 needs a GPU, like the other kk oracles)

2: "lib/gpu.k"
2: "lib/dye.k"

ok:: 0; nok:: 0
chk: {[nm;b] $[b; ok::ok+1; nok::nok+1]; $[b; 0; `0 0: "FAIL ",nm,"\n"]}

/ OpVectorShuffle 79 with n lanes: header word = ((5+n) shifted into the high
/ half) | 79. opXtract is fixed-width, so its header is the constant below.
shufW: {[n] 0x4F+0x10000*5+n}
XTRACT: 0x00050051
/ Index of the first word equal to `x (-1 when absent) — the shuffle is unique in
/ every kernel here, so a plain Find over the module is enough to locate it.
findW: {[w;x] i:&w=x; $[#i; *i; -1]}
/ The n lane operands of the shuffle: they trail (header;type;result;vecA;vecB).
lanes: {[w;n] i:findW[w;shufW n]; $[i<0; (); w@(i+5)+!n]}
/ Result type id of the shuffle (word 1 after the header).
shufTy: {[w;n] i:findW[w;shufW n]; $[i<0; -1; w i+1]}

/ A v4 local `c` built from the two uv lanes plus two constants, then swizzled.
/ Every case compiles the SAME body shape so the shuffle is the only difference.
f4: {[body] shader.fragment[(uv:`v2; out:`v4); body]}
f2: {[body] shader.fragment[(uv:`v2; out:`v2); body]}
f3: {[body] shader.fragment[(uv:`v2; out:`v3); body]}
/ A rejection latches xErr and yields `!xErr`; bind the result and never index it —
/ reading the latch IS the assertion. xReset clears it at the start of every compile.
bad: {[body] f4[body]; xErr}

run: {[]
  / ── 1. lane order is preserved exactly ─────────────────────────────────────
  w: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`z`y`x`w)}]
  chk["reverse swizzle emits a 4-lane shuffle"; -1<findW[w;shufW 4]]
  chk["`z`y`x`w → lanes 2 1 0 3";               (lanes[w;4])~2 1 0 3]
  chk["4-lane swizzle result type is v4";       (shufTy[w;4])=Tv4]
  w2: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`w`w`z`z)}]
  chk["`w`w`z`z → lanes 3 3 2 2"; (lanes[w2;4])~3 3 2 2]

  / ── 2. repeats are a splat — no separate broadcast path needed ─────────────
  w3: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`x`x`x`x)}]
  chk["`x`x`x`x splats → lanes 0 0 0 0"; (lanes[w3;4])~0 0 0 0]

  / ── 3. narrowing swizzles pick the result type from the lane count ─────────
  w4: f2[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`x`w)}]
  chk["`x`w → lanes 0 3";                 (lanes[w4;2])~0 3]
  chk["2-lane swizzle result type is v2"; (shufTy[w4;2])=Tv2]
  w5: f3[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`z`y`x)}]
  chk["`z`y`x → lanes 2 1 0";             (lanes[w5;3])~2 1 0]
  chk["3-lane swizzle result type is v3"; (shufTy[w5;3])=Tv3]

  / ── 4. one lane reuses OpCompositeExtract — no shuffle at all ──────────────
  w6: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`z; c`z; c`z; 1.0)}]
  chk["single lane emits no shuffle"; (findW[w6;shufW 1])<0]
  chk["single lane emits extracts";   -1<findW[w6;XTRACT]]
  / ...and it is the same module as spelling the extract positionally.
  p6: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); (c[2]; c[2]; c[2]; 1.0)}]
  chk["c`z ≡ c[2]"; w6~p6]

  / ── 5. rgba aliases xyzw, and the bracket form the juxtaposed one ──────────
  rgba: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`b`g`r`a)}]
  chk["`b`g`r`a ≡ `z`y`x`w"; rgba~w]
  brk: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); (c[`z`y`x`w])}]
  chk["c[`z`y`x`w] ≡ c`z`y`x`w"; brk~w]

  / ── 6. a swizzle of a PARAM, not just a local ──────────────────────────────
  w7: f4[{[uv] s:(uv`y`x); (s[0]; s[1]; 0.5; 1.0)}]
  chk["param swizzle uv`y`x → lanes 1 0"; (lanes[w7;2])~1 0]

  / ── 7. rejections latch xErr ───────────────────────────────────────────────
  chk["unknown lane name rejected"; ~`~bad[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`q`x`y`z)}]]
  chk["mixed name sets rejected";   ~`~bad[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`x`g`y`z)}]]
  chk["more than 4 lanes rejected"; ~`~bad[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`x`y`z`w`x)}]]
  chk["lane past a v2 rejected";    ~`~bad[{[uv] s:(uv`z`x); (s[0];s[1];0.5;1.0)}]]
  / ...and a legal swizzle after those leaves the latch clear.
  chk["valid swizzle leaves xErr clear"; `~bad[{[uv] c:(uv[0];uv[1];0.5;1.0); (c`z`y`x`w)}]]

  0}

/ ── 8. component writes: `v[`x`z]: e` ───────────────────────────────────────
/ In SSA a component write is a REBIND, not a mutation: v' = merge(v, e). One lane
/ is OpCompositeInsert, two or more a TWO-source OpVectorShuffle whose selector
/ reaches past the first vector's width (n+p) for the written lanes.
INSERT: 0x00060052
insLane: {[w] i:findW[w;INSERT]; $[i<0; -1; w i+5]}
/ Result id of the insert (opInsert = header;type;result;object;composite;lane).
insRes:  {[w] i:findW[w;INSERT]; $[i<0; -1; w i+2]}
/ Does any OpCompositeExtract read id `x? (opXtract = header;type;result;vec;lane)
xtrReads: {[w;x] is: &w=XTRACT; $[0=#is; 0b; |/{[w;x;i] x=w i+3}[w;x]'is]}
wrun: {[]
  / v4, lanes 0 and 2 written from a v2 → selector 4 1 5 3
  w: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); c[`x`z]: (0.25;0.75); c}]
  chk["write `x`z → selector 4 1 5 3"; (lanes[w;4])~4 1 5 3]
  / a single lane is an insert, not a shuffle
  w2: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); c[`y]: 0.25; c}]
  chk["write `y emits CompositeInsert"; -1<findW[w2;INSERT]]
  chk["write `y targets lane 1";        1=insLane[w2]]
  chk["single-lane write emits no shuffle"; (findW[w2;shufW 4])<0]
  / positional `v[0]:` is the same path — and used to be SILENTLY DROPPED
  w3: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); c[2]: 0.25; c}]
  chk["positional write c[2] targets lane 2"; 2=insLane[w3]]
  chk["c[2]: ≡ c[`z]:"; w3 ~ f4[{[uv] c:(uv[0];uv[1];0.5;1.0); c[`z]: 0.25; c}]]
  / a scalar RHS broadcasts across every written lane
  w4: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); c[`x`y`z]: 0.25; c}]
  chk["scalar RHS broadcasts → selector 4 5 6 3"; (lanes[w4;4])~4 5 6 3]
  / rejections
  chk["lane written twice rejected";  ~`~bad[{[uv] c:(uv[0];uv[1];0.5;1.0); c[`x`x]: (0.25;0.75); c}]]
  chk["write past the width rejected";~`~bad[{[uv] c:(uv[0];uv[1];0.5;1.0); c[`x`z`w`y`x]: 0.25; c}]]
  chk["RHS width mismatch rejected";  ~`~bad[{[uv] c:(uv[0];uv[1];0.5;1.0); c[`x`z]: (0.1;0.2;0.3); c}]]
  chk["unknown lvalue lane rejected"; ~`~bad[{[uv] c:(uv[0];uv[1];0.5;1.0); c[`q]: 0.25; c}]]
  / Writing the SOLE env entry (a 1-param shader, no other binds): a single-entry
  / env stores its lone value unwrapped, so the replace path differs from the
  / multi-entry one. The property that matters is that LATER READS see the new
  / value, i.e. an extract consumes the insert's result rather than the param.
  w6: f4[{[uv] uv[`x]: 0.5; (uv[0];uv[1];0.25;1.0)}]
  chk["sole-entry write emits an insert at lane 0"; 0=insLane[w6]]
  chk["later reads consume the insert's result";    xtrReads[w6; insRes w6]]
  / a plain rebind still reads back the NEW value (the duplicate-key env trap)
  w5: f4[{[uv] c:(uv[0];uv[1];0.5;1.0); c: (0.1;0.2;0.3;0.4); c}]
  p5: f4[{[uv] c:(0.1;0.2;0.3;0.4); c}]
  chk["rebinding a name shadows the old entry"; w5~p5]
  0}

/ ── 9. numeric parity on the DEVICE ─────────────────────────────────────────
/ The checks above pin the lane operands; this one proves the GPU actually returns
/ those lanes. Each kernel builds a v4 per element whose lanes are v, 10v, 100v,
/ 1000v — so a lane's identity is readable straight off the result.
X: 1. 2. 3. 4. 5. 6.
gpuRun: {[]
  gpu.computeRun[{[x]
    g1:: gpu.runShader[shader.compute[{[v] c:(v; v*10.; v*100.; v*1000.); s:(c`z`y`x`w); s[0]}]; X]
    g2:: gpu.runShader[shader.compute[{[v] c:(v; v*10.; v*100.; v*1000.); s:(c`w`z); s[1]}]; X]
    g3:: gpu.runShader[shader.compute[{[v] c:(v; v*10.; v*100.; v*1000.); s:(c`y`y`y`y); s[3]}]; X]
    g4:: gpu.runShader[shader.compute[{[v] c:(v; v*10.; v*100.; v*1000.); (c`b)}]; X]
    / component writes: overwrite lane 1 (10v) with 100v, then read it back
    g5:: gpu.runShader[shader.compute[{[v] c:(v; v*10.; v*100.; v*1000.); c[`y]: v*100.; c`y}]; X]
    g6:: gpu.runShader[shader.compute[{[v] c:(v; v*10.; v*100.; v*1000.); c[`x`y]: (v*100.; v*100.); c`y}]; X]
    0}]
  chk["gpu `z`y`x`w → lane 0 is z"; 1e-5 > |/ abs g1 - 100.*X]
  chk["gpu `w`z → lane 1 is z";     1e-5 > |/ abs g2 - 100.*X]
  chk["gpu `y`y`y`y splat";         1e-5 > |/ abs g3 -  10.*X]
  chk["gpu single lane `b";         1e-5 > |/ abs g4 - 100.*X]
  chk["gpu write c[`y] lands";      1e-5 > |/ abs g5 - 100.*X]
  chk["gpu write c[`x`y] lands";    1e-5 > |/ abs g6 - 100.*X]
  0}

z0: run[]
z2: wrun[]
z1: gpuRun[]
`0 0: "kkswz: ",($ok)," ok, ",($nok)," fail\n"
