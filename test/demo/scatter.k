/ demo/scatter.k — Scatter plot with three clusters

n: 50

rnd: {[cx;sp] cx + sp * 0.5 - ?n}

g0x: rnd[0.25; 0.30];  g0y: rnd[0.30; 0.25]
g1x: rnd[0.70; 0.20];  g1y: rnd[0.65; 0.20]
g2x: rnd[0.50; 0.18];  g2y: rnd[0.18; 0.25]

sz0: 3 + `i$3*?n
sz1: 3 + `i$3*?n
sz2: 3 + `i$3*?n

Disk: {[x;y;r;clr;glw]
  (`save;
   / [circle: x, y, (r+3); fill: glw];
   [circle: x, y, r;     fill: clr];
   `restore)
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

  scx:: {[v] pad + `i$v*cw};
  scy:: {[v] (H-pad) - `i$v*ch};

  / Grid lines at 0, .25, .5, .75, 1.0
  grid: {[i]
    gy: (H-pad) - (i * (ch%4));
    gx: pad + (i * (cw%4));
    (`path; [move: pad, gy]; [line: (W-pad), gy]; [stroke: `Zinc800; width: 1]; `stroke;
     `path; [move: gx, pad]; [line: gx, (H-pad)]; [stroke: `Zinc800; width: 1]; `stroke)
  }'!5;

  / Render one cluster
  cl0x:: scx'g0x; cl0y:: scy'g0y;
  cl1x:: scx'g1x; cl1y:: scy'g1y;
  cl2x:: scx'g2x; cl2y:: scy'g2y;

  clr0:: `Violet500; glw0:: 139 92 246 22;
  clr1:: `Amber400;  glw1:: 251 191 36 22;
  clr2:: `Emerald400; glw2:: 52 211 153 22;

  dots0: {[i] Disk[cl0x[i]; cl0y[i]; sz0[i]; clr0; glw0]}'!n;
  dots1: {[i] Disk[cl1x[i]; cl1y[i]; sz1[i]; clr1; glw1]}'!n;
  dots2: {[i] Disk[cl2x[i]; cl2y[i]; sz2[i]; clr2; glw2]}'!n;

  window 9: (
    `animate;
    [rect: 0, 0, W, H; fill: `Zinc950];
    [rrect: (pad-5), (pad-5), (cw+10), (ch+10), 4; fill: `Zinc900];
    grid;
    dots0; dots1; dots2;
    [rrect: (W-135), 35, 120, 72, 6; fill: `Zinc800];
    Label[W-120; 53; `Violet500; "Cluster A"];
    Label[W-120; 73; `Amber400;  "Cluster B"];
    Label[W-120; 93; `Emerald400; "Cluster C"];
    XAxis[pad; W-pad; H-pad];
    YAxis[pad; pad; H-pad];
    [text: "Cluster Scatter"; at: W%2, 28; size: 16; fill: `Zinc200; align: `center]
  )
}
