/ test/replay.k — a tiny audio recorder / player on the GPU window loop.
/
/ Build first:  zig build gpu && zig build audio
/ Run:          ink test/replay.k
/
/ A little state machine driven by two keys, ENTER and SPACE:
/   idle       ENTER→record   SPACE→play
/   recording  SPACE→pause     ENTER→stop (idle)
/   rec-paused SPACE→resume    ENTER→stop (idle)
/   playing    SPACE→pause     ENTER→stop (idle)
/   play-paused SPACE→resume   ENTER→stop (idle)
/
/ Top-left a status icon shows the mode (empty circle idle, red circle record,
/ pause bars paused, square playing) with a live level meter beside it.  The
/ lower two-thirds plots the recorded waveform, with a vertical playhead line
/ marking where in the clip we are (pinned to the right edge while recording).
/
/ How it works with the audio module (lib/audio.k):
/  * Recording is the polled path — each frame while `rec` we drain the mic ring
/    buffer with audio.rec.read[] and append to BUF.  Pausing just stops the
/    capture device; resuming restarts it and keeps appending to the same BUF.
/  * Playback is fire-and-forget: on SPACE-from-idle we dump BUF to a temp WAV,
/    audio.load it and audio.start it; the engine plays it on its own thread.
/    audio.stop / audio.start pause & resume (miniaudio keeps the cursor), and
/    audio.state gives the play cursor that drives the playhead.

2: "lib/gpu.k"
/ audio.* autoloads lib/audio.k on first reference (compile time).

pi:   3.14159265359
RATE: 48000

/ ── layout ───────────────────────────────────────────────────────────────────
WINW:   900.
WINH:   500.
MARGIN: 28.
ICX: 62.
ICY: 60.
ICR: 30.

/ ── colours ──────────────────────────────────────────────────────────────────
BGV:      0.10 0.11 0.14                 / background (also used to punch the ring)
BG:       gpu.solid[0.10; 0.11; 0.14; 1.]
WAVEG:    gpu.solid[0.25; 0.68; 0.85; 1.]
PHG:      gpu.solid[0.98; 0.82; 0.30; 1.]
IDLEC:    0.72 0.72 0.80
RECC:     0.92 0.22 0.22
PLAYC:    0.34 0.80 0.46
PAUSEC:   0.86 0.80 0.46
METERBGC: 0.18 0.18 0.22
METERFGC: 0.30 0.82 0.55

/ ── state (globals; written from lambdas with ::) ────────────────────────────
ST:    `idle          / `idle `rec `recpause `play `playpause
BUF:   0#0.           / recorded mono f32 samples
PH:    -1             / playback sound handle (-1 = none)
WAVE:  0#0.           / cached waveform vertex buffer
DIRTY: 1              / waveform needs rebuilding
WVW:   0.             / window size the cached waveform was built for
WVH:   0.
LEVEL: 0.             / smoothed level-meter value
PATH:  "/tmp/ink-replay.wav"

/ ── shape helpers (flat vertex buffers → one gpu.fill each) ─────────────────
ellipsePts: {[cx;cy;rx;ry;n]
  t: (2.*pi%(n+0.))*!n
  pts: @[(2*n)#0.; 2*!n; :; cx + rx * cos t]
  @[pts; 1+2*!n; :; cy + ry * sin t]}
fillEllipse: {[cx;cy;rx;ry;c] gpu.fill[gpu.tessellate ellipsePts[cx;cy;rx;ry;48]; gpu.solid[c 0; c 1; c 2; 1.]]}
quad:     {[x;y;w;h] gpu.tessellate (x,y, (x+w),y, (x+w),(y+h), x,(y+h))}
fillRect: {[x;y;w;h;c] gpu.fill[quad[x;y;w;h]; gpu.solid[c 0; c 1; c 2; 1.]]}

/ ── status icon ──────────────────────────────────────────────────────────────
ring: {[cx;cy;rad;c]
  fillEllipse[cx;cy;rad;rad;c]
  fillEllipse[cx; cy; rad-4.; rad-4.; BGV]}      / punch centre with the background
pauseIcon: {[]
  bw: ICR*0.36
  g:  ICR*0.26
  fillRect[ICX-(bw+g); ICY-ICR; bw; 2.*ICR; PAUSEC]
  fillRect[ICX+g;      ICY-ICR; bw; 2.*ICR; PAUSEC]}
drawIcon: {[]
  $[ST=`idle; ring[ICX;ICY;ICR;IDLEC]
    ST=`rec;  fillEllipse[ICX;ICY;ICR;ICR;RECC]
    ST=`play; fillRect[ICX-ICR; ICY-ICR; 2.*ICR; 2.*ICR; PLAYC]
    pauseIcon[]]}                                 / recpause / playpause

/ ── level meter (beside the icon) ────────────────────────────────────────────
drawMeter: {[]
  fillRect[112.; ICY-11.; 240.; 22.; METERBGC]
  lv: 1. & LEVEL*4.
  fillRect[112.; ICY-11.; 1. | 240.*lv; 22.; METERFGC]}

/ ── waveform ─────────────────────────────────────────────────────────────────
/ Peak (max |amplitude|) of each of ncols contiguous buckets of buf.  Fully
/ vectorised: zero-pad to a multiple of ncols, reshape into ncols rows, max-abs
/ each row.  (An inner {[c]…} lambda can't see these locals — ink lambdas don't
/ close over the enclosing scope — so we avoid one here.)
peaks: {[buf;ncols]
  n: #buf
  b: 1 | `i$ ((n+ncols)-1) % ncols                / ceil(n/ncols), >=1
  pad: buf, ((ncols*b)-n)#0.
  |/' (ncols;b)# abs pad}
/ One waveform bar (top-level so it takes its context as args — see the note
/ above; a bar lambda nested in bldWave would read sc/pk/x0/… as undefined).
barFn: {[x0;colw;cy;sc;pk;c] bh: 1. | sc*(pk c); quad[x0+(colw*c); cy-bh; 1. | colw*0.8; 2.*bh]}
bldWave: {[w;h]
  x0: MARGIN
  ww: w - (2.*MARGIN)
  cy: h*0.62
  hh: h*0.26
  ncols: 1 | `i$ 700. & ww
  pk: peaks[BUF; ncols]
  mx: |/pk
  sc: hh * $[mx>0; 1.%mx; 1.]                      / normalise to full height
  colw: ww%ncols
  ,/ barFn[x0;colw;cy;sc;pk;]' !ncols}
waveVerts: {[w;h] $[0=#BUF; 0#0.; bldWave[w;h]]}
rebuildWave: {[w;h] WAVE:: waveVerts[w;h]; WVW:: w; WVH:: h; DIRTY:: 0}
needWave: {[w;h] DIRTY | ~ (w~WVW) & (h~WVH)}

/ ── playhead ─────────────────────────────────────────────────────────────────
pfPlay:  {[] $[PH<0; 0.; frac (audio.state PH)`cursor]}
frac:    {[c] t: #BUF; $[t>0; (c+0.)%t; 0.]}
playFrac:{[]
  $[(ST=`play)|ST=`playpause; pfPlay[]
    (ST=`rec)|ST=`recpause;   1.
    0.]}
playheadV: {[w;h]
  x0: MARGIN
  ww: w - (2.*MARGIN)
  cy: h*0.62
  hh: h*0.28
  px: x0 + (ww*playFrac[])
  quad[px-1.5; cy-hh; 3.; 2.*hh]}

/ ── transitions / actions ────────────────────────────────────────────────────
doStopPlay:    {[] audio.stop PH; audio.unload PH; PH:: -1}
stopPlayIfAny: {[] $[PH>-1; doStopPlay[]; 0]}

startRec: {[] stopPlayIfAny[]; BUF:: 0#0.; DIRTY:: 1; audio.rec.start[]; ST:: `rec}
pauseRec: {[] drainRec[]; audio.rec.stop[]; ST:: `recpause}
contRec:  {[] audio.rec.start[]; ST:: `rec}
stopRec:  {[] drainRec[]; audio.rec.stop[]; DIRTY:: 1; ST:: `idle}

beginPlay: {[] stopPlayIfAny[]; audio.save[PATH; 1; RATE; BUF]; PH:: audio.load PATH; audio.start PH; ST:: `play}
startPlay: {[] $[0<#BUF; beginPlay[]; 0]}
pausePlay: {[] stopPlayIfAny2[]; ST:: `playpause}
stopPlayIfAny2: {[] $[PH>-1; audio.stop PH; 0]}
contPlay:  {[] $[PH>-1; audio.start PH; 0]; ST:: `play}
stopPlay:  {[] stopPlayIfAny[]; ST:: `idle}

onEnter: {[] $[ST=`idle; startRec[]; ST=`rec; stopRec[]; ST=`recpause; stopRec[]; ST=`play; stopPlay[]; ST=`playpause; stopPlay[]; 0]}
onSpace: {[] $[ST=`idle; startPlay[]; ST=`rec; pauseRec[]; ST=`recpause; contRec[]; ST=`play; pausePlay[]; ST=`playpause; contPlay[]; 0]}
onKey:   {[code] $[code=257; onEnter[]; code=32; onSpace[]; 0]}

/ ── recording drain + level ──────────────────────────────────────────────────
appendRec: {[s] BUF:: BUF,s; DIRTY:: 1; LEVEL:: LEVEL | |/ abs s}
drainRec:  {[] s: audio.rec.read[]; $[0<#s; appendRec s; 0]}
sampleLevel: {[] $[PH<0; 0; bumpLevel (audio.state PH)`cursor]}
bumpLevel: {[c] $[(c>-1)&c<#BUF; LEVEL:: LEVEL | abs BUF c; 0]}
chkEnd: {[] $[PH<0; 0; endIfDone (audio.state PH)`atEnd]}
endIfDone: {[e] $[1=e; stopPlay[]; 0]}

/ ── per-frame input ──────────────────────────────────────────────────────────
keyCodes: {[E] (E`code)@&(`key=(E`kind))&(1=(E`down))}
handleKeys: {[E] cs: keyCodes E; {onKey x}' cs}
procEvents: {[props] E: props`events; $[0<#E; handleKeys E; 0]; $[ST=`rec; drainRec[]; 0]}

/ ── frame ────────────────────────────────────────────────────────────────────
run: {[props]
  LEVEL:: LEVEL*0.80                              / meter decays; drain/play re-bump
  procEvents props
  $[ST=`play; sampleLevel[]; 0]
  $[ST=`play; chkEnd[]; 0]
  w: props`width
  h: props`height
  $[needWave[w;h]; rebuildWave[w;h]; 0]
  gpu.fill[quad[0.;0.;w;h]; BG]                  / background
  $[0<#WAVE; gpu.fill[WAVE; WAVEG]; 0]           / waveform (single cached draw)
  $[0<#BUF; gpu.fill[playheadV[w;h]; PHG]; 0]    / playhead
  drawIcon[]
  drawMeter[]}

window.run[run; WINW,WINH]
