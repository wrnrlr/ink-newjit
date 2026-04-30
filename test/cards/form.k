path: (0 0; 100 0; 100 100; 0 0)
fill Red100 stroke Stone700

style: `fill`stroke!0xff0000 0x

9: ink (`fill`stroke!0xff0000 0x00ff00) `quad!(0 0; 100 0; 100 100; 0 0)

PaintCircle: {[c; r]

}

LinePlot: {}

Graph@ (1 3; 1 2; 2 4; 4 5; 5 1)

Graphics@ ((Orange; Disk 0 0); Opacity .7; Pink; Disk)

// N
SplitLayout: {[ratio; view ;left; right]
 leftsize: (ratio+1)/2 * constraints.

 (
}

Disk: {[x;y;r]
  a: x*x; b:y*y; c: r*r; d: a+b<c
  (d<c) | (d=c)
}

Fragment[Disk]

Bitmap[( 0 0 1 ;
         0 1 0 ;
         1 1 0 )]
