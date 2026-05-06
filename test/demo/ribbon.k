/ demo/ribbon.k — Multi-stock ribbon (overlapping area) chart

n: 80

v0: ?n; v1: ?n; v2: ?n; v3: ?n

s0: 1.0 + +\(v0-0.5)*0.04
s1: 1.0 + +\(v1-0.5)*0.04
s2: 1.0 + +\(v2-0.5)*0.04
s3: 1.0 + +\(v3-0.5)*0.04

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

  lo:: (&/s0) & (&/s1) & (&/s2) & &/s3;
  hi:: (|/s0) | (|/s1) | (|/s2) | |/s3;
  rng:: hi - lo;

  scx:: {[i] pad + (i*cw) % (n-1)};
  scy:: {[v] (H-pad) - `i$((v-lo) % (rng|0.001)) * ch};

  ptx:: scx'!n;
  pty0:: scy's0; pty1:: scy's1; pty2:: scy's2; pty3:: scy's3;

  pt0: {[i] ptx[i], pty0[i]}'!n;
  pt1: {[i] ptx[i], pty1[i]}'!n;
  pt2: {[i] ptx[i], pty2[i]}'!n;
  pt3: {[i] ptx[i], pty3[i]}'!n;

  x0:: scx[0]; xn:: scx[n-1]; yb:: H-pad;

  / Horizontal grid lines
  grid: {[i]
    gy: (H-pad) - (i * (ch%4));
    (`path;
     [move: pad, gy];
     [line: (W-pad), gy];
     [stroke: `Zinc800; width: 1]; `stroke)
  }'!5;

  window 9: (
    `animate;
    [rect: 0, 0, W, H; fill: `Zinc950];
    [rrect: (pad-5), (pad-5), (cw+10), (ch+10), 4; fill: `Zinc900];
    grid;
    Area[pt0; x0; xn; yb; 59 130 246 45];
    Area[pt1; x0; xn; yb; 16 185 129 45];
    Area[pt2; x0; xn; yb; 249 115 22 45];
    Area[pt3; x0; xn; yb; 168 85 247 45];
    Line[pt0; `Blue400; 1.5];
    Line[pt1; `Emerald400; 1.5];
    Line[pt2; `Orange400; 1.5];
    Line[pt3; `Violet400; 1.5];
    [rrect: (W-145), 35, 130, 92, 6; fill: `Zinc800];
    Label[W-130; 53;  `Blue400;    "AAPL"];
    Label[W-130; 73;  `Emerald400; "MSFT"];
    Label[W-130; 93;  `Orange400;  "GOOG"];
    Label[W-130; 113; `Violet400;  "AMZN"];
    XAxis[pad; W-pad; H-pad];
    YAxis[pad; pad; H-pad];
    [text: "Stock Prices"; at: W%2, 28; size: 16; fill: `Zinc200; align: `center]
  )
}
