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

t.EVK:`kind`code`mods`down`x`y`amt
t.VIEW:{[] ui.label[""]}                          / current view thunk (0-arg → node tree)
t.ACT:{[a] 0}                                     / current per-action handler
t.VW:800.; t.VH:600.; t.DPR:1.                         / viewport (logical) + device pixel ratio
t.CX:0.; t.CY:0.; t.TIME:0.                            / cursor (framebuffer px) + sim time (s)
t.PEND:()                                          / events queued for the next flush
t.LW:()                                            / last solved widget table
t.LA:()                                            / last frame's returned actions
t.NPASS:0; t.NFAIL:0; t.FAILS:()                        / assertion tally

  / ── setup ────────────────────────────────────────────────────────────────────
  / Register the app: `vf` is a THUNK {[] node} returning the node tree for the current model;
  / `af` is {[a] …} run once per action ui.frame returns (updates the model). Either may be omitted
  / for framework-only tests — assert on ui.get/isFocus/getv + t.acts[] instead.
t.app:{[vf;af] t.VIEW::vf; t.ACT::af; `}
t.setView:{[vf] t.VIEW::vf; `}
t.onAct:{[af] t.ACT::af; `}
  / Viewport in LOGICAL units; dpr scales layout to framebuffer px (test coords stay logical).
t.viewport:{[w;h;dpr] t.VW::w; t.VH::h; t.DPR::dpr; t.CX::0.; t.CY::0.; `}
  / Wipe INTERACTION state between independent test groups (queue, cursor, time). Does NOT touch
  / the assertion tally — call it freely mid-suite; only t.begin resets the pass/fail counters.
t.reset:{[] t.PEND::(); t.LW::(); t.LA::(); t.CX::0.; t.CY::0.; t.TIME::0.; `}
  / Zero the assertion tally (call once at the top of a test file).
t.begin:{[] t.NPASS::0; t.NFAIL::0; t.FAILS::(); t.reset[]}

  / ── build the props dict the native window would feed ui.frame ────────────────
t.mkTbl:{[rows] t.EVK! $[0=#rows; (0#`z;0#0;0#0;0#0;0#0.;0#0.;0#0.); +rows]}
t.props:{[rows] `width`height`mx`my`time`dpr`events!(t.VW*t.DPR; t.VH*t.DPR; t.CX; t.CY; t.TIME; t.DPR; t.mkTbl rows)}

  / ── the core driver: run one frame from the queued (or given) events ──────────
  / 1) solve the view for the current model (hit-test table), 2) ui.frame → actions (real input
  / path: focus/menu/slider/keys mutate ui state), 3) dispatch each action to the app, 4) re-solve
  / so t.W[] reflects the post-action model. Clears the queue. Returns the actions.
t.step:{[rows]
    p: t.props rows
    W0: ui.run[t.VIEW[]; p]
    a:  ui.frame[W0; p]
    t.ACT'a
    t.LW:: ui.run[t.VIEW[]; p]                         / post-action geometry
    t.LA:: a
    t.PEND::()
    a}
  / low-level: queue events, flush explicitly (many events → ONE frame)
  / Driver helpers return null (the actions are read back via t.acts[]) so a test file can drive at
  / top level without every line auto-printing. Use t.step directly when you want the actions inline.
t.emit:{[rows] t.PEND:: t.PEND,rows; `}
t.flush:{[] t.step t.PEND; `}
t.frame:{[] t.step t.PEND; `}                          / an empty (or queued-only) frame; advances nothing

  / ── event constructors (framebuffer px = logical × dpr) ──────────────────────
t.pxx:{[x] x*t.DPR}; t.pxy:{[y] y*t.DPR}
t.evMouse:{[code;dn;x;y] (`mouse;code;0;dn;t.pxx x;t.pxy y;0n)}
t.evText:{[cp] (`text;cp;0;0N;t.CX;t.CY;0n)}
t.evKey:{[code;mods] (`key;code;mods;1;t.CX;t.CY;0n)}
t.evScroll:{[amt] (`scroll;0N;0;0N;t.CX;t.CY;amt)}

  / ── one-frame action helpers (each drives a frame; cursor persists) ───────────
  / a left click: move cursor there, then a down+up pair in one frame.
t.clickB:{[code;x;y] t.CX::t.pxx x; t.CY::t.pxy y; t.step (t.evMouse[code;1;x;y]; t.evMouse[code;0;x;y]); `}
t.click:{[x;y] t.clickB[0;x;y]}
t.rclick:{[x;y] t.clickB[1;x;y]}
  / press / release the left button separately (for drags): down at (x;y), later up.
  / (parens around the enlist: `step ,ev` would misparse as `step , ev` — `,` after the noun
  / `step` reads as DYADIC join, so step is never applied. `step (,ev)` forces monadic enlist.)
t.down:{[x;y] t.CX::t.pxx x; t.CY::t.pxy y; t.step (,t.evMouse[0;1;x;y]); `}
t.up:{[x;y] t.CX::t.pxx x; t.CY::t.pxy y; t.step (,t.evMouse[0;0;x;y]); `}
  / hover: move the cursor and run a frame (no event row; drag/hover read props`mx/my).
t.move:{[x;y] t.CX::t.pxx x; t.CY::t.pxy y; t.step (); `}
  / type a string: one `text event per codepoint, all in one frame.
  / (parens: `step evText' x` would misparse as `(step evText)' x` — the `'`-binds-left gotcha.)
t.type:{[s] t.step (t.evText' `i$s); `}
  / a single key press (259 backspace, 261 delete, 263/262 ←/→, 268/269 home/end, …).
t.key:{[code] t.step (,t.evKey[code;0]); `}
t.keyMod:{[code;mods] t.step (,t.evKey[code;mods]); `}
t.scroll:{[amt] t.step (,t.evScroll amt); `}
  / advance sim time by dt and run an idle frame (time-driven UI updates).
t.wait:{[dt] t.TIME:: t.TIME+dt; t.step (); `}
  / click a sequence of (x;y) points, one frame each (e.g. drag path via down/move/up is separate).
t.clicks:{[pts] {t.click . x}' pts}

  / ── inspecting the last frame ─────────────────────────────────────────────────
t.W:{[] t.LW}
t.acts:{[] t.LA}
  / first widget-table row index whose id matches `id`, or -1.
t.find:{[id] i:&(t.LW`id)~\:id; $[#i; *i; -1]}
  / the (x;y;w;h) rect (framebuffer px) of widget `id`, or () if absent.
t.rect:{[id] i:t.find id; $[i<0; (); ((t.LW`x)i;(t.LW`y)i;(t.LW`w)i;(t.LW`h)i)]}
  / a widget-table column value for `id` (e.g. t.val[`fx;`txt] → the drawn text).
t.val:{[id;col] i:t.find id; $[i<0; (); (t.LW col)i]}

  / ── assertions (quiet on pass, loud on fail; tally for t.report) ──────────────
t.pass:{[nm] t.NPASS:: t.NPASS+1; `}
t.failed:{[nm;msg] t.NFAIL:: t.NFAIL+1; t.FAILS:: t.FAILS,,nm; `0:"  FAIL ",nm," — ",msg,"\n"; `}
t.eq:{[nm;got;exp] $[got~exp; t.pass nm; t.failed[nm; ($got)," ~ ",$exp]]}
t.ok:{[nm;cond] $[cond; t.pass nm; t.failed[nm; "expected true"]]}
t.truthy:{[nm;cond] t.ok[nm; $[0=#cond; 0; ~0~*cond]]}   / non-empty & first item non-zero
  / assert an expression evaluates to an error value (protects the parse/eval verbs).
t.err:{[nm;v] t.ok[nm; iserr v]}

  / ── screenshots (golden PNG diffs) ───────────────────────────────────────────
  / A screenshot test runs INSIDE a headless render context: t.render[testThunk] wraps the whole
  / test in window.test (a hidden-window swapchain, no display) so the pure-k logic drivers (click,
  / type, …) and the GPU render path (ui.draw → gpu.shot) share one device. Sized to the CURRENT
  / viewport (set t.viewport before t.render), so shots are exactly VW×VH px (retina off).
  / Goldens live under t.shotDir (default test/golden), one PNG per name. First run for a name has
  / no golden → it's saved as the baseline and the assertion passes; later runs render to <name>.out.png
  / and pixel-diff it against the golden, failing if more than `tol` (fraction 0..1) of bytes differ.
t.shotDir:"test/golden"
t.setShotDir:{[d] t.shotDir::d; `}
  / RFN holds the test thunk for the window.test callback (a lambda can't close over render's
  / param — lambdas don't capture parent scope — so it reads this global instead).
t.RFN:{[] 0}
t.render:{[fn] t.RFN::fn; window.test[{[x] t.RFN[]; 0}; (t.VW*t.DPR),(t.VH*t.DPR)]; `}
  / ui.draw renders widget TEXT via ui.k's font; with no font set, drawTxt corrupts the frame (a
  / blank render). Load one lazily before the first shot. Override the path with t.setFont.
t.fontPath:"font/FiraCode-Regular.ttf"
t.fontSet:0
t.setFont:{[p] t.fontPath::p; t.fontSet::0; `}
t.loadFont:{[] ui.setFont (font.read t.fontPath) 0; t.fontSet::1}
t.ensureFont:{[] $[t.fontSet; 0; t.loadFont[]]}
  / render the current view to the GPU frame queue (call inside a shot, before gpu.shot flushes it).
t.paintNow:{[] t.ensureFont[]; p:t.props (); W:ui.run[t.VIEW[]; p]; ui.draw[W; t.VW*t.DPR; t.VH*t.DPR]}
  / pixel diff of two image.read dicts → fraction of bytes that differ (1.0 if dims mismatch).
  / (helpers, not bracketed $-branches: a `[stmt;stmt]` block inside $[…] breaks the parser.)
t.imDims:{[x] (x`width; x`height)}
t.byteDiff:{[da;db] n:(#da)&#db; $[n=0; 1.; (+/~(n#da)=n#db)%n]}
t.pngDiff:{[a;b] $[(t.imDims a)~t.imDims b; t.byteDiff[a`data; b`data]; 1.]}
  / path builder — kept as a var so `gpu.shot p` (not `gpu.shot dir,"/",…`, which parses as
  / `(gpu.shot dir),"/",…` — a monadic call binds before the `,`) targets the whole path.
t.shotPath:{[name;ext] t.shotDir,"/",name,ext}
  / t.shot[name] — capture the current view to <shotDir>/<name>.png (no assertion).
t.shot:{[name] t.paintNow[]; p:t.shotPath[name;".png"]; gpu.shot p; `}
  / golden branches as functions (again: no bracketed $-branches). Compare = render to <name>.out.png
  / and diff vs the golden; save = write the golden and pass (baseline on first run).
t.shotCmp:{[name;tol;g] out:t.shotPath[name;".out.png"]; gpu.shot out; o:image.read out; t.ok[name; (t.pngDiff[g;o])<tol]}
t.shotSave:{[name;gold] gpu.shot gold; `0:"  NOTE ",name," saved new golden (review + rerun)\n"; t.pass name}
  / t.shotEq[name;tol] — golden-diff the current view. Baseline-on-first-run; else assert diff<tol.
t.shotEq:{[name;tol] gold:t.shotPath[name;".png"]; g:image.read gold; t.paintNow[]; $[`m~@g; t.shotCmp[name;tol;g]; t.shotSave[name;gold]]}

  / ── report ───────────────────────────────────────────────────────────────────
t.report:{[]
    n: t.NPASS+t.NFAIL
    `0:"\n",($n)," assertions: ",($t.NPASS)," passed, ",($t.NFAIL)," failed\n"
    $[t.NFAIL>0; `0:"FAILED: ",(","/$t.FAILS),"\n"; `0:"ALL PASS\n"]
    t.NFAIL}
