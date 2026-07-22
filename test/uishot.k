/ test/uishot.k — golden-PNG screenshot tests for lib/ui.k, driven by lib/uitest.k.
/ Run:  ./zig-out/bin/ink test/uishot.k       (needs  zig build gpu)
/ First run for each name saves a baseline under test/golden/<name>.png (review + commit it);
/ later runs render to <name>.out.png and pixel-diff it against the golden.
/
/ Screenshot tests run INSIDE t.render (a hidden-window headless swapchain — no display), so the
/ pure-k logic drivers (click/type/…) and the GPU render path (ui.draw → gpu.shot) share one device.

2: "lib/ui.k"
2: "lib/uitest.k"

main:{[]
  t.begin[]
  t.viewport[300.;160.;1.]
  t.render {[]
    / 1) a single button, padded
    t.setView {[] ui.pad[16.; ui.button["Click me"; `go]]}
    t.shotEq["button"; 0.01]

    / 2) an input after focusing + typing — proves logic frames + render compose
    t.setView {[] ui.pad[16.; ui.input[`fx; 260.; "name"]]}
    t.click[40.;40.]
    t.type["Werner"]
    t.shotEq["input-typed"; 0.01]

    / 3) a row of two buttons
    t.setView {[] ui.pad[12.; ui.row[10.; (ui.button["OK";`ok] ; ui.button["Cancel";`no])]]}
    t.frame[]
    t.shotEq["two-buttons"; 0.01] }
  t.report[]}

main[]
