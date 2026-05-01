/ RSI MOMENTUM OSCILLATOR: Boolean-masked gain/loss routing
/ O(N) via prefix-sum MA; go long when RSI < threshold (oversold)

lines: 0: "test/KStrategies/HistDataAPPLE.csv"
prc: 0.0+|{. 1_ (","\ x)[1]}'-1_ 1_ lines
n: #prc

/ O(N) moving average (no lag shift — returns same length as input)
rsima: {[w;x] s:0.0,+\x; nn:1+(#x)-w; ((w-1)#0.0),(s[w+!nn]-s[!nn])%w}

/ Return % for RSI momentum: go long when RSI < threshold (oversold bounce)
rsiStrat: {[w;tr;p]
  d: p--1_ (*p),p
  u: d*(d>0)
  dw: (0.0-d)*(0>d)
  au: rsima[w;u]
  ad: rsima[w;dw]
  rs: au%(ad+10e-4)
  rsi: 100.0-(100.0%(1.0+rs))
  s: -1_ 0,0+((tr>rsi)*((au+ad)>0))
  r: 0.0,1_-': log p
  c: 0.0,0.0005*1_(1=+':s)
  t: (r*s)-c
  100*(exp +/-1_ t)-1}

/ 1D sweep: windows 2–39, fixed oversold threshold = 30
wins: 2_!40
scores: {[w] rsiStrat[w;30;prc]}'wins
best: wins[*>scores]
`0 0: "RSI best window:"
`0 0: $best
`0 0: "Return (%):"
`0 0: $rsiStrat[best;30;prc]

/ Equity curve for best window
d: prc--1_ (*prc),prc
u: d*(d>0)
dw: (0.0-d)*(0>d)
au: rsima[best;u]
ad: rsima[best;dw]
rs: au%(ad+10e-4)
rsi: 100.0-(100.0%(1.0+rs))
s: -1_ 0,0+((30>rsi)*((au+ad)>0))
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
    (`path; [move: x0, yb]; [line: pts]; [line: xn, yb]; `close; [fill: 234 179 8 35]; `fill);
    (`path; [move: pts[0]]; [line: pts[1+!(#pts-1)]]; [stroke: `Yellow400; width: 2]; `stroke);
    [text: "RSI Momentum Oscillator — AAPL"; at: W%2, 28; size: 16; fill: `Zinc200; align: `center];
    [text: "Equity Curve (start = 100)"; at: W%2, 48; size: 12; fill: `Zinc400; align: `center]
  )
}
