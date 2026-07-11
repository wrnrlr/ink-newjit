/ test/frontend.k — GPU log-mel featurizer validated vs a CPU reference on a
/ synthetic two-tone signal.  Run headless:  INK_SNAP=0 ink test/frontend.k
/
/ Real use: audio.rec.speech[] (mono 16 kHz) → audio.rec.read[] gives the samples
/ that go straight into LogMel here; the mel matrix would be shipped from the
/ offline model export.

2: "lib/spirv.k"
2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/nn.k"

SR:16000; NFFT:128; WIN:64; HOP:32; NMELS:16; FMIN:0.; FMAX:8000.; EPS:0.000001
NFREQ: (NFFT div 2) + 1
NSAMP: 512
NFRAMES: nnFrames[NSAMP;WIN;HOP]

/ synthetic signal: two sinusoids
PI:3.14159265358979
SIG: (sin (2. * PI * 5. * `f$!NSAMP) % 0.+NSAMP) + 0.5 * sin (2. * PI * 19. * `f$!NSAMP) % 0.+NSAMP

/ host precompute (window, DFT basis, mel filterbank)
WND: nnHann[WIN]
DFT: nnDft[NFFT; WIN; WND]
CR: DFT 0
CI: DFT 1
MELFB: nnMelFb[SR; NFFT; NMELS; FMIN; FMAX]

/ ── CPU reference (top-level helpers read the globals above) ──────────────────
cStftEl:{[f;k] fr: SIG@(f*HOP)+!WIN; re: +/ fr * CR@(k*WIN)+!WIN; im: +/ fr * CI@(k*WIN)+!WIN; (re*re)+im*im}
cPowRow:{[f] cStftEl[f;]' !NFREQ}
cMelEl: {[pw;m] +/ pw * MELFB@(m*NFREQ)+!NFREQ}
cLmRow: {[f] pw: cPowRow f; log EPS + cMelEl[pw;]' !NMELS}
cref:   {[] ,/ cLmRow' !NFRAMES}

demo:{[]
  Rlm: LogMel[SIG; CR; CI; MELFB; (HOP;WIN;NFREQ;NMELS;NFRAMES;EPS)]
  Rc:  cref[]
  `0 0:"nframes="; `0 0:$NFRAMES; `0 0:"  nmels="; `0 0:$NMELS; `0 0:"  nfreq="; `0 0:$NFREQ; `0 0:"\n"
  `0 0:"#gpu="; `0 0:$#Rlm; `0 0:"  #cpu="; `0 0:$#Rc; `0 0:"\n"
  `0 0:"MelFb any-NaN (want 0b)="; `0 0:$~ (|/MELFB) = |/MELFB; `0 0:"\n"
  `0 0:"log-mel maxerr -> "; `0 0:$(|/abs Rlm-Rc); `0 0:"\n"
  `0 0:"gpu frame0[0..7] -> "; `0 0:$8#Rlm; `0 0:"\n"
  `0 0:"cpu frame0[0..7] -> "; `0 0:$8#Rc;  `0 0:"\n"
  0}
gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
window.run[loop; 0]
