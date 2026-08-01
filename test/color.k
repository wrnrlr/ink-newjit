2:"lib/color.k"

/ ── helper ──────────────────────────────────────────────────────────────────
pass: 0
fail: 0
chkN: 0
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; {fail::fail+1; `0 0:"FAIL #",($chkN)," ",name,"  got ",$x}[got]]; 0}

/ ── hsl2rgb: the six primaries sit exactly on the sector boundaries ──────────
chk["hsl 0 red";      hsl2rgb[0.;1.;0.5];   255 0 0]
chk["hsl 60 yellow";  hsl2rgb[60.;1.;0.5];  255 255 0]
chk["hsl 120 green";  hsl2rgb[120.;1.;0.5]; 0 255 0]
chk["hsl 180 cyan";   hsl2rgb[180.;1.;0.5]; 0 255 255]
chk["hsl 240 blue";   hsl2rgb[240.;1.;0.5]; 0 0 255]
chk["hsl 300 magenta";hsl2rgb[300.;1.;0.5]; 255 0 255]

/ ── mid-sector, desaturated, and the extremes ────────────────────────────────
chk["hsl 210 .5 .4";  hsl2rgb[210.;0.5;0.4]; 51 102 153]
chk["saturation 0";   hsl2rgb[0.;0.;0.5];    127 127 127]
chk["lightness 0";    hsl2rgb[123.;1.;0.];   0 0 0]
chk["lightness 1";    hsl2rgb[123.;1.;1.];   255 255 255]

/ ── hue wraps rather than running off the sector table ───────────────────────
chk["hue 360";        hsl2rgb[360.;1.;0.5];  255 0 0]
chk["hue 480";        hsl2rgb[480.;1.;0.5];  0 255 0]
chk["hue -120";       hsl2rgb[-120.;1.;0.5]; 0 0 255]

/ ── pct2rgb: the fully saturated wheel, x in 0..1 ────────────────────────────
chk["pct 0";          pct2rgb 0.;            255 0 0]
chk["pct 1%3";        pct2rgb 1.%3.;         0 255 0]
chk["pct .5";         pct2rgb 0.5;           0 255 255]
chk["pct 1.5 wraps";  pct2rgb 1.5;           0 255 255]

/ ── oklch stays bit-exact on the Tailwind neutral ramp ───────────────────────
hex: {[c] _0.5+255.*3#oklch c}
chk["neutral-500 #737373"; hex Neutral500; 115 115 115]
chk["neutral-800 #262626"; hex Neutral800; 38 38 38]
chk["neutral-50  #fafafa"; hex Neutral50;  250 250 250]
chk["neutral-950 #0a0a0a"; hex Neutral950; 10 10 10]

/ ── summary ─────────────────────────────────────────────────────────────────
`0 0:($pass)," passed, ",($fail)," failed"
