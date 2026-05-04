/ test/bench/report.k — Benchmark results chart (ink vs ngnk)
/ Run after: make bench-langs
/ Usage:     make bench-report

/ Load bench/measure.csv: lang,benchmark,args,time (time in µs per iteration)
lines: 1_ "\n" \ 1:"bench/measure.csv"
lines: lines @ & {0<#x}'lines
rows:  {","\ x}'lines

lang_col:  {*x}'rows
bench_col: {x[1]}'rows
args_col:  `I$ {x[2]}'rows
time_us:   `I$ {x[3]}'rows

/ Build per-language views
ink_i:  & lang_col = "ink"
ngnk_i: & lang_col = "ngnk"

names:   bench_col @ ink_i
N_args:  args_col  @ ink_i
ink_ms:  (0.0 + time_us @ ink_i) % 1000.0
ngnk_ms: :[0 = # ngnk_i; 0.0 * ink_ms; (0.0 + time_us @ ngnk_i) % 1000.0]

/ Throughput: bytes processed per iteration per benchmark
/ gb_s = bytes / (time_us * 1e-6) / 1e9  =  bytes / (time_us * 1000)
bpn: ("baseline";"sum";"max";"scan";"reverse";"sort";"distinct";"group";"dot";"count";"filter";"each";"fusion") ! 4 8 4 8 8 8 4 4 16 4 8 8 8
ink_bytes: (bpn @ names) * N_args
ink_gb_s:  (0.0 + ink_bytes) % (1000.0 * time_us @ ink_i)

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

  / One benchmark row: name label + two bars + GB/s annotation
  drawRow: {[i]
    y:   posY[i];
    bw1: scaleW[ink_ms[i]];
    bw2: scaleW[ngnk_ms[i]];
    gbs: $`i$ ink_gb_s[i];
    (
      [text: names[i]; at: (padL-6), (y+barH+1); size: 10; fill: `Zinc400; align: `right];
      Bar[padL; y;           bw1; barH; `Blue500];
      [text: gbs," GB/s"; at: (padL+bw1+4), (y+barH-1); size: 8; fill: `Blue300];
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
    [text: "Array Language Benchmarks — ms per iteration (N=",$*N_args,", 20 reps)";
     at: W%2, 28; size: 14; fill: `Zinc200; align: `center];
    / Legend
    [rect: (padL+10), (H-padB+8), 10, 10; fill: `Blue500];
    [text: "ink";  at: (padL+26), (H-padB+17); size: 11; fill: `Zinc300];
    [rect: (padL+55), (H-padB+8), 10, 10; fill: `Emerald500];
    [text: "ngnk"; at: (padL+71), (H-padB+17); size: 11; fill: `Zinc300]
  )
}
