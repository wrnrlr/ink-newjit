/ lib/feat.k — audio samples → log-mel features.
/ STFT power via one kernel (framing folded in), mel projection = a Linear, then log.
/ Design notes: doc/design/nn.md
/
/ The Hann window / DFT basis / mel filterbank are precomputed host-side here; in a
/ real pipeline you would ship the mel matrix from the offline export (librosa/NeMo).
/
/ Everything under feat.nemo.* exists to match NeMo's
/ AudioToMelSpectrogramPreprocessor bit-for-bit.  Those constants and off-by-ones are
/ where the silent corruption bugs lived — see doc/design/nn.md §5.

\e logmel

feat.pi:: 3.14159265358979

/ frames produced from n samples given window/hop ("valid" framing).
feat.frames: {[n;win;hop] 1 + (n - win) div hop}

/ ── NeMo AudioToMelSpectrogramPreprocessor compatibility ─────────────────────
/ NeMo calls torch.stft(center=True, pad_mode="constant"), which ZERO-pads the signal
/ by nfft÷2 and centres the win-length window inside the nfft-long frame (offset
/ (nfft−win)÷2).  A pure time shift only rotates the DFT phase and we keep |X|², so
/ instead of widening the STFT kernel to nfft we zero-pad by exactly
/ (nfft÷2)−((nfft−win)÷2) and keep the cheap win-point transform.  Frame count then
/ matches torch: floor((n + 2·(nfft÷2) − nfft) / hop) + 1 = n÷hop + 1.  NB NeMo's own
/ get_seq_len is ONE LESS than that — see feat.nemo.valid.
feat.nemo.preemph:: 0.97                       / FilterbankFeatures preemph default
feat.nemo.guard::   5.9604644775390625e-8      / log_zero_guard_value = 2⁻²⁴
feat.nemo.normEps:: 0.00001                    / normalize_batch CONSTANT, added to the STD

/ feat.nemo.frames = frames the STFT physically produces (torch.stft center=True).
/ feat.nemo.valid  = NeMo get_seq_len, which is ONE LESS — the trailing frame is
/ excluded from the normalization statistics and then zeroed by the pad mask.  Missing
/ that shifts every per-bin mean/std and corrupts the whole spectrogram.
feat.nemo.frames: {[n;hop] 1 + n div hop}
feat.nemo.valid:  {[n;hop] n div hop}
feat.nemo.pad:    {[nfft;win] (nfft div 2) - (nfft - win) div 2}

/ y[0]=x[0];  y[i]=x[i] − a·x[i−1]
feat.preemph: {[sig;a] (1#sig), (1_sig) - a * -1_sig}
/ NeMo calls torch.stft with pad_mode="constant", so this is ZERO padding — NOT
/ the reflect padding torch defaults to.  Pads left by p and out to `tot` samples.
feat.zpad: {[sig;p;tot] (p#0.), sig, (tot - p + #sig)#0.}

/ ── per-feature (per mel bin) normalization over frames — NeMo normalize_batch ──
/ NB torch .std() is UNBIASED (÷ nfr−1) and CONSTANT is added to the std, not the
/ variance; getting either wrong shifts every encoder input.
feat.nmu::(); feat.nsd::()
feat.dev:   {[r] r - feat.nmu}
feat.scale: {[d] d % feat.nsd}
feat.sqr:   {[d] d*d}
/ stats come from the first nv frames only; frames [nv,nfr) are zeroed (pad_value).
feat.norm: {[mel;nfr;nv;nm]
  M:  nv # (nfr;nm)#mel
  feat.nmu:: (+/M) % nv
  dev: feat.dev' M
  feat.nsd:: feat.nemo.normEps + sqrt (+/ feat.sqr' dev) % nv-1
  ,/ (feat.scale' dev), (nfr-nv) # ,nm#0.}

/ ── window / DFT basis / mel filterbank (host-side precompute) ───────────────
/ Hann window of length win.
feat.hann: {[win] 0.5 - 0.5 * cos (2. * feat.pi * `f$!win) % (0. + win - 1)}

/ DFT basis folded with the window → (Cr;Ci), each [nfreq,win] flat, nfreq=nfft÷2+1.
/ Cr[k,t]=cos(2πkt/nfft)·w[t];  Ci[k,t]=−sin(2πkt/nfft)·w[t].
feat.win::0; feat.nfft::0; feat.wnd::()
feat.crRow: {[k] (cos (2. * feat.pi * k * `f$!feat.win) % (0. + feat.nfft)) * feat.wnd}
feat.ciRow: {[k] (0. - sin (2. * feat.pi * k * `f$!feat.win) % (0. + feat.nfft)) * feat.wnd}
feat.dft: {[nfft; win; wnd]
  feat.nfft:: nfft; feat.win:: win; feat.wnd:: wnd
  nfreq: (nfft div 2) + 1
  (,/ feat.crRow' !nfreq; ,/ feat.ciRow' !nfreq)}

/ Triangular mel filterbank → [nmels,nfreq] flat.
feat.hz2mel: {[f] 2595. * (log 1. + f % 700.) % log 10.}
feat.mel2hz: {[m] 700. * (exp (m * log 10.) % 2595.) - 1.}
feat.nfreq::0; feat.bpts::()
feat.melRow: {[m] b: `f$!feat.nfreq; lo:feat.bpts m; mi:feat.bpts m+1; hi:feat.bpts m+2
  0. | ((b-lo)%mi-lo) & (hi-b)%hi-mi}
feat.melfb: {[sr; nfft; nmels; fmin; fmax]
  feat.nfreq:: (nfft div 2) + 1
  mmin: feat.hz2mel fmin; mmax: feat.hz2mel fmax
  mpts: mmin + (mmax - mmin) * (`f$!nmels+2) % (0. + nmels + 1)
  fpts: feat.mel2hz' mpts
  feat.bpts:: (0. + nfft) * fpts % (0. + sr)
  ,/ feat.melRow' !nmels}

/ ── STFT power (resident) ────────────────────────────────────────────────────
/ pw[f,k] = re²+im², re=Σ_t sig[f·hop+t]·Cr[k,t]  (one thread per frame×freq)
feat.stft.kern: gpu.kernel[{[pw;sig;cr;ci;g;e]
  hop:`i$g[0]; win:`i$g[1]; nf:`i$g[2]
  f:e div nf; k:e mod nf
  base: f*hop; kb: k*win
  re: +/{[t] (sig[base+t]) * cr[kb+t]}'!win
  im: +/{[t] (sig[base+t]) * ci[kb+t]}'!win
  set[pw; e; (re*re) + im*im]}; 0; 5]
feat.stft: {[bpw;bsig;bcr;bci;hop;win;nf;nfr]
  g: nn.par[`stft; (hop;win;nf)]
  gpu.dispatch[nn.pipe[`stft; feat.stft.kern; 5]; (bpw;bsig;bcr;bci;g); nfr*nf]
  bpw}

/ ── raw log-mel spectrogram ──────────────────────────────────────────────────
/ feat.spec[sig; Cr; Ci; MelFb; cfg]  cfg=(hop;win;nfreq;nmels;nframes;eps)
/ → [nframes*nmels].  Chain: STFT power → mel projection (Linear, zero bias) → log(·+eps).
feat.spec: {[sig; Cr; Ci; MelFb; cfg]
  hop:cfg 0; win:cfg 1; nf:cfg 2; nm:cfg 3; nfr:cfg 4; eps:cfg 5
  bsig:gpu.buffer[sig]; bcr:gpu.buffer[Cr]; bci:gpu.buffer[Ci]; bmf:gpu.buffer[MelFb]
  bz:gpu.buffer[nm#0.]
  bpw:nn.buf[nfr*nf]
  feat.stft[bpw;bsig;bcr;bci;hop;win;nf;nfr]
  bmel:nn.buf[nfr*nm]
  linear[bmel;bpw;bmf;bz;nfr;nf;nm]
  bout:nn.buf[nfr*nm]
  logeps[bout;bmel;eps;nfr*nm]
  r: (nfr*nm) # gpu.read[bout]
  nn.drop(bsig;bcr;bci;bmf;bz;bpw;bmel;bout)
  r}

/ ── the whole NeMo preprocessor ──────────────────────────────────────────────
/ logmel[sig; Cr; Ci; MelFb; cfg] — cfg = (hop;win;nfft;nfreq;nmels).
/ `sig` is raw f32 audio in [-1,1); returns the per-feature-normalized log-mel
/ [nframes*nmels], i.e. exactly what the encoder wants.
/ Frame count is feat.nemo.frames[#sig;hop].
logmel: {[sig; Cr; Ci; MelFb; cfg]
  hop:cfg 0; win:cfg 1; nfft:cfg 2; nf:cfg 3; nm:cfg 4
  nfr: feat.nemo.frames[#sig; hop]; nv: feat.nemo.valid[#sig; hop]
  xp:  feat.zpad[feat.preemph[sig; feat.nemo.preemph]; feat.nemo.pad[nfft; win]; ((nfr-1)*hop)+win]
  feat.norm[feat.spec[xp; Cr; Ci; MelFb; (hop;win;nf;nm;nfr;feat.nemo.guard)]; nfr; nv; nm]}
