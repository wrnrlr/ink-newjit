/ Constraint-based layout — ink interface.
/ Views and constraints are ink values; the Zig solver resolves them.
/
/ A View is a dict with six float variables:
/   `left `top `width `height `right `bottom
/
/ A Constraint is a dict describing a linear relation between two variables:
/   type:     `pin | `eq | `offset | `ratio | `contain
/   rel:      `eq | `leq | `geq
/   strength: Required | Strong | Medium | Weak

/ ── Strengths ─────────────────────────────────────────────────────────────────

Required: 1001001000.0
Strong:   1000000.0
Medium:   1000.0
Weak:     1.0

/ ── View ─────────────────────────────────────────────────────────────────────
/ A view starts with all variables at zero.
/ right = left + width and bottom = top + height are always added by the solver.

View: {[`left`top`width`height`right`bottom ! 6#0.0]}

/ Convenience: solve and read back a frame as [x y w h]
Frame: {x[`left], x[`top], x[`width], x[`height]}

/ ── Constraint helpers ───────────────────────────────────────────────────────

/ Pin a variable to a constant:  var = value
Pin: {[var; val; str]
  [`type`var`val`strength ! (`pin; var; val; str)]
}

/ Equality between two variables:  a = b
Eq: {[a; b; str]
  [`type`a`b`strength ! (`eq; a; b; str)]
}

/ Offset:  a = b + off
Offset: {[a; b; off; str]
  [`type`a`b`off`strength ! (`offset; a; b; off; str)]
}

/ Width ratio:  a.width = ratio * b.width
WidthRatio: {[a; ratio; b; str]
  [`type`a`ratio`b`strength ! (`widthRatio; a; ratio; b; str)]
}

/ Height ratio:  a.height = ratio * b.height
HeightRatio: {[a; ratio; b; str]
  [`type`a`ratio`b`strength ! (`heightRatio; a; ratio; b; str)]
}

/ Containment:  inner sits inside outer with uniform padding
Contain: {[inner; outer; pad; str]
  [`type`inner`outer`pad`strength ! (`contain; inner; outer; pad; str)]
}

/ ── Solver call (delegated to Zig backend via `9:`) ──────────────────────────
/ Layout takes a dict of views and a list of constraints, returns solved views.
/
/ Usage:
/   solved: Layout[views; constraints]
/   frame:  Frame[solved[`root]]

Layout: {[views; constraints]
  [`render`views`constraints ! (`layout; views; constraints)]
}

/ ── Pure-ink fallback: equality-only solver ──────────────────────────────────
/ For when only `pin and `eq constraints are needed, solved via substitution.
/ vars: dict of symbol → float  (variable name → current value)
/ cs:   list of constraint dicts

ApplyPin: {[vars; c]
  vars[c[`var]]: c[`val]
  vars
}

ApplyEq: {[vars; c]
  vars[c[`a]]: vars[c[`b]]
  vars
}

ApplyOffsetC: {[vars; c]
  vars[c[`a]]: vars[c[`b]] + c[`off]
  vars
}

SolveSimple: {[vars; cs]
  {[v; c]
    (c[`type]=`pin):    ApplyPin[v; c]
    (c[`type]=`eq):     ApplyEq[v; c]
    (c[`type]=`offset): ApplyOffsetC[v; c]
    v
  } / cs
}

/ ── Example: sidebar layout ───────────────────────────────────────────────────
/ A 800×600 window split into a 200px sidebar and a main content area.

SidebarLayout: {
  root:    View[]
  sidebar: View[]
  main:    View[]

  views: [`root`sidebar`main ! (root; sidebar; main)]

  cs: (
    / root: fixed 800×600 at the origin
    Pin[`root.left;   0;   Required],
    Pin[`root.top;    0;   Required],
    Pin[`root.width;  800; Required],
    Pin[`root.height; 600; Required],

    / sidebar: left-aligned, 200px wide, full height
    Pin[`sidebar.left;  0;   Strong],
    Pin[`sidebar.top;   0;   Strong],
    Pin[`sidebar.width; 200; Strong],
    Eq[`sidebar.height; `root.height; Required],

    / main: fills the remaining width to the right of the sidebar
    Offset[`main.left;   `sidebar.right; 0; Required],
    Pin[`main.top;       0;              Strong],
    Eq[`main.right;      `root.right;    Required],
    Eq[`main.height;     `root.height;   Required]
  )

  Layout[views; cs]
}

/ ── Example: centered button ─────────────────────────────────────────────────
/ A 120×40 button centered inside an 800×600 panel.

CenteredButton: {
  panel:  View[]
  button: View[]

  views: [`panel`button ! (panel; button)]

  cs: (
    Pin[`panel.left;    0;   Required],
    Pin[`panel.top;     0;   Required],
    Pin[`panel.width;   800; Required],
    Pin[`panel.height;  600; Required],

    Pin[`button.width;  120; Strong],
    Pin[`button.height;  40; Strong],

    / button.left = panel.left + (panel.width - button.width) / 2
    /   ↔  2*button.left - 2*panel.left - panel.width + button.width = 0
    / Expressed as two offset constraints:
    Offset[`button.left;  `panel.left; 340; Medium],   / fallback: (800-120)/2
    Offset[`button.top;   `panel.top;  280; Medium]    / (600-40)/2
  )

  Layout[views; cs]
}

/ ── Drawing helpers ──────────────────────────────────────────────────────────

/ Draw a solved view as a filled rectangle.
/ Usage:  DrawView[gx; solved_views[`sidebar]]
DrawView: {[gx; v]
  r: Frame[v]
  (`rect; r[0]; r[1]; r[2]; r[3]) 9: gx
}

/ Draw all views in a solved layout dict.
DrawLayout: {[gx; solved]
  DrawView[gx]' solved
}
