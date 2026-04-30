/ demo/vasarely.k — Victor Vasarely inspired grid art

N: 14

mod2: {x - 2*`i$x%2};

loop: {[window; props; events]
  W:: props`width;
  H:: props`height;
  cw:: W % N;
  ch:: H % N;
  nh:: N % 2;

  vi:: 0;
  cells: {[i]
    vi:: i;
    {[j]
      dx: vi - nh; dy: j - nh;
      d: sqrt (dx*dx) + (dy*dy);
      t: 0.0 | 1.0 - d % (nh * sqrt 2.0);
      sz: cw * (0.18 + 0.72*t);
      r: (sz%2) * t;
      cx: (cw * vi) + (cw%2);
      cy: (ch * j) + (ch%2);
      clr: $[mod2[vi+j]; `Zinc900; `Zinc200];
      [rrect: (cx-(sz%2)), (cy-(sz%2)), sz, sz, r; fill: clr]
    }'!N
  }'!N;

  window 9: (
    `animate;
    [rect: 0, 0, W, H; fill: `Zinc500];
    cells
  )
}
