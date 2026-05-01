/ Z-SCORE MEAN REVERSION: Statistical Arbitrage Strategy
/ Var(X) = E[X^2] - (E[X])^2 identity for O(N) rolling std dev

lines: 0: "test/KStrategies/HistDataAPPLE.csv"
prc: 0.0+|{. 1_ (","\ x)[1]}'-1_ 1_ lines
n: #prc

/ O(N) moving average (no lag shift — returns same length as input)
zma: {[w;x] s:0.0,+\x; nn:1+(#x)-w; ((w-1)#0.0),(s[w+!nn]-s[!nn])%w}

/ Return % for z-score mean reversion: go short when z < -threshold
zStrat: {[w;tr;p]
  m: zma[w;p]
  sd: sqrt zma[w;p*p]-m*m
  z: ((p-m)%(sd+1e-5))*(0+m>0)
  s: -1_ 0,0+((-tr)>z)
  r: 0.0,1_-': log p
  c: 0.0,0.0005*1_(1=+':s)
  t: (r*s)-c
  100*(exp +/-1_ t)-1}

/ 1D sweep: windows 1–99, fixed threshold = 2
wins: 1_!100
scores: {[w] zStrat[w;2;prc]}'wins
best: wins[*>scores]
`0 0: "Z-Score best window:"
`0 0: $best
`0 0: "Return (%):"
`0 0: $zStrat[best;2;prc]

/ Equity curve for best window
m: zma[best;prc]
sd: sqrt zma[best;prc*prc]-m*m
z: ((prc-m)%(sd+1e-5))*(0+m>0)
s: -1_ 0,0+((-2)>z)
r: 0.0,1_-': log prc
c: 0.0,0.0005*1_(1=+':s)
t: (r*s)-c
eq: 100.0*exp +\(-1_ t)

loop: {[window; props; events]
  W:: props`width;
  H:: props`height;
  pad:: 55;
  ch:: (H-pad) - pad;
  cw:: (W-pad) - pad;
  ne:: #eq;

  lo:: &/eq;
  hi:: |/eq;
  rng:: hi - lo;

  scx:: {[i] pad + (i*cw) % (ne-1)};
  scy:: {[v] (H-pad) - `i$((v-lo) % (rng|0.001)) * ch};

  ptx:: scx'!ne;
  pty:: scy'eq;
  base:: scy[100.0];
  pts: {[i] ptx[i], pty[i]}'!ne;

  x0:: scx[0]; xn:: scx[ne-1]; yb:: H-pad;

  grid: {[i]
    gy: (H-pad) - (i * (ch%4));
    (`path; [move: pad, gy]; [line: (W-pad), gy]; [stroke: `Zinc800; width: 1]; `stroke)
  }'!5;

  window 9: (
    `animate;
    [rect: 0, 0, W, H; fill: `Zinc950];
    [rrect: (pad-5), (pad-5), (cw+10), (ch+10), 4; fill: `Zinc900];
    grid;
    (`path; [move: pad, base]; [line: (W-pad), base]; [stroke: `Zinc600; width: 1]; `stroke);
    (`path; [move: x0, yb]; [line: pts]; [line: xn, yb]; `close; [fill: 16 185 129 35]; `fill);
    (`path; [move: pts[0]]; [line: pts[1+!(#pts-1)]]; [stroke: `Emerald400; width: 2]; `stroke);
    [text: "Z-Score Mean Reversion — AAPL"; at: W%2, 28; size: 16; fill: `Zinc200; align: `center];
    [text: "Equity Curve (start = 100)"; at: W%2, 48; size: 12; fill: `Zinc400; align: `center]
  )
}
