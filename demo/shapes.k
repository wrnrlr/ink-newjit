/ demo/shapes.k — Basic shapes reference

loop: {[window; props; events]
  W: props`width;
  H: props`height;
  cx: W%2;
  wr: W-30;

  window 9: (
    `animate;
    [rect: 0,0,W,H; fill: `Zinc950];

    / ── Filled shapes ────────────────────────────────────────────────
    [text: "Filled"; at: cx,38; size:15; fill:`Zinc400; align:`center];

    [rect:    30,55,110,70; fill:`Blue600];
    [rrect:  160,55,110,70,12; fill:`Emerald600];
    [circle: 340,90,35; fill:`Violet500];
    [ellipse:430,90,55,35; fill:`Amber400];

    [text:"rect";    at:85, 145; size:11; fill:`Zinc500; align:`center];
    [text:"rrect";   at:215,145; size:11; fill:`Zinc500; align:`center];
    [text:"circle";  at:340,145; size:11; fill:`Zinc500; align:`center];
    [text:"ellipse"; at:430,145; size:11; fill:`Zinc500; align:`center];

    / ── Stroked shapes ───────────────────────────────────────────────
    [text: "Stroked"; at: cx,185; size:15; fill:`Zinc400; align:`center];

    [rect:    30,200,110,70; stroke:`Blue400;    width:2];
    [rrect:  160,200,110,70,12; stroke:`Emerald400; width:2];
    [circle: 340,235,35; stroke:`Violet400; width:2];
    [ellipse:430,235,55,35; stroke:`Amber300; width:2];

    / ── Paths ────────────────────────────────────────────────────────
    [text: "Paths"; at: cx,310; size:15; fill:`Zinc400; align:`center];

    `path;
    [move: 30,330]; [line: wr,330];
    [stroke: `Zinc700; width: 1];
    `stroke;

    `path;
    [move: 30,355]; [line: 160,355]; [line: 260,395]; [line: wr,375];
    [stroke: `Sky400; width: 2.5];
    `stroke;

    `path;
    [move: 30,420];
    [bezier: 120,390, 230,460, 330,420];
    [bezier: 400,390, 460,460, wr,420];
    [stroke: `Emerald400; width: 2.5];
    `stroke;

    / ── Gradients ────────────────────────────────────────────────────
    [text: "Gradients"; at: cx,470; size:15; fill:`Zinc400; align:`center];

    [rrect: 30,490,220,60,8;
     fill: [linear: (30.0,490.0,250.0,490.0; `Sky400; `Blue800)]];
    [rrect: 270,490,220,60,8;
     fill: [radial: (380.0,520.0,5.0,80.0; `Amber300; `Orange700)]]
  )
}
