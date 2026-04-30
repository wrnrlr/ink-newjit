/ demo/bar_chart.k — Bar chart demo

n: 10
vals: ?n
cats: `Jan`Feb`Mar`Apr`May`Jun`Jul`Aug`Sep`Oct

XAxis: {[x0;x1;y]
  (`path; [move: x0, y]; [line: x1, y]; [stroke: `Zinc600; width: 1]; `stroke)
};

loop: {[window; props; events]
  W:: props`width;
  H:: props`height;
  pad:: 55;
  ch:: (H-pad) - pad;
  cw:: (W-pad) - pad;
  bw:: cw % n;

  / Horizontal grid lines at 0%, 25%, 50%, 75%, 100%
  grid: {[i]
    gy: (H-pad) - (i * (ch%4));
    (`path;
     [move: pad, gy];
     [line: (W-pad), gy];
     [stroke: `Zinc800; width: 1];
     `stroke;
     [text: $i*25; at: (pad-8), (gy+4); size: 11; fill: `Zinc500; align: `right])
  }'!5;

  / Bars
  bars: {[i]
    v: vals[i];
    bh: `i$v * ch;
    bx: 2 + pad + bw*i;
    by: (H-pad) - bh;
    bw4: bw - 4;
    [rrect: bx, by, bw4, bh, 4; fill: `Blue600]
  }'!n;

  / Category labels on x axis
  xlabels: {[i]
    lx: (bw%2) + pad + bw*i;
    [text: $cats[i]; at: lx, ((H-pad)+16); size: 11; fill: `Zinc400; align: `center]
  }'!n;

  window 9: (
    `animate;
    [rect: 0, 0, W, H; fill: `Zinc950];
    [rrect: (pad-5), (pad-5), (cw+10), (ch+10), 4; fill: `Zinc900];
    grid;
    bars;
    XAxis[pad; W-pad; H-pad];
    xlabels;
    [text: "Monthly Revenue"; at: W%2, 28; size: 16; fill: `Zinc200; align: `center]
  )
}
