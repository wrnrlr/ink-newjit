/
# stats

Descriptive statistics: moments, correlation, regression and distributions.

Means, variance and standard deviation, covariance and correlation, linear
regression, and the normal / t distributions — all whole-array, no loops.

## Translating from kyte

```k
kyte `x^y`   (power)     / not available in ink; z95 is stubbed
kyte `^^x`   (sort)      / → ink `x@<x` (grade-up applied)
kyte `n^^x`  (windows)   / → ink `n':x` (sliding-window adverb)
kyte `while[cond;body]`  / → ink `n f/` (N-do adverb)
kyte `(-n)#x`(pad-left)  / → ink `(n#0.),(-n)_x` (explicit float-zero pad)
kyte `_x`    (floor)     / ink has no floor builtin; `x div 1` truncates
```

`%` is always float division in ink; use `div` for the integer form.

Pure k — loads on the first reference to any `stats.*` name.
\

/ Mean of a numeric list.
/ Ex: avg 1 2 3 4 5  ->  3.0
avg: { (+/x)%0.+#x }

/ Sample variance (Bessel's correction: divides by n-1).
/ Ex: var 2. 4. 4. 4. 5. 5. 7. 9.  ->  ~4.57
/ Note: kyte `x*x:(x-avg x)` mutates x in-place before squaring;
/       ink does not support that pattern, so we use an explicit `d`.
var: { d:x-avg x; (+/d*d)%-1+#x }

/ Sample standard deviation (square root of sample variance).
/ Ex: std 2. 4. 4. 4. 5. 5. 7. 9.  ->  ~2.14
std: { sqrt var x }

/ Median (average of two middle elements for even-length lists).
/ Kyte original: `med: **|2^^`  (tacit: sort, window-2, reverse, first, first).
/ Ink rewrite sorts ascending (`x@<x`), then averages the lower and upper
/ middle indices — works for both odd and even lengths.
/ Ex: med 3. 1. 5. 2. 4.  ->  3.0
/ Ex: med 1. 2. 3. 4.     ->  2.5
med: { s: x@<x; n: #s;a:s@((n-1) div 2); b:s@(n div 2); (a+b)%2. }

/ 95% confidence interval half-width using Minkowski p-norm (p=3.2).
/ Kyte original: `z95:{1.97*(((std@_x)^b)+(std imag x)^b)^1%b:3.2}`
/ NOT TRANSLATED: requires complex-number `imag` and power operator `^`,
/ neither of which exists in ink.
/ z95:{[x] `exit@1}

/ Moving average of window size x over series y.
/ Returns a series of the same length; early positions use partial windows.
/ Kyte original used `(-#y)#` for left-zero-padding; ink `#` cycles instead,
/ so we build the shifted cumsum with explicit float-zero padding `(x#0.)`.
/ Ex: mavg[3;1. 3. 5. 7. 9.]  ->  0.333 1.333 3.0 5.0 7.0
mavg: {c:+\y; (c-(x#0.),(-x)_c)%0.+x }

/ Rolling maximum of window size w over series y.
/ Kyte original used `while[x-:1; y:{x|(*x),-1_x}y]`;
/ ink uses N-do `(w-1) f/` — equivalent, no mutable window counter needed.
/ The inner lambda propagates the running max one step right per iteration.
/ Ex: mmax[3;1. 3. 2. 4. 5.]  ->  1.0 3.0 3.0 4.0 5.0
mmax: {[w;y] (w-1) {x|(*x),(-1)_x}/ y }

/ Rolling minimum of window size w over series y.
/ Mirror of mmax using `&` (min) instead of `|` (max).
/ Ex: mmin[3;5. 3. 4. 1. 2.]  ->  5.0 3.0 3.0 1.0 1.0
mmin: {[w;y] (w-1) {x&(*x),(-1)_x}/ y }
