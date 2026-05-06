/ demo/line_chart.k — Multi-series line chart with area fill

n: 24

v1: ?n; s1: 0.5 + +\(v1-0.5)*0.15
v2: ?n; s2: 0.5 + +\(v2-0.5)*0.15

Area: {[pts; x0; xn; yb; clr]
  (`path;
   [move: x0, yb];
   [line: pts];
   [line: xn, yb];
   `close;
   [fill: clr];
   `fill)
};

Line: {[pts; clr; w]
  (`path;
   [move: pts[0]];
   [line: pts[1+!((-1)+#pts)]];
   [stroke: clr; width: w];
   `stroke)
};

Dots: {[ptx; pty; r; clr]
  {[i] [circle: ptx[i], pty[i], r; fill: clr]}'!#ptx
};

Label: {[x;y;clr;txt]
  ([circle: x, y, 5; fill: clr];
   [text: txt; at: (x+9), (y+4); size: 12; fill: `Zinc300])
};

XAxis: {[x0;x1;y]
  (`path; [move: x0, y]; [line: x1, y]; [stroke: `Zinc600; width: 1]; `stroke)
};

YAxis: {[x;y0;y1]
  (`path; [move: x, y0]; [line: x, y1]; [stroke: `Zinc600; width: 1]; `stroke)
};

loop: {[window; props; events]
  W:: props`width;
  H:: props`height;
  pad:: 55;
  ch:: (H-pad) - pad;
  cw:: (W-pad) - pad;

  lo:: 0.0 & (&/s1) & &/s2;
  hi:: 1.0 | (|/s1) | |/s2;
  rng:: hi - lo;

  scx:: {[i] pad + (i*cw) % (n-1)};
  scy:: {[v] (H-pad) - `i$((v-lo) % (rng|0.001)) * ch};

  ptx:: scx'!n;
  pty1:: scy's1;
  pty2:: scy's2;
  pt1: {[i] ptx[i], pty1[i]}'!n;
  pt2: {[i] ptx[i], pty2[i]}'!n;

  x0:: scx[0]; xn:: scx[n-1]; yb:: H-pad;

  / Horizontal grid lines
  grid: {[i]
    gy: (H-pad) - (i * (ch%4));
    (`path;
     [move: pad, gy];
     [line: (W-pad), gy];
     [stroke: `Zinc800; width: 1];
     `stroke)
  }'!5;

  window 9: (
    `animate;
    [rect: 0, 0, W, H; fill: `Zinc950];
    [rrect: (pad-5), (pad-5), (cw+10), (ch+10), 4; fill: `Zinc900];
    grid;
    Area[pt1; x0; xn; yb; 37 99 235 35];
    Area[pt2; x0; xn; yb; 16 185 129 35];
    Line[pt1; `Blue400; 2.5];
    Line[pt2; `Emerald400; 2.5];
    Dots[ptx; pty1; 3; `Blue200];
    Dots[ptx; pty2; 3; `Emerald200];
    [rrect: (W-130), 35, 110, 52, 6; fill: `Zinc800];
    Label[W-115; 53; `Blue400;    "Series A"];
    Label[W-115; 73; `Emerald400; "Series B"];
    XAxis[pad; W-pad; H-pad];
    YAxis[pad; pad; H-pad];
    [text: "Random Walk"; at: W%2, 28; size: 16; fill: `Zinc200; align: `center]
  )
}
