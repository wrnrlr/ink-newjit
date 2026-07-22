/ lib/uitest.k — a deterministic, replayable test harness for lib/ui.k apps (one `t` namespace).
/ Load AFTER lib/ui.k:  2: "lib/ui.k"  then  2: "lib/uitest.k".
/
/ WHY THIS WORKS. A ui.k frame is a pure function of (model, props): input is a TABLE (props`events)
/ and time/cursor ride in props, so a test is a SCRIPTED EVENT STREAM replayed frame by frame — no
/ live window, no GPU. The harness builds the SAME `kind code mods down x y amt` event table the
/ native window feeds `ui.frame`, drives ui.run + ui.frame (the real input + layout path), then lets
/ you assert on model state, framework state (ui.get/isFocus/getv), or geometry (the widget table W).
/ Only ui.draw touches the GPU, and a headless test never calls it (see t.shot for pixels).
/
/ SHAPE OF A TEST.
/   t.app[{[] view[]}; {[a] act a}]   / register a view THUNK (0-arg → node tree) + action handler
/   t.click[x;y]                      / drive a frame: a mouse down+up at (x,y) in LOGICAL px
/   t.type["=A0+B1"]                  / drive a frame: one `text event per codepoint
/   t.key[259]                        / drive a frame: a `key press (259=backspace, 263/262=←/→ …)
/   t.eq["selected"; sheet.selCell; `A0]         / assert model state
/   t.eq["6 cells"; #t.W[]`x; 6]                 / assert geometry / hit-test
/   t.report[]                        / print "N passed / M failed", list failures, set exit status
/ Coords are LOGICAL units at dpr=1 (the default) so they match the flexbox layout 1:1. Every action
/ helper drives exactly ONE frame; accumulate several events into one frame with t.emit + t.flush.

\d t app setView onAct viewport reset begin click rclick down up move type key keyMod scroll wait frame emit flush step W acts find rect val eq ok truthy err report clicks render shot shotEq setShotDir shotDir setFont

  / ── harness state ────────────────────────────────────────────────────────────
  EVK:`kind`code`mods`down`x`y`amt
  VIEW:{[] ui.label[""]}                          / current view thunk (0-arg → node tree)
  ACT:{[a] 0}                                     / current per-action handler
  VW:800.; VH:600.; DPR:1.                         / viewport (logical) + device pixel ratio
  CX:0.; CY:0.; TIME:0.                            / cursor (framebuffer px) + sim time (s)
  PEND:()                                          / events queued for the next flush
  LW:()                                            / last solved widget table
  LA:()                                            / last frame's returned actions
  NPASS:0; NFAIL:0; FAILS:()                        / assertion tally

  / ── setup ────────────────────────────────────────────────────────────────────
  / Register the app: `vf` is a THUNK {[] node} returning the node tree for the current model;
  / `af` is {[a] …} run once per action ui.frame returns (updates the model). Either may be omitted
  / for framework-only tests — assert on ui.get/isFocus/getv + t.acts[] instead.
  app:{[vf;af] VIEW::vf; ACT::af; `}
  setView:{[vf] VIEW::vf; `}
  onAct:{[af] ACT::af; `}
  / Viewport in LOGICAL units; dpr scales layout to framebuffer px (test coords stay logical).
  viewport:{[w;h;dpr] VW::w; VH::h; DPR::dpr; CX::0.; CY::0.; `}
  / Wipe INTERACTION state between independent test groups (queue, cursor, time). Does NOT touch
  / the assertion tally — call it freely mid-suite; only t.begin resets the pass/fail counters.
  reset:{[] PEND::(); LW::(); LA::(); CX::0.; CY::0.; TIME::0.; `}
  / Zero the assertion tally (call once at the top of a test file).
  begin:{[] NPASS::0; NFAIL::0; FAILS::(); reset[]}

  / ── build the props dict the native window would feed ui.frame ────────────────
  mkTbl:{[rows] EVK! $[0=#rows; (0#`z;0#0;0#0;0#0;0#0.;0#0.;0#0.); +rows]}
  props:{[rows] `width`height`mx`my`time`dpr`events!(VW*DPR; VH*DPR; CX; CY; TIME; DPR; mkTbl rows)}

  / ── the core driver: run one frame from the queued (or given) events ──────────
  / 1) solve the view for the current model (hit-test table), 2) ui.frame → actions (real input
  / path: focus/menu/slider/keys mutate ui state), 3) dispatch each action to the app, 4) re-solve
  / so t.W[] reflects the post-action model. Clears the queue. Returns the actions.
  step:{[rows]
    p: props rows
    W0: ui.run[VIEW[]; p]
    a:  ui.frame[W0; p]
    ACT'a
    LW:: ui.run[VIEW[]; p]                         / post-action geometry
    LA:: a
    PEND::()
    a}
  / low-level: queue events, flush explicitly (many events → ONE frame)
  / Driver helpers return null (the actions are read back via t.acts[]) so a test file can drive at
  / top level without every line auto-printing. Use t.step directly when you want the actions inline.
  emit:{[rows] PEND:: PEND,rows; `}
  flush:{[] step PEND; `}
  frame:{[] step PEND; `}                          / an empty (or queued-only) frame; advances nothing

  / ── event constructors (framebuffer px = logical × dpr) ──────────────────────
  pxx:{[x] x*DPR}; pxy:{[y] y*DPR}
  evMouse:{[code;dn;x;y] (`mouse;code;0;dn;pxx x;pxy y;0n)}
  evText:{[cp] (`text;cp;0;0N;CX;CY;0n)}
  evKey:{[code;mods] (`key;code;mods;1;CX;CY;0n)}
  evScroll:{[amt] (`scroll;0N;0;0N;CX;CY;amt)}

  / ── one-frame action helpers (each drives a frame; cursor persists) ───────────
  / a left click: move cursor there, then a down+up pair in one frame.
  clickB:{[code;x;y] CX::pxx x; CY::pxy y; step (evMouse[code;1;x;y]; evMouse[code;0;x;y]); `}
  click:{[x;y] clickB[0;x;y]}
  rclick:{[x;y] clickB[1;x;y]}
  / press / release the left button separately (for drags): down at (x;y), later up.
  / (parens around the enlist: `step ,ev` would misparse as `step , ev` — `,` after the noun
  / `step` reads as DYADIC join, so step is never applied. `step (,ev)` forces monadic enlist.)
  down:{[x;y] CX::pxx x; CY::pxy y; step (,evMouse[0;1;x;y]); `}
  up:{[x;y] CX::pxx x; CY::pxy y; step (,evMouse[0;0;x;y]); `}
  / hover: move the cursor and run a frame (no event row; drag/hover read props`mx/my).
  move:{[x;y] CX::pxx x; CY::pxy y; step (); `}
  / type a string: one `text event per codepoint, all in one frame.
  / (parens: `step evText' x` would misparse as `(step evText)' x` — the `'`-binds-left gotcha.)
  type:{[s] step (evText' `i$s); `}
  / a single key press (259 backspace, 261 delete, 263/262 ←/→, 268/269 home/end, …).
  key:{[code] step (,evKey[code;0]); `}
  keyMod:{[code;mods] step (,evKey[code;mods]); `}
  scroll:{[amt] step (,evScroll amt); `}
  / advance sim time by dt and run an idle frame (time-driven UI updates).
  wait:{[dt] TIME:: TIME+dt; step (); `}
  / click a sequence of (x;y) points, one frame each (e.g. drag path via down/move/up is separate).
  clicks:{[pts] {click . x}' pts}

  / ── inspecting the last frame ─────────────────────────────────────────────────
  W:{[] LW}
  acts:{[] LA}
  / first widget-table row index whose id matches `id`, or -1.
  find:{[id] i:&(LW`id)~\:id; $[#i; *i; -1]}
  / the (x;y;w;h) rect (framebuffer px) of widget `id`, or () if absent.
  rect:{[id] i:find id; $[i<0; (); ((LW`x)i;(LW`y)i;(LW`w)i;(LW`h)i)]}
  / a widget-table column value for `id` (e.g. t.val[`fx;`txt] → the drawn text).
  val:{[id;col] i:find id; $[i<0; (); (LW col)i]}

  / ── assertions (quiet on pass, loud on fail; tally for t.report) ──────────────
  pass:{[nm] NPASS:: NPASS+1; `}
  failed:{[nm;msg] NFAIL:: NFAIL+1; FAILS:: FAILS,,nm; `0:"  FAIL ",nm," — ",msg,"\n"; `}
  eq:{[nm;got;exp] $[got~exp; pass nm; failed[nm; ($got)," ~ ",$exp]]}
  ok:{[nm;cond] $[cond; pass nm; failed[nm; "expected true"]]}
  truthy:{[nm;cond] ok[nm; $[0=#cond; 0; ~0~*cond]]}   / non-empty & first item non-zero
  / assert an expression evaluates to an error value (protects the parse/eval verbs).
  err:{[nm;v] ok[nm; iserr v]}

  / ── screenshots (golden PNG diffs) ───────────────────────────────────────────
  / A screenshot test runs INSIDE a headless render context: t.render[testThunk] wraps the whole
  / test in window.test (a hidden-window swapchain, no display) so the pure-k logic drivers (click,
  / type, …) and the GPU render path (ui.draw → gpu.shot) share one device. Sized to the CURRENT
  / viewport (set t.viewport before t.render), so shots are exactly VW×VH px (retina off).
  / Goldens live under t.shotDir (default test/golden), one PNG per name. First run for a name has
  / no golden → it's saved as the baseline and the assertion passes; later runs render to <name>.out.png
  / and pixel-diff it against the golden, failing if more than `tol` (fraction 0..1) of bytes differ.
  shotDir:"test/golden"
  setShotDir:{[d] shotDir::d; `}
  / RFN holds the test thunk for the window.test callback (a lambda can't close over render's
  / param — lambdas don't capture parent scope — so it reads this global instead).
  RFN:{[] 0}
  render:{[fn] RFN::fn; window.test[{[x] RFN[]; 0}; (VW*DPR),(VH*DPR)]; `}
  / ui.draw renders widget TEXT via ui.k's font; with no font set, drawTxt corrupts the frame (a
  / blank render). Load one lazily before the first shot. Override the path with t.setFont.
  fontPath:"font/FiraCode-Regular.ttf"
  fontSet:0
  setFont:{[p] fontPath::p; fontSet::0; `}
  loadFont:{[] ui.setFont (font.read fontPath) 0; fontSet::1}
  ensureFont:{[] $[fontSet; 0; loadFont[]]}
  / render the current view to the GPU frame queue (call inside a shot, before gpu.shot flushes it).
  paintNow:{[] ensureFont[]; p:props (); W:ui.run[VIEW[]; p]; ui.draw[W; VW*DPR; VH*DPR]}
  / pixel diff of two image.read dicts → fraction of bytes that differ (1.0 if dims mismatch).
  / (helpers, not bracketed $-branches: a `[stmt;stmt]` block inside $[…] breaks the parser.)
  imDims:{[x] (x`width; x`height)}
  byteDiff:{[da;db] n:(#da)&#db; $[n=0; 1.; (+/~(n#da)=n#db)%n]}
  pngDiff:{[a;b] $[(imDims a)~imDims b; byteDiff[a`data; b`data]; 1.]}
  / path builder — kept as a var so `gpu.shot p` (not `gpu.shot dir,"/",…`, which parses as
  / `(gpu.shot dir),"/",…` — a monadic call binds before the `,`) targets the whole path.
  shotPath:{[name;ext] shotDir,"/",name,ext}
  / t.shot[name] — capture the current view to <shotDir>/<name>.png (no assertion).
  shot:{[name] paintNow[]; p:shotPath[name;".png"]; gpu.shot p; `}
  / golden branches as functions (again: no bracketed $-branches). Compare = render to <name>.out.png
  / and diff vs the golden; save = write the golden and pass (baseline on first run).
  shotCmp:{[name;tol;g] out:shotPath[name;".out.png"]; gpu.shot out; o:image.read out; ok[name; (pngDiff[g;o])<tol]}
  shotSave:{[name;gold] gpu.shot gold; `0:"  NOTE ",name," saved new golden (review + rerun)\n"; pass name}
  / t.shotEq[name;tol] — golden-diff the current view. Baseline-on-first-run; else assert diff<tol.
  shotEq:{[name;tol] gold:shotPath[name;".png"]; g:image.read gold; paintNow[]; $[`m~@g; shotCmp[name;tol;g]; shotSave[name;gold]]}

  / ── report ───────────────────────────────────────────────────────────────────
  report:{[]
    n: NPASS+NFAIL
    `0:"\n",($n)," assertions: ",($NPASS)," passed, ",($NFAIL)," failed\n"
    $[NFAIL>0; `0:"FAILED: ",(","/$FAILS),"\n"; `0:"ALL PASS\n"]
    NFAIL}
\d
