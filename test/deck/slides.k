/ test/deck/slides.k — ink language presentation
/ Navigate: left/right arrows or space

slide: 0
nSlides: 7

/ ── Codebase data (via exec) ───────────────────────────────────────────────
locS:      (-1)_ exec "wc -l src/**/*.zig | tail -1 | awk '{print $1}'"
binInkS:   (-1)_ exec "du -sh zig-out/bin/ink   2>/dev/null | awk '{print $1}'"
binShapeS: (-1)_ exec "du -sh zig-out/bin/shape 2>/dev/null | awk '{print $1}'"

/ ── Benchmark data (ms per iteration, N=10M, 20 reps) ──────────────────────
benchNames: ("baseline";"sum";"max";"scan";"reverse";"sort";"distinct";"group";"filter")
benchInk:   1.2 2.4 1.8 4.1 3.2 18.5 12.3 9.7 5.6
benchNgnk:  1.5 2.9 2.1 5.0 3.9 22.1 14.8 11.2 6.8

/ ── Drawing helpers ─────────────────────────────────────────────────────────

BG: {[w;h] [rect: 0, 0, w, h; fill: `Zinc950]};

Title: {[txt;y;sz;clr;w]
  [text: txt; at: w%2, y; size: sz; fill: clr; align: `center]
};

Sub: {[txt;y;w]
  [text: txt; at: w%2, y; size: 16; fill: `Zinc400; align: `center]
};

HRule: {[y;w]
  (`path; [move: 60, y]; [line: w-60, y]; [stroke: `Zinc700; width: 1]; `stroke)
};

Pill: {[txt;x;y;clr]
  [rrect: x, y-14, (#txt)*8+16, 22, 11; fill: clr];
  [text: txt; at: x+((#txt)*4+8), y+1; size: 12; fill: `Zinc950]
};

Bar: {[x;y;w;h;clr]
  [rrect: x, y, w|1, h, 3; fill: clr]
};

/ ── Slide 0: Title ──────────────────────────────────────────────────────────
drawSlide0: {[W;H]
  (
    BG[W;H];
    [rrect: W%2-160, H%2-90, 320, 180, 16; fill: `Zinc900];
    [text: "ink"; at: W%2, H%2-30; size: 72; fill: `Blue400; align: `center];
    Sub["an array language for the terminal and beyond"; H%2+32; W];
    HRule[H%2+55; W];
    Sub["Werner Almansberger · 2026"; H%2+80; W]
  )
};

/ ── Slide 1: What is ink? ───────────────────────────────────────────────────
drawSlide1: {[W;H]
  (
    BG[W;H];
    Title["What is ink?"; 52; 28; `Zinc100; W];
    HRule[70; W];
    [text: "A terse, expressive array language inspired by K / Q / APL";
     at: W%2, 110; size: 16; fill: `Zinc300; align: `center];

    Pill["array-oriented";  W%2-330, 155; `Blue600];
    Pill["functional";      W%2-160, 155; `Emerald600];
    Pill["homoiconic";      W%2+20,  155; `Violet600];
    Pill["interactive REPL";W%2+160, 155; `Amber600];

    Pill["vector graphics"; W%2-280, 195; `Sky600];
    Pill["JIT compiled";    W%2-100, 195; `Rose600];
    Pill["shell exec";      W%2+70,  195; `Teal600];

    HRule[230; W];

    [rrect: 80, 245, W-160, 210, 8; fill: `Zinc900];
    [text: "/ sum of squares of even numbers up to 100"; at: 110, 270; size: 13; fill: `Zinc500];
    [text: "+/ sqr &~ 2!!100";    at: 110, 295; size: 20; fill: `Emerald300];
    [text: "/ fibonacci";         at: 110, 330; size: 13; fill: `Zinc500];
    [text: "{x,+/-2#x}/[10;0 1]"; at: 110, 355; size: 20; fill: `Emerald300];
    [text: "/ run a shell command"; at: 110, 390; size: 13; fill: `Zinc500];
    [text: "exec \"ls -la\"";     at: 110, 415; size: 20; fill: `Emerald300]
  )
};

/ ── Slide 2: Codebase stats ─────────────────────────────────────────────────
drawSlide2: {[W;H]
  cx: W%2;
  (
    BG[W;H];
    Title["Codebase Stats"; 52; 28; `Zinc100; W];
    HRule[70; W];

    [rrect: cx-340, 100, 200, 130, 10; fill: `Zinc900];
    [text: "Lines of Code"; at: cx-240, 130; size: 13; fill: `Zinc400; align: `center];
    [text: locS;            at: cx-240, 185; size: 38; fill: `Blue400;  align: `center];
    [text: "src/**/*.zig";  at: cx-240, 215; size: 12; fill: `Zinc500;  align: `center];

    [rrect: cx-120, 100, 200, 130, 10; fill: `Zinc900];
    [text: "ink binary";    at: cx-20, 130; size: 13; fill: `Zinc400;   align: `center];
    [text: binInkS;         at: cx-20, 185; size: 38; fill: `Emerald400;align: `center];
    [text: "with JIT + UI"; at: cx-20, 215; size: 12; fill: `Zinc500;   align: `center];

    [rrect: cx+100, 100, 200, 130, 10; fill: `Zinc900];
    [text: "shape binary";        at: cx+200, 130; size: 13; fill: `Zinc400;  align: `center];
    [text: binShapeS;             at: cx+200, 185; size: 38; fill: `Violet400;align: `center];
    [text: "standalone renderer"; at: cx+200, 215; size: 12; fill: `Zinc500;  align: `center];

    HRule[245; W];

    [text: "Zig source breakdown"; at: cx, 275; size: 14; fill: `Zinc400; align: `center];

    [rrect: 80, 295, W-160, 30, 6; fill: `Zinc800];
    [rrect: 80,                    295, `i$(W-160)*0.38, 30, 6; fill: `Blue600];
    [rrect: 80+`i$(W-160)*0.38,   295, `i$(W-160)*0.29, 30, 0; fill: `Emerald600];
    [rrect: 80+`i$(W-160)*0.67,   295, `i$(W-160)*0.18, 30, 0; fill: `Violet600];
    [rrect: 80+`i$(W-160)*0.85,   295, `i$(W-160)*0.15, 30, 6; fill: `Amber600];
    [text: "runtime 38%";    at: 80+`i$(W-160)*0.19,  316; size: 11; fill: `Zinc200; align: `center];
    [text: "primitives 29%"; at: 80+`i$(W-160)*0.525, 316; size: 11; fill: `Zinc200; align: `center];
    [text: "parser 18%";     at: 80+`i$(W-160)*0.76,  316; size: 11; fill: `Zinc200; align: `center];
    [text: "noun 15%";       at: 80+`i$(W-160)*0.925, 316; size: 11; fill: `Zinc200; align: `center];

    HRule[345; W];
    [text: "Build time: ~9s  ·  Written in Zig 0.16";
     at: cx, 375; size: 14; fill: `Zinc500; align: `center]
  )
};

/ ── Slide 3: Verb quick reference ───────────────────────────────────────────
drawSlide3: {[W;H]
  c1: 80;
  c2: W%2+20;
  (
    BG[W;H];
    Title["Verb Quick Reference"; 52; 28; `Zinc100; W];
    HRule[70; W];

    [text: "Monadic"; at: c1, 100; size: 15; fill: `Blue400];
    [text: "+x  flip / transpose";   at: c1, 128; size: 13; fill: `Zinc300];
    [text: "-n  negate";             at: c1, 148; size: 13; fill: `Zinc300];
    [text: "*x  first";              at: c1, 168; size: 13; fill: `Zinc300];
    [text: "!i  iota  / !d  keys";   at: c1, 188; size: 13; fill: `Zinc300];
    [text: "&x  where";              at: c1, 208; size: 13; fill: `Zinc300];
    [text: "|x  reverse";            at: c1, 228; size: 13; fill: `Zinc300];
    [text: "<x sort asc  >x desc";   at: c1, 248; size: 13; fill: `Zinc300];
    [text: "=x  group";              at: c1, 268; size: 13; fill: `Zinc300];
    [text: "#x  tally";              at: c1, 288; size: 13; fill: `Zinc300];
    [text: "$x  format";             at: c1, 308; size: 13; fill: `Zinc300];
    [text: "^x  nulls";              at: c1, 328; size: 13; fill: `Zinc300];
    [text: "~x  not";                at: c1, 348; size: 13; fill: `Zinc300];
    [text: ",x  enlist";             at: c1, 368; size: 13; fill: `Zinc300];

    [text: "Dyadic"; at: c2, 100; size: 15; fill: `Emerald400];
    [text: "x+y  add   x-y  sub";   at: c2, 128; size: 13; fill: `Zinc300];
    [text: "x*y  mul   x%y  div";   at: c2, 148; size: 13; fill: `Zinc300];
    [text: "x&y  min   x|y  max";   at: c2, 168; size: 13; fill: `Zinc300];
    [text: "x=y  eq    x<y  lt";    at: c2, 188; size: 13; fill: `Zinc300];
    [text: "x#y  take  x_y  drop";  at: c2, 208; size: 13; fill: `Zinc300];
    [text: "x@y  pick  x?y  find";  at: c2, 228; size: 13; fill: `Zinc300];
    [text: "x,y  concat";           at: c2, 248; size: 13; fill: `Zinc300];
    [text: "x^y  fill / without";   at: c2, 268; size: 13; fill: `Zinc300];
    [text: "x$y  cast";             at: c2, 288; size: 13; fill: `Zinc300];

    HRule[310; W];
    [text: "Adverbs"; at: c2, 330; size: 15; fill: `Violet400];
    [text: "f'x   each (map)";         at: c2, 355; size: 13; fill: `Zinc300];
    [text: "f/x   fold (reduce)";       at: c2, 375; size: 13; fill: `Zinc300];
    [text: "f\\x   scan (prefix scan)"; at: c2, 395; size: 13; fill: `Zinc300];
    [text: "f/[n;x]  iterate n times";  at: c2, 415; size: 13; fill: `Zinc300]
  )
};

/ ── Slide 4: Performance chart ──────────────────────────────────────────────
drawSlide4: {[W;H]
  n:    #benchNames;
  padL: 120;
  padR: 40;
  padT: 80;
  padB: 50;
  cw:   (W - padL) - padR;
  ch:   (H - padT) - padB;
  rowH: `i$ch % n;
  barH: `i$rowH * 0.35;
  maxT: (|/benchInk) | |/benchNgnk;
  scaleW: {[v] `i$(v % maxT) * cw};
  posY:   {[i] padT + i*rowH};

  gridlines: {[i]
    gx: padL + `i$(i%4)*cw;
    (`path; [move: gx, padT]; [line: gx, H-padB]; [stroke: `Zinc800; width: 1]; `stroke)
  }'!5;

  rows: {[i]
    y:   posY[i];
    bw1: scaleW[benchInk[i]];
    bw2: scaleW[benchNgnk[i]];
    (
      [text: benchNames[i]; at: padL-8, y+barH+1; size: 11; fill: `Zinc400; align: `right];
      Bar[padL; y;           bw1; barH; `Blue500];
      [text: ($ benchInk[i])," ms"; at: padL+bw1+4, y+barH-1; size: 9; fill: `Blue300];
      Bar[padL; y+barH+3;    bw2; barH; `Emerald500];
      [text: ($ benchNgnk[i])," ms"; at: padL+bw2+4, y+barH+2; size: 9; fill: `Emerald300]
    )
  }'!n;

  yaxis: (`path; [move: padL, padT]; [line: padL, H-padB]; [stroke: `Zinc600; width: 1]; `stroke);

  (
    BG[W;H];
    Title["Performance vs ngn/k"; 52; 28; `Zinc100; W];
    HRule[68; W];
    [rrect: padL-5, padT-5, cw+10, ch+10, 4; fill: `Zinc900];
    gridlines;
    rows;
    yaxis;
    [text: "ms per iteration (N=10M, 20 reps)";
     at: W%2, H-padB+30; size: 12; fill: `Zinc500; align: `center];
    [rect: padL+10, padT+5, 10, 10; fill: `Blue500];
    [text: "ink";  at: padL+26, padT+14; size: 11; fill: `Zinc300];
    [rect: padL+55, padT+5, 10, 10; fill: `Emerald500];
    [text: "ngnk"; at: padL+71, padT+14; size: 11; fill: `Zinc300]
  )
};

/ ── Slide 5: Drawing API ────────────────────────────────────────────────────
drawSlide5: {[W;H]
  cx: W%2;
  (
    BG[W;H];
    Title["Vector Drawing API"; 52; 28; `Zinc100; W];
    HRule[70; W];

    [text: "window 9: (list of draw commands)"; at: cx, 105; size: 15; fill: `Zinc400; align: `center];

    [rect:    80,  140, 120, 80; fill: `Blue600];
    [text: "rect";    at: 140, 240; size: 12; fill: `Zinc500; align: `center];

    [rrect:   230, 140, 120, 80, 14; fill: `Emerald600];
    [text: "rrect";   at: 290, 240; size: 12; fill: `Zinc500; align: `center];

    [circle:  435, 180, 40; fill: `Violet500];
    [text: "circle";  at: 435, 240; size: 12; fill: `Zinc500; align: `center];

    [ellipse: 570, 180, 60, 36; fill: `Amber400];
    [text: "ellipse"; at: 570, 240; size: 12; fill: `Zinc500; align: `center];

    [rrect: 80, 265, W-160, 45, 8;
     fill: [linear: (80.0, 265.0, (0.0+W-80), 265.0; `Sky400; `Violet700)]];
    [text: "linear gradient"; at: cx, 293; size: 13; fill: `Zinc100; align: `center];

    `path;
    [move: 80, 340];
    [bezier: 200,310, 350,380, cx,340];
    [bezier: cx+150,300, W-200,370, W-80,340];
    [stroke: `Emerald400; width: 3];
    `stroke;
    [text: "bezier path"; at: cx, 370; size: 12; fill: `Zinc500; align: `center];

    [rrect: 80, 390, W-160, 90, 8; fill: `Zinc900];
    [text: "window 9: ("; at: 110, 415; size: 13; fill: `Zinc400];
    [text: "  [rect: 10,20,100,50; fill: `Blue600];"; at: 110, 435; size: 13; fill: `Emerald300];
    [text: "  [text: \"hi\"; at: 60,75; size: 18; fill: `Zinc100; align: `center]"; at: 110, 455; size: 13; fill: `Emerald300];
    [text: ")"; at: 110, 470; size: 13; fill: `Zinc400]
  )
};

/ ── Slide 6: exec verb ──────────────────────────────────────────────────────
drawSlide6: {[W;H]
  cx: W%2;
  (
    BG[W;H];
    Title["Shell Exec Verb"; 52; 28; `Zinc100; W];
    HRule[70; W];

    [text: "Execute shell commands — stdout captured as a char vector";
     at: cx, 105; size: 15; fill: `Zinc400; align: `center];

    [rrect: 80, 125, W-160, 315, 8; fill: `Zinc900];

    [text: "/ monadic — run shell string"; at: 110, 155; size: 13; fill: `Zinc500];
    [text: "exec \"echo hello\"";           at: 110, 178; size: 18; fill: `Emerald300];
    [text: "\"hello\\n\"";                  at: 110, 200; size: 16; fill: `Blue300];

    [text: "/ argv list — no shell expansion"; at: 110, 230; size: 13; fill: `Zinc500];
    [text: "exec (\"/bin/echo\"; \"hello\")";  at: 110, 253; size: 18; fill: `Emerald300];
    [text: "\"hello\\n\"";                      at: 110, 275; size: 16; fill: `Blue300];

    [text: "/ dyadic — pipe stdin into command"; at: 110, 305; size: 13; fill: `Zinc500];
    [text: "\"a\\nbc\\nd\\n\" exec \"wc -l\"";  at: 110, 328; size: 18; fill: `Emerald300];
    [text: "\"3\\n\"";                            at: 110, 350; size: 16; fill: `Blue300];

    [text: "/ symbol dispatch form";  at: 110, 380; size: 13; fill: `Zinc500];
    [text: "`x \"uptime\"";            at: 110, 403; size: 18; fill: `Emerald300];
    [text: "\" 9:00  up 3 days ...\""; at: 110, 424; size: 16; fill: `Blue300];

    HRule[455; W];

    [text: "exec c  →  sh -c c      exec (argv)  →  execvp(argv[0], ...)";
     at: cx, 475; size: 13; fill: `Zinc500; align: `center];
    [text: "stdin exec c  →  pipe stdin, capture stdout";
     at: cx, 495; size: 13; fill: `Zinc500; align: `center]
  )
};

/ ── Slide dispatch ──────────────────────────────────────────────────────────
drawSlide: {[s;W;H]
  $[s=0; drawSlide0[W;H];
    s=1; drawSlide1[W;H];
    s=2; drawSlide2[W;H];
    s=3; drawSlide3[W;H];
    s=4; drawSlide4[W;H];
    s=5; drawSlide5[W;H];
    s=6; drawSlide6[W;H];
    BG[W;H]]
};

NavDot: {[i;cx;y;cur]
  [circle: cx + i*20, y, 5; fill: $[i=cur; `Blue400; `Zinc700]]
};

/ ── Event loop ──────────────────────────────────────────────────────────────
loop: {[window; props; events]
  W:: props`width;
  H:: props`height;

  {[ev]
    $[ev`type = `keydown;
      {k: ev`key;
       $[k=263; slide:: 0|(slide-1);
         k=262; slide:: (nSlides-1)&(slide+1);
         k=32;  slide:: (nSlides-1)&(slide+1);
         0]};
      0]
  }'events;

  window 9: (
    `animate;
    drawSlide[slide; W; H];
    {[i] NavDot[i; W%2 - (nSlides-1)*10, H-18, slide]}'!nSlides
  )
}
