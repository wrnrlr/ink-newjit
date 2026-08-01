/ demo/flight.k — 7GUIs #3 (Flight Booker): combo, validation, enable/disable.
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/flight.k
/ Snapshot:             ink -snap 0.4 demo/flight.k
/
/ A dropdown picks one-way / return. Two date fields (DD.MM.YYYY). Return date is DISABLED for a
/ one-way flight. An unparseable date turns its field RED. Book is enabled only when the dates are
/ valid and (for a return) the return date isn't before the start. Everything the UI shows is a
/ DERIVED function of the two buffers + the combo — computed fresh in `view`, no extra state.

2: "lib/ui.k"
ui.setFont (font.read "font/FiraCode-Regular.ttf") 0
ui.set[`type; "one-way flight"]; ui.set[`d1; "27.03.2014"]; ui.set[`d2; "27.03.2014"]

world.msg: ""
world.TYPES: ("one-way flight"; "return flight")
  / strict DD.MM.YYYY → comparable int YYYYMMDD, else 0N.
world.dk10:{[v]
    d:(v@0 1 3 4 6 7 8 9)-48
    ok:((&/~d<0)&&/~d>9)&(46=v 2)&46=v 5
    day:(10*d 0)+d 1; mon:(10*d 2)+d 3; yr:((1000*d 4)+(100*d 5)+(10*d 6)+d 7)
    $[ok&(~day<1)&(~day>31)&(~mon<1)&(~mon>12); ((yr*10000)+(mon*100)+day); 0N]}
world.dateKey:{[s] v:(0#0),`i$s; $[10=#v; world.dk10 v; 0N]}
world.valid:{[s] ~0N~world.dateKey s}
world.isReturn:{[] (ui.get`type)~"return flight"}
  / bookable: one-way needs a valid start; return also needs a valid, not-earlier end.
world.bookable:{[] $[world.isReturn[]; ((world.valid ui.get`d1)&world.valid ui.get`d2)&~world.dateKey[ui.get`d2]<world.dateKey ui.get`d1; world.valid ui.get`d1]}

world.act:{[a] $[a~`book; world.doBook[]; 0]}
world.doBook:{[] world.msg:: "Booked a ",(ui.get`type)," on ",(ui.get`d1),$[world.isReturn[]; " returning ",ui.get`d2; ""]}

  / a date field: red when its content doesn't parse.
world.field:{[key] f:ui.input[key; 260.; "DD.MM.YYYY"]; $[world.valid ui.get key; f; ui.invalid f]}
world.d2field:{[] $[world.isReturn[]; world.field`d2; ui.disabled ui.input[`d2; 260.; "DD.MM.YYYY"]]}
world.bookBtn:{[] b:ui.button["Book"; `book]; $[world.bookable[]; b; ui.disabled b]}
world.msgLine:{[] $[world.msg~""; ui.spacer[]; ui.label world.msg]}

world.view:{[] ui.bg[0.96 0.96 0.98 1.; ui.pad[40.; ui.col[16.; (
    ui.label["Book a Flight"]
    ui.select[`type; 260.; world.TYPES]
    world.field`d1
    world.d2field[]
    world.bookBtn[]
    world.msgLine[]
    ui.spacer[] )]]]}

run:{[props]
  W: ui.run[world.view[]; props]
  {world.act x}' ui.frame[W; props]
  ui.draw[ui.run[world.view[]; props]; props`width; props`height]}

window.run[run; 460. 400.]
