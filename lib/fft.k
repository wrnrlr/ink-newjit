/ Fast Fourier Transform — Cooley-Tukey radix-2 DIT (decimation-in-time).
/
/ Complex vectors are represented as (re;im) — two float arrays of equal length.
/ Complex 2D matrices are (re_mat;im_mat) — two lists of equal-length row vectors.
/
/ Public API:
/   fft[x]        — DFT of complex vector x=(re;im); length must be power of 2
/   ifft[x]       — inverse DFT; recovers x from fft output (within f32 error ~1e-7)
/   rfft[xr;yr]   — FFT of two real signals at once ("two for one" trick)
/   fft2[A]       — 2D DFT of complex matrix A=(re_mat;im_mat)
/
/ kyte→ink translation:
/   kyte `1@theta`  (polar unit complex)   → ink `(cos theta;-sin theta)` via tau
/   kyte `conj x`                           → ink `cconj[x]`
/   kyte `imag[x;y]` (interleave)          → ink `(x;y)` directly (already split)
/   kyte `1a270`    (-i)                    → ink multiply: (re;im)→(im;-re)
/   kyte `n!k`      (k mod n)              → ink `k mod n`
/   kyte `n%:2`     (integer divide by 2)  → ink `n div 2`
/   CRITICAL: all `c@0` used in arithmetic need (c@0) parens — ink is right-to-left,
/             so `x@0+y@0` parses as `x@(0+y@0)`, not `(x@0)+(y@0)`.

tau:6.283185307179586   / 2π — hardcoded (acos/asin not available in ink)

/ ── complex vector operations ─────────────────────────────────────────────────

/ For a complex vector c = (re;im):  c@0 = re array,  c@1 = im array.
/ All (c@0) accesses use explicit parens to defeat right-to-left ambiguity.

cadd:{[x;y]((x@0)+(y@0);(x@1)+(y@1))}
csub:{[x;y]((x@0)-(y@0);(x@1)-(y@1))}
cmul:{[x;y](((x@0)*(y@0))-((x@1)*(y@1));((x@0)*(y@1))+((x@1)*(y@0)))}
cconj:{[x](x@0;-(x@1))}                               / negate imaginary part
cabs:{[x]sqrt(((x@0)*(x@0))+((x@1)*(x@1)))}          / magnitudes → float vector
cscale:{[s;c](s*(c@0);s*(c@1))}                       / scale both parts by scalar s
cindex:{[c;idx]((c@0)@idx;(c@1)@idx)}                / select elements at indices
ccat:{[x;y]((x@0),(y@0);(x@1),(y@1))}                / concatenate two complex vectors

/ Unit twiddle factors exp(-2πi*k/n) for k=0..m-1: (cos(2πk/n); -sin(2πk/n)).
ctwiddle:{[m;n]
  theta:tau*(0.+!m)%0.+n
  (cos theta;-sin theta)
}

/ ── FFT helpers (global — ink lambdas don't close over parent locals) ──────────

/ Radix-2 butterfly: combine even/odd sub-FFTs into full-length FFT.
/ Carries n explicitly because ink lambdas cannot close over parent locals.
fftBfly:{[x;n]
  m:n div 2
  even:2*!m
  E:fft cindex[x;even]
  O:fft cindex[x;1+even]
  R:cmul[ctwiddle[m;n];O]
  ccat[cadd[E;R];csub[E;R]]
}

/ ── public API ────────────────────────────────────────────────────────────────

/ fft[x] — DFT of complex vector x=(re;im). Length must be a power of 2.
/ Ex: fft[(?8;8#0.)]    / FFT of 8 random reals with zero imaginary part
fft:{[x]
  n:#x@0
  $[n=1;x;fftBfly[x;n]]
}

/ ifft[x] — inverse DFT. Uses ifft(x) = conj(fft(conj(x))) / n.
/ Ex: x:(?8;?8); |/cabs csub[x;ifft fft x]   / residual should be < 1e-5
ifft:{[x]
  n:#x@0
  cscale[1.%0.+n;cconj fft cconj x]
}

/ rfft[xr;yr] — FFT of two real signals simultaneously ("two for one" trick).
/ Returns (Xfft;Yfft), each being the FFT of the respective real input.
/ Cost is one complex FFT instead of two.
rfft:{[xr;yr]
  n:#xr
  Z:fft(xr;yr)
  / Conjugate-reversed partner: conj(Z[0], Z[n-1], Z[n-2], ..., Z[1])
  Zf:cconj cindex[Z;(n-!n)mod n]
  Xfft:cscale[.5;cadd[Z;Zf]]
  diff:csub[Z;Zf]
  Yfft:cscale[.5;(diff@1;-(diff@0))]   / multiply by -i: (re;im)→(im;-re)
  (Xfft;Yfft)
}

/ fft2[A] — 2D DFT of complex matrix A=(re_mat;im_mat). Row and column count must be
/ powers of 2. Applies 1D fft to every row, then every column (separable).
/ Ex: n:8; fft2[({?n}'!n;{n#0.}'!n)]
fft2:{[A]
  re:A@0;im:A@1
  / FFT each row; binary each passes (re_row;im_row) to fft per row
  rows:(re){fft(x;y)}'(im)
  re2:{x@0}'rows; im2:{x@1}'rows
  / Transpose, FFT each column, transpose back
  cols:(+re2){fft(x;y)}'(+im2)
  re3:{x@0}'cols; im3:{x@1}'cols
  (+re3;+im3)
}
