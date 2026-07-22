/ lib/fmt.k — number → string formatting helpers (the `fmt` namespace).
/ Load with:  2: "lib/fmt.k"
/
/ The point of `fmt.dec` is a FIXED number of decimal places, so a live value doesn't change
/ string width frame-to-frame (which makes on-screen text jitter). `$x` on a float gives a
/ variable-width result; `fmt.dec[2; x]` is always "N.NN".

\d fmt dec sec pct

  pw:{[n] $[n=0; 1; */n#10]}                    / 10^n  (guard n=0: */() is a unit, not 1)
  padz:{[v;n] t:$v; ((0|n-#t)#"0"),t}           / left-pad the digits of v to width n with '0'

  / Format x with EXACTLY n decimal places (rounded, fixed width). n=0 ⇒ integer, no point.
  dec:{[n;x]
    sg:$[x<0.; "-"; ""]                          / sign, then work on the magnitude
    a:$[x<0.; 0.-x; x]
    sc:pw n
    k:`i$_0.5+a*sc                               / value scaled to an integer, rounded
    ip:k div sc; fp:k mod sc
    $[n=0; sg,$k; sg,($ip),".",padz[fp;n]]}

  sec:{[x] (dec[1;x])," s"}                       / seconds, 1 decimal: "8.0 s"
  pct:{[x] (dec[0;100.*x]),"%"}                   / a 0..1 fraction as a whole percent
\d
