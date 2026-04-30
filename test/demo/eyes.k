drawEye: {[ex;ey;er;mx;my]
  br: er*0.35;
  ry: er*0.75;

  / Pupil tracking: clamp to eye ellipse boundary
  dx: mx - ex;
  dy: my - ey;
  d: sqrt (dx*dx) + dy*dy;
  d: d | 0.001;
  maxd: (er*ry*d) % sqrt (sqr (ry*dx)) + sqr(er*dy);
  maxd: maxd * 0.7;
  offset: d & maxd;
  px: ex + dx * offset % d;
  py: ey + dy * offset % d;

  (`save;
    [ellipse: ex,ey,er,ry; fill: [linear: (ex, ey-ry, ex, ey+ry; `Neutral50; `Neutral200)]];
    [ellipse: px,py,br,br; fill: [radial: (px,py,br*0.1,br; `Zinc500; `Zinc950)]];
   `restore)
};

loop: {[window;props;events]
  w: props`width;
  h: props`height;
  er: (w&h) % 6;
  mx: props`mx;
  my: props`my;

  window 9: (
    `animate;
    [rect: 0,0,w,h; fill: `Zinc900];
    drawEye[(w%2)-er*1.5; h%2; er; mx; my];
    drawEye[(w%2)+er*1.5; h%2; er; mx; my]
  )
}
