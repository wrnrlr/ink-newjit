# Graphics Operator `9:`

`9:` renders vector graphics using NanoVG. Pass a list of commands monadically.

```k
window 9: (
  [rect: 0 0 W H; fill: `Zinc950];
  [rrect: 20 20 160 80 12; fill: `Blue500; stroke: `Blue200; width: 2];
  [text: "hello"; at: 50 50; size: 18; fill: `White]
)
```

## Animated loop

For interactive or animated output, define a `loop` function and use `` `animate `` as
the first command. The notebook calls `loop` every frame, passing the window handle,
a props dict, and an events list.

```k
loop: {[window; props; events]
  W:: props`width;
  H:: props`height;

  window 9: (
    `animate;
    [rect: 0, 0, W, H; fill: `Zinc950];
    / ... drawing commands ...
  )
}
```

`props` keys: `width`, `height`.

## Command types

### Standalone symbols

| Symbol       | Effect                                    |
|--------------|-------------------------------------------|
| `` `animate ``   | Re-render every frame (animated output)   |
| `` `path ``      | `beginPath()`                             |
| `` `close ``     | `closePath()`                             |
| `` `fill ``      | `fill()`                                  |
| `` `stroke ``    | `stroke()`                                |
| `` `save ``      | `save()` — push graphics state            |
| `` `restore ``   | `restore()` — pop graphics state          |

### Dict commands — path building

| Key          | Args                          | NanoVG call                        |
|--------------|-------------------------------|------------------------------------|
| `move`/`m`   | `x y` or point list           | `moveTo(x, y)` per point           |
| `line`/`l`   | `x y` or point list           | `lineTo(x, y)` per point           |
| `bezier`/`b` | `(c1; c2; end)`               | `bezierTo(c1x c1y c2x c2y x y)`   |
| `quad`/`q`   | `(cp; end)`                   | `quadTo(cpx cpy x y)`              |
| `arc`        | `cx cy r a0 a1`               | `arc(cx cy r a0 a1 .cw)`           |
| `arcto`      | `x1 y1 x2 y2 r`               | `arcTo(x1 y1 x2 y2 r)`             |
| `rect`       | `x y w h`                     | `rect(x y w h)` + auto-path        |
| `rrect`      | `x y w h r`                   | `roundedRect(...)` + auto-path     |
| `circle`     | `cx cy r`                     | `circle(cx cy r)` + auto-path      |
| `ellipse`    | `cx cy rx ry`                 | `ellipse(...)` + auto-path         |

**Auto-path**: dicts containing `rect`, `rrect`, `circle`, or `ellipse` automatically call
`beginPath()` before drawing, and `fill()`/`stroke()` after if those colors are set in the
same dict.

**Point arrays**: `move` and `line` accept a list of `x,y` pairs and emit one NanoVG call
per point. This lets you pass a pre-computed point vector directly:

```k
pts: {[i] (scx[i]), (scy[vals[i]])}'!n

`path; [move: pts[0]]; [line: pts[1+!(n-1)]]; [stroke: `Blue400; width: 2]; `stroke
```

### Dict commands — style

| Key         | Args                            | Effect              |
|-------------|---------------------------------|---------------------|
| `fill`      | color or gradient dict          | Set fill paint      |
| `stroke`    | color or gradient dict          | Set stroke paint    |
| `width`/`w` | number                          | `strokeWidth(n)`    |
| `cap`       | `` `butt `round `square ``      | `lineCap(...)`      |
| `join`      | `` `miter `round `bevel ``      | `lineJoin(...)`     |
| `alpha`     | 0.0–1.0                         | `globalAlpha(n)`    |

### Dict commands — transform

| Key         | Args            | NanoVG call              |
|-------------|-----------------|--------------------------|
| `translate` | `x y`           | `translate(x, y)`        |
| `rotate`    | angle (radians) | `rotate(angle)`          |
| `scale`     | `sx sy` or `s`  | `scale(sx, sy)`          |
| `transform` | `a b c d e f`   | `transform(a b c d e f)` |
| `scissor`   | `x y w h`       | `scissor(x y w h)`       |

### Dict commands — text

```k
[text: "hello"; at: 50 50; size: 18; fill: `White]
[text: "right-aligned"; at: 400 50; size: 14; fill: `Zinc300; align: `right]
[text: "centered"; at: 200 50; size: 14; fill: `Zinc300; align: `center]
```

Keys: `text` (string), `at` (x y), `size` (pt), `fill` (color), `align` (`` `left `center `right ``).

### Meta

```k
[h: 400]   / set widget height (default 300)
```

## Colors

- **Tailwind symbol**: `` `Red400 ``, `` `Blue200 ``, `` `Emerald500 ``, ...
- **Named**: `` `white ``, `` `black ``, `` `transparent ``
- **Integer RGBA**: `255 0 128` or `255 0 128 200` (I-vector, 3 or 4 elements)
- **Float RGBA**: `.1 .5 .9` or `.1 .5 .9 .8` (F-vector, 3 or 4 elements)

## Gradients

Used as the value of `fill:` or `stroke:`:

```k
[fill: [linear: (0 0 200 0; `Blue400; `Violet600)]]
[fill: [radial: (100 100 0 80; `White; `transparent)]]
[fill: [box: (10 10 180 80 8 20; `Amber300; `transparent)]]
```

Gradient args:
- `linear`: `(x0 y0 x1 y1; c0; c1)`
- `radial`: `(cx cy innerR outerR; c0; c1)`
- `box`: `(x y w h cornerR feather; c0; c1)`

## Nested lists

The command list is flattened recursively: any nested list is walked as if its items
appeared inline. This lets helper functions return sub-lists of commands, and lets
`each` results (lists of draw commands) be spliced in directly.

```k
/ helper returns a list of commands
Disk: {[x;y;r;clr;glw]
  (`save;
   [circle: x, y, (r+3); fill: glw];
   [circle: x, y, r;     fill: clr];
   `restore)
};

dots: {[i] Disk[xs[i]; ys[i]; sz[i]; `Violet500; 139 92 246 22]}'!n;

window 9: (
  `animate;
  [rect: 0, 0, W, H; fill: `Zinc950];
  dots   / list of Disk results, spliced in automatically
)
```

## Examples

```k
/ Filled + stroked rounded rect
9: (
  [rrect: 20 20 160 80 12; fill: `Blue500; stroke: `Blue200; width: 2]
)

/ Polyline from computed points
n: 20; vals: ?n
9: (
  [h: 120];
  `path;
  [move: 10, `i$110-vals[0]*100];
  {[i] [line: (10+i*25), `i$110-vals[i]*100]}'1+!n-1;
  [stroke: `Sky400; width: 2]; `stroke
)

/ Area fill under a series
9: (
  `path;
  [move: x0, yb];
  [line: pts];          / pts is a list of x,y pairs
  [line: xn, yb];
  `close;
  [fill: 37 99 235 35];
  `fill
)

/ Bezier path
9: (
  `path;
  [move: 20 80];
  [bezier: (20 20; 160 20; 160 80)];
  `close;
  [fill: `Violet500]; `fill;
  [stroke: `Violet200; width: 2]; `stroke
)

/ Circle with radial gradient
9: (
  [circle: 100 100 80;
   fill: [radial: (100 100 20 80; `White; `Blue600)]]
)

/ Transformed rect
9: (
  `save;
  [translate: 100 100];
  [rotate: .4];
  [rect: -40 -20 80 40; fill: `Amber400];
  `restore
)

/ Text label
9: (
  [h: 80];
  [rect: 0 0 400 80; fill: `Slate700];
  [text: "Hello Terse"; at: 20 50; size: 24; fill: `White]
)

/ Linear gradient background
9: (
  [h: 200];
  [rect: 0 0 400 200;
   fill: [linear: (0 0 0 200; `Indigo950; `Violet800)]]
)
```

## How it works

`9: cmd_list` (monadic, list arg) returns `[render: `gfx; cmds: cmd_list]`.
The notebook cell renderer detects `render: `gfx` and calls `TerseGraphics.layout`,
which walks the command list recursively and calls NanoVG directly.

The dyadic form `data 9: spec` still works for data-driven chart plots.
