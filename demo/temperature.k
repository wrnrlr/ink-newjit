/ demo/temperature.k — 7GUIs #2 (Temperature Converter): two-way binding.
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/temperature.k
/ Snapshot:             ink -snap 0.4 demo/temperature.k
/
/ Two text inputs, Celsius and Fahrenheit. Editing either recomputes the other; an unparseable
/ entry leaves the other untouched. There is NO separate model — the two `ui` buffers ARE the
/ state; two-way binding = each frame, read the FOCUSED (edited) field, and if it's a valid
/ number write the converted value into the other. Reading the focused one avoids clobbering
/ what the user is typing.

2: "lib/ui.k"
ui.setFont (font.read "font/FiraCode-Regular.ttf") 0
ui.set[`c; "20"]; ui.set[`f; "68"]

\d world
  / ── numeric validation on codepoints (single-char strings are atoms — normalise first) ──
  digv:{[t] isd:(~t<48)&(~t>57); isdot:t=46; (&/isd|isdot)&(~1<+/isdot)&0<+/isd}
  okv:{[v] neg:45=*v; t:$[neg;1_v;v]; $[0=#t;0;digv t]}
  isNum:{[s] v:(0#0),`i$s; $[0=#v;0;okv v]}
  num:{[s] . s}                                  / parse (safe: only called when isNum)
  fmt:{[x] $0.1*_0.5+10.*x}                       / round to 0.1 and format
  cToF:{[c] 32.+c*9%5}
  fToC:{[f] (f-32.)*5%9}
  / write `dst` from `src` through `conv`, only if `src` currently parses.
  syncFrom:{[src;dst;conv] s:ui.get src; $[isNum s; ui.set[dst; fmt conv num s]; 0]}
  sync:{[] $[ui.focus~`c; syncFrom[`c;`f;cToF]; ui.focus~`f; syncFrom[`f;`c;fToC]; 0]}

  view:{[] ui.bg[0.96 0.96 0.98 1.; ui.pad[44.; ui.col[26.; (
    ui.label["Temperature Converter"]
    ui.row[12.; (
      ui.input[`c; 110.; "°C"]
      ui.sized[112.;34.; ui.label["Celsius  ="]]
      ui.input[`f; 110.; "°F"]
      ui.sized[112.;34.; ui.label["Fahrenheit"]] )]
    ui.spacer[] )]]}
\d

run:{[props]
  W: ui.run[world.view[]; props]
  {0}' ui.frame[W; props`events]     / edit the focused buffer
  world.sync[]                        / propagate to the other field
  ui.draw[ui.run[world.view[]; props]; props`width; props`height]}

window.run[run; 720. 300.]
