/ TREND FOLLOWING: Moving Average Crossover Strategy
/ O(N) vectorized via prefix-sum; 2D parameter sweep

lines: 0: "test/KStrategies/HistDataAPPLE.csv"
prc: 0.0+|{. 1_ (","\ x)[1]}'-1_ 1_ lines
n: #prc

/ Moving avarage with window size w over x elements computed via prefix-sum (pads warmup with 0.0, shifts by 1 day)
ma: {[w;x]
  s: 0.0,+\x;   / prefix sum, shifted by 1 day
  nn: 1+(#x)-w; / window count
  begin: s[w+!nn];
  end: s[!nn]
  ((w-1)#0.0),-1_(s[begin]-s[end])%w
}

/ Return % for (slow=h1, fast=h2) MA crossover on prices p
maStr: {[h1;h2;p]
  sig: (ma[h1;p])>ma[h2;p]
  s: -1_ 0,0+sig
  r: 0.0,1_-': log -1_ p
  c: 0.0,0.0005*1_(1=+':s)
  t: (r*s)-c
  100*(exp +/t)-1}

/ 2D sweep: all (slow,fast) window pairs up to 25
pairs: ,/{[x] x,'1_!x}'1_!25
scores: {[j] maStr[j[0];j[1];prc]}'pairs
best: pairs[*>scores]
h1: best[0]; h2: best[1]
`0 0: "MA Crossover best windows (slow,fast):"
`0 0: $h1,h2
`0 0: "Return (%):"
`0 0: $maStr[h1;h2;prc]

/ Equity curve for best params
sig: (ma[h1;prc])>ma[h2;prc]
s: -1_ 0,0+sig
r: 0.0,1_-': log -1_ prc
c: 0.0,0.0005*1_(1=+':s)
t: (r*s)-c
eq: 100.0*exp +\t

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
    (`path; [move: x0, yb]; [line: pts]; [line: xn, yb]; `close; [fill: 37 99 235 35]; `fill);
    (`path; [move: pts[0]]; [line: pts[1+!(#pts-1)]]; [stroke: `Blue400; width: 2]; `stroke);
    [text: "MA Crossover — AAPL"; at: W%2, 28; size: 16; fill: `Zinc200; align: `center];
    [text: "Equity Curve (start = 100)"; at: W%2, 48; size: 12; fill: `Zinc400; align: `center]
  )
}
