/ demo/step_chart.k — Step (staircase) chart

n: 16

inv: `i$100 * ?n
ord: `i$60  * ?n

LineLabel: {[x;y;clr;txt]
  (`path; [move: x, y]; [line: (x+15), y]; [stroke: clr; width: 2.5]; `stroke;
   [text: txt; at: (x+19), (y+4); size: 12; fill: `Zinc300])
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

  scx:: {[i] pad + (i*cw) % (n-1)};
  scy:: {[v] (H-pad) - (v*ch) % 100};

  / Step line: horizontal then vertical per step, flattened into one I vector
  stLine: {[ser; clr]
    stser:: ser; stclr:: clr;
    x0: scx[0]; y0: scy[ser[0]];
    steps: ,/{[i]
      xi: scx[i+1]; yi: scy[stser[i]]; yi1: scy[stser[i+1]];
      (xi,yi),(xi,yi1)
    }'!(n-1);
    (`path;
     [move: x0, y0];
     [line: steps];
     [stroke: stclr; width: 2.5];
     `stroke)
  };

  stArea: {[ser; clr]
    staser:: ser; staclr:: clr;
    x0: scx[0]; y0: scy[ser[0]]; xn: scx[n-1];
    steps: ,/{[i]
      xi: scx[i+1]; yi: scy[staser[i]]; yi1: scy[staser[i+1]];
      (xi,yi),(xi,yi1)
    }'!(n-1);
    (`path;
     [move: pad, (H-pad)];
     [line: x0, y0];
     [line: steps];
     [line: xn, (H-pad)];
     `close;
     [fill: staclr];
     `fill)
  };

  / Marker dots
  dinv:: inv; dord:: ord;
  dots_inv: {[i] [circle: (scx[i]), (scy[dinv[i]]), 3; fill: `Blue200]}'!n;
  dots_ord: {[i] [circle: (scx[i]), (scy[dord[i]]), 3; fill: `Orange200]}'!n;

  / Horizontal grid lines with y-axis labels
  grid: {[i]
    gy: (H-pad) - (i * (ch%4));
    (`path;
     [move: pad, gy];
     [line: (W-pad), gy];
     [stroke: `Zinc800; width: 1];
     `stroke;
     [text: $i*25; at: (pad-8), (gy+4); size: 11; fill: `Zinc500; align: `right])
  }'!5;

  window 9: (
    `animate;
    [rect: 0, 0, W, H; fill: `Zinc950];
    [rrect: (pad-5), (pad-5), (cw+10), (ch+10), 4; fill: `Zinc900];
    grid;
    stArea[inv; 59 130 246 28];
    stLine[inv; `Blue400];
    dots_inv;
    stArea[ord; 249 115 22 22];
    stLine[ord; `Orange400];
    dots_ord;
    [rrect: (W-135), 35, 120, 52, 6; fill: `Zinc800];
    LineLabel[W-130; 53; `Blue400;   "Inventory"];
    LineLabel[W-130; 73; `Orange400; "Orders"];
    XAxis[pad; W-pad; H-pad];
    YAxis[pad; pad; H-pad];
    [text: "Inventory vs Orders"; at: W%2, 28; size: 16; fill: `Zinc200; align: `center]
  )
}
