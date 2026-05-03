/ test/bench/report.k — Benchmark results chart (ink vs ngnk)
/ Run after: make bench-langs
/ Usage:     make bench-report

2:"bench/langs.k"

/ bench/langs.k sets: names, ink_ms, ngnk_ms

Bar: {[x;y;w;h;clr]
  [rect: x, y, w, h; fill: clr]
};

HLine: {[x0;x1;y;clr]
  (`path; [move: x0, y]; [line: x1, y]; [stroke: clr; width: 1]; `stroke)
};

loop: {[window; props; events]
  W:: props`width;
  H:: props`height;

  padL:: 90;
  padR:: 30;
  padT:: 50;
  padB:: 40;

  n:: #names;
  cw:: (W - padL) - padR;
  ch:: (H - padT) - padB;

  rowH:: `i$ch % n;
  barH:: `i$rowH * 0.38;

  maxT:: (|/ink_ms) | |/ngnk_ms;
  safeMax:: maxT | 0.001;

  scaleW:: {[v] `i$(v % safeMax) * cw};

  posY:: {[i] padT + i*rowH};

  / Gridlines at 25%, 50%, 75%, 100% of maxT
  gridX: {[i]
    gx: padL + `i$(i % 4) * cw;
    HLine[gx; gx; padT; `Zinc800];
    HLine[gx; gx; (H-padB); `Zinc800];
    (`path; [move: gx, padT]; [line: gx, (H-padB)]; [stroke: `Zinc800; width: 1]; `stroke)
  }'!5;

  / One benchmark row: name label + two bars
  drawRow: {[i]
    y:   posY[i];
    bw1: scaleW[ink_ms[i]];
    bw2: scaleW[ngnk_ms[i]];
    (
      [text: names[i]; at: (padL-6), (y+barH+1); size: 10; fill: `Zinc400; align: `right];
      Bar[padL; y;           bw1; barH; `Blue500];
      Bar[padL; (y+barH+2); bw2; barH; `Emerald500]
    )
  };

  / Y axis line
  yaxis: (`path; [move: padL, padT]; [line: padL, (H-padB)]; [stroke: `Zinc600; width: 1]; `stroke);

  window 9: (
    `animate;
    [rect: 0, 0, W, H; fill: `Zinc950];
    [rrect: (padL-5), (padT-5), (cw+10), (ch+10), 4; fill: `Zinc900];
    gridX;
    drawRow'!n;
    yaxis;
    [text: "Array Language Benchmarks — ms per iteration (N=1M, 20 reps)";
     at: W%2, 28; size: 14; fill: `Zinc200; align: `center];
    / Legend
    [rect: (padL+10), (H-padB+8), 10, 10; fill: `Blue500];
    [text: "ink";  at: (padL+26), (H-padB+17); size: 11; fill: `Zinc300];
    [rect: (padL+55), (H-padB+8), 10, 10; fill: `Emerald500];
    [text: "ngnk"; at: (padL+71), (H-padB+17); size: 11; fill: `Zinc300]
  )
}
