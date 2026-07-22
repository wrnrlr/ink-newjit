/ test/ui.k — regression tests for lib/ui.k, driven by the headless harness lib/uitest.k.
/ Run:  ./zig-out/bin/ink test/ui.k         (needs  zig build gpu  for the dylib the libs load)
/
/ These exercise the REAL input + layout path headlessly (no window, no GPU): each t.* action
/ builds the same props`events table the native window feeds ui.frame, then drives ui.run+ui.frame
/ and asserts on geometry (the widget table W), hit-testing, action dispatch, and interaction state
/ (typed buffers, caret motion, slider/select/list values — all of it commits headlessly).
/ The suite is wrapped in a lambda so only t.report's summary prints (a top-level statement's value
/ auto-prints in script mode; a lambda body's intermediate statements do not).

2: "lib/ui.k"
2: "lib/uitest.k"

main:{[]
  t.begin[]

  / ── layout: flexbox row distributes slack across grows, honours gap ─────────────
  t.setView {[] ui.row[8.; (ui.grow[1.; ui.button["A";`a]] ; ui.grow[1.; ui.button["B";`b]])]}
  t.viewport[200.;100.;1.]
  t.frame[]
  t.eq["row: two widgets"; #t.W[]`x; 2]
  t.eq["row: equal grow widths"; t.W[]`w; 96. 96.]        / (200-8)/2 each
  t.eq["row: second starts after first+gap"; t.W[]`x; 0. 104.]

  / ── layout: column honours pad + gap, stacks on the main (y) axis ───────────────
  t.setView {[] ui.pad[10.; ui.col[6.; (ui.button["A";`a] ; ui.button["B";`b])]]}
  t.frame[]
  t.eq["col: pad offsets first child"; *t.W[]`y; 10.]
  t.eq["col: gap between rows"; t.W[]`y; 10. 52.]          / 10 + btnH(36) + gap(6)

  / ── intrinsic sizes: a label is content-sized (monospace-exact) ─────────────────
  t.setView {[] ui.row[0.; ,ui.label["hello"]]}
  t.frame[]
  t.eq["label width = 5ch*18*0.6 + 4"; *t.W[]`w; (5.*18.*0.6)+4.]

  / ── progress: a pure-flexbox gauge fills `frac` of its track ─────────────────────
  t.setView {[] ui.progress[0.25; 200.; 20.]}
  t.frame[]
  / the spacer (no bg/text, inert) is not emitted, so only the track bg + fill box render.
  t.eq["progress: track + fill rows"; #t.W[]`x; 2]
  t.truthy["progress: fill narrower than track"; ,((t.W[]`w) 1) < (t.W[]`w) 0]

  / ── hit-test: topmost (last row) wins; a miss returns -1 ────────────────────────
  t.setView {[] ui.button["A";`a]}
  t.frame[]
  t.eq["hit inside"; ui.hit[t.W[]; 50.; 50.]; 0]
  t.eq["hit left of widget"; ui.hit[t.W[]; -5.; 50.]; -1]
  t.eq["hit below widget"; ui.hit[t.W[]; 50.; 999.]; -1]

  / ── action dispatch: clicking a button returns its action ───────────────────────
  t.reset[]
  t.app[{[] ui.button["Go"; `go]}; {[a] 0}]
  t.viewport[200.;80.;1.]
  t.click[50.;40.]
  t.eq["button click → its action"; t.acts[]; ,`go]

  / ── focus: clicking an input focuses it; clicking empty space defocuses ─────────
  t.reset[]
  t.setView {[] ui.input[`fx; 300.; "type"]}
  t.viewport[320.;80.;1.]
  t.click[40.;30.]
  t.eq["input focused after click"; ui.isFocus`fx; 1b]
  t.setView {[] ui.row[0.; (,ui.sized[50.;30.; ui.input[`fx; 50.; ""]])]}
  t.click[300.;300.]
  t.eq["click outside defocuses"; ui.isFocus`fx; 0b]

  / ── text editing: type / backspace / caret motion all commit through ui.frame ───
  t.reset[]
  t.setView {[] ui.input[`fx; 300.; "type"]}
  t.viewport[320.;80.;1.]
  t.click[40.;30.]
  t.type["Hello"]
  t.eq["typed text retained"; ui.get`fx; "Hello"]
  t.eq["caret at end after type"; ui.caret; 5]
  t.key[259]                                    / backspace
  t.eq["backspace deletes last char"; ui.get`fx; "Hell"]
  t.key[263]                                    / ← left
  t.key[263]
  t.type["X"]                                   / insert mid
  t.eq["left-arrow then insert"; ui.get`fx; "HeXll"]
  t.key[268]                                    / home
  t.type["Z"]
  t.eq["home then insert"; ui.get`fx; "ZHeXll"]
  t.key[269]                                    / end
  t.type["!"]
  t.eq["end then insert"; ui.get`fx; "ZHeXll!"]

  / ── slider: press + drag sets the value proportionally ─────────────────────────
  t.reset[]
  t.setView {[] ui.slider[`sl; 200.; 0.; 100.]}
  t.viewport[240.;60.;1.]
  t.down[10.;10.]
  t.move[110.;10.]
  t.up[110.;10.]
  t.truthy["slider drag sets value > 0"; ,(ui.getv`sl) > 0.]
  t.truthy["slider drag ≈ 50 at midpoint"; ,((ui.getv`sl)>40.)&(ui.getv`sl)<60.]

  / ── select: click opens the dropdown, clicking an option picks + closes it ──────
  t.reset[]
  t.setView {[] ui.col[0.; (ui.select[`sel; 150.; ("A";"B";"C")] ; ui.grow[1.; ui.spacer[]])]}
  t.viewport[150.;200.;1.]
  t.click[70.;15.]                              / box at y 0..34
  t.eq["select opens"; ui.open; `sel]
  t.click[70.;85.]                              / option B at y 68..102 (34 + 34*1)
  t.eq["select picks option B"; ui.get`sel; "B"]
  t.eq["select closes after pick"; ui.open; `none]

  / ── list: a single-frame click selects the item under the cursor ────────────────
  t.reset[]
  t.setView {[] ui.list[`ls; ("one";"two";"three"); 200.; 120.]}
  t.viewport[240.;160.;1.]
  t.click[20.;50.]
  t.eq["list selects row under cursor"; ui.getv`ls; 1.]

  t.report[]}

main[]
