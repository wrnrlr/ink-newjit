/ demo/asr.k — record speech and transcribe it with Parakeet-TDT, all in ink.
/ Combines demo/replay.k (mic + waveform) with demo/edit.k (font text rendering)
/ and the lib/nn.k ASR pipeline (LogMel → ConvSubsample → Encoder → TDT → detok).
/
/ Build first:  zig build gpu && zig build audio && zig build font && zig build safetensors
/ Run:          ink demo/asr.k
/
/ Keys:  ENTER = start recording / stop+transcribe;  SPACE = play back the clip.
/
/ WEIGHTS: this needs Parakeet exported to f32 safetensors + a vocab.txt (see
/ doc/parakeet-export.py).  If those files are missing the demo still records,
/ plays and plots — it just shows setup instructions instead of a transcript.
/
/ The pipeline is validated token-for-token against NeMo itself by test/asr.k,
/ using oracle dumps from doc/parakeet-oracle.py.
/
/ DRAWING: waveform, status icon, and transcript all render analytically through
/ lib/canvas.k (Slug scene buffer) — cnv.rect/cnv.ellipse for shapes, cnv.text for
/ the transcript. No tessellation, no glyph cache.

2: "lib/dye.k"
2: "lib/canvas.k"
2: "lib/nn.k"
2: "lib/font.k"
/ audio.* autoloads lib/audio.k on first reference.

/ ── model + featurizer config (verified vs parakeet-tdt-0.6b-v2 model_config.yaml) ─
/ The weights load automatically when MODELPATH is present; convert
/ model_weights.ckpt → safetensors with doc/parakeet-export.py.  vocab.txt is
/ already extracted from the .nemo.
MDIR:      "data/parakeet-tdt-0.6b-v2/"
MNAME:     "parakeet.safetensors"
VNAME:     "vocab.txt"
MODELPATH: MDIR,MNAME
VOCABPATH: MDIR,VNAME
/ encoder
Dm:1024; NLAYERS:24; Hh:8; Dff:4096; KS:9; SUBC:256; EPS:0.00001
/ featurizer (16 kHz) — window + mel filterbank come from the export (feat.*), so
/ they are NeMo's own tables rather than a re-derivation.
NFFT:512; WINL:400; HOP:160; NMELS:128
NFREQ: (NFFT div 2) + 1
/ decoder — pred_rnn_layers:2, so TdtGreedy runs a 2-layer LSTM predictor.
VOCABN:1024; EMBD:640; PREDH:640; JOINTH:640; DUR:0 1 2 3 4; MAXSYM:10

RATE: 16000                        / record at the model's rate (no host resample)
MINSAMP: 4000                      / <0.25 s of audio can't fill the 8× subsample

/ ── model load ───────────────────────────────────────────────────────────────
HAVE: 0
MODEL:0; ENC:0; SUB:0; DEC:0; VOCAB:0; CRb:0; CIb:0; MELFBb:0
/ `dir joins with its own "/", so MDIR's trailing slash makes entries "dir//name" —
/ match on the final path segment rather than the whole path.
WANT:: ""
tailEq: {[e] k:#WANT; $[(#e)<k; 0; WANT ~ (0-k)#e]}
haveFile:{[nm] WANT:: "/",nm; 0 < +/ tailEq' `dir MDIR}
loadModel:{[]
  MODEL:: safetensors.read MODELPATH
  ENC::   nnLoadEncoder[MODEL; NLAYERS]
  SUB::   nnLoadSubsample MODEL
  DEC::   nnLoadDecoder MODEL
  VOCAB:: nnLoadVocab VOCABPATH
  dft: nnDft[NFFT; WINL; (MODEL[`feat.window])`data]
  CRb:: dft 0; CIb:: dft 1
  MELFBb:: (MODEL[`feat.fb])`data
  HAVE:: 1}
$[haveFile[MNAME] & haveFile[VNAME]; loadModel[]; 0]

/ ── ASR pipeline (one shot on the recorded buffer) ───────────────────────────
/ nnFeatures is the whole NeMo preprocessor (preemphasis → zero-padded STFT power
/ → mel → log → per-feature normalize); test/asr.k pins it to the real thing.
/ The encoder weights are uploaded ONCE and kept on the device: that upload is ~300 ms,
/ i.e. most of a short utterance's encode time, and there is no GPU context to upload
/ into until window.run is live — so it happens on the first transcription, not at load.
/ The decoder weights are likewise transposed to column-major once, not per utterance.
/ nnPrepDec ignores cfg[0] (the frame count), so a placeholder 0 is fine here.
DCFG: (0; Dm; EMBD; PREDH; JOINTH; VOCABN; DUR; MAXSYM)
ENCB:0; DECP:0; ENCBOK:0
holdEnc:{[] ENCB:: nnHoldWs ENC; DECP:: nnPrepDec[DEC; DCFG]; ENCBOK:: 1}
ensureEnc:{[] $[ENCBOK=0; holdEnc[]; 0]}
runAsr:{[buf]
  ensureEnc[]
  nfr: nnFramesC[#buf; HOP]
  mel: nnFeatures[buf; CRb; CIb; MELFBb; (HOP;WINL;NFFT;NFREQ;NMELS)]
  Tp:  nnSub2 nnSub2 nnSub2 nfr
  sub: ConvSubsample[mel; SUB; (nfr; NMELS; SUBC; Dm)]
  enc: EncoderRW[sub; ENCB; (Tp; Dm; Hh; Dff; KS; EPS)]  / weights + activations stay on-device across all NLAYERS blocks
  ids: TdtGreedyP[enc; DECP; (Tp; Dm; EMBD; PREDH; JOINTH; VOCABN; DUR; MAXSYM)]
  nnDetok[VOCAB; ids]}
setText:{[buf] t: runAsr buf; TEXT:: $[0=#t; "(nothing recognised)"; t]}
transcribe:{[buf]
  $[~HAVE; TEXT::HELP; (#buf)<MINSAMP; TEXT::"Too short - hold it a little longer."; setText buf]}

HELP: "No model found. Convert model_weights.ckpt to parakeet.safetensors with doc/parakeet-export.py."
TEXT: $[HAVE; "Press ENTER to record, ENTER again to transcribe."; HELP]

/ ── layout / colours ─────────────────────────────────────────────────────────
pi:3.14159265359
WINW:900.; WINH:560.; MARGIN:22.
ICX:52.; ICY:44.; ICR:22.
BGV:0.10 0.11 0.14
WAVEG:   gpu.solid[0.25;0.68;0.85;1.]
IDLEC:0.72 0.72 0.80; RECC:0.92 0.22 0.22; PLAYC:0.34 0.80 0.46; BUSYC:0.95 0.72 0.25
PEN:     gpu.solid[0.90;0.90;0.84;1.]

/ ── state ────────────────────────────────────────────────────────────────────
ST:`idle; BUF:0#0.; PH:-1; LEVEL:0.; PEND:0
DIRTY:1; WVW:0.; WVH:0.
WVPK:0#0.; WVX0:0.; WVCOLW:0.; WVCY:0.; WVSC:0.; WVN:0
PATH:"/tmp/ink-asr.wav"

/ ── canvas shapes ────────────────────────────────────────────────────────────
solidC:{[c] cnv.rgba[c 0; c 1; c 2; 1.]}
fillEllipse:{[cx;cy;rx;ry;c] cnv.ellipse[cx;cy;rx;ry]; cnv.fill solidC c}
fillRect:{[x;y;w;h;c] cnv.rect[x;y;w;h]; cnv.fill solidC c}
ring:{[cx;cy;rad;c] fillEllipse[cx;cy;rad;rad;c]; fillEllipse[cx;cy;rad-4.;rad-4.;BGV]}
drawIcon:{[] $[ST=`idle; ring[ICX;ICY;ICR;IDLEC]; ST=`rec; fillEllipse[ICX;ICY;ICR;ICR;RECC]; ST=`busy; ring[ICX;ICY;ICR;BUSYC]; fillEllipse[ICX;ICY;ICR;ICR;PLAYC]]}

/ ── waveform (peaks cache + rect emit, from replay.k) ─────────────────────────
peaks:{[buf;ncols] n:#buf; b:1|`i$((n+ncols)-1)%ncols; pad:buf,((ncols*b)-n)#0.; |/'(ncols;b)#abs pad}
bldWave:{[w;h]
  x0:MARGIN; ww:w-(2.*MARGIN); cy:96.; hh:52.
  ncols:1|`i$700.&ww; pk:peaks[BUF;ncols]; mx:|/pk
  sc:hh*$[mx>0;1.%mx;1.]
  WVPK::pk; WVX0::x0; WVCOLW::ww%ncols; WVCY::cy; WVSC::sc; WVN::ncols}
rebuildWave:{[w;h] $[0=#BUF; WVN::0; bldWave[w;h]]; WVW::w; WVH::h; DIRTY::0}
needWave:{[w;h] DIRTY | ~ (w~WVW)&(h~WVH)}
barRect:{[c] bh:1.|WVSC*(WVPK c); cnv.rect[WVX0+(WVCOLW*c); WVCY-bh; 1.|WVCOLW*0.8; 2.*bh]}
fillWave:{[] barRect' !WVN; cnv.fill WAVEG}
drawWave:{[] $[WVN>0; fillWave[]; 0]}

/ ── transcript text (analytic Slug text, from edit.k) ────────────────────────
FONT:*font.read "font/FiraCode-Regular.ttf"
SZ:20.; SCALE:font.scale[FONT;SZ]; AV:(FONT`hmtx)`adv; ADV:SCALE*AV 0
FMET:font.metrics[FONT;SZ]; ASC:FMET 0; LINEH:6.+(FMET 0)-FMET 1
TX0:MARGIN; TY0:170.                                 / transcript origin
contByte:{[out;need;acc;c] a:(acc*64)+c-128; $[need=1;(out,a;0;0);(out;need-1;a)]}
u8step:{[st;c] out:st 0; need:st 1; acc:st 2; $[need>0; contByte[out;need;acc;c]; c<128;(out,c;0;0); c<224;(out;1;c-192);(out;2;c-224)]}
u8:{[s] (u8step/[(!0;0;0);`i$s]) 0}
/ greedy char-wrap the transcript codepoints into lines that fit the window.
wrapLine:{[cp;n;i] cp@ (i*n) + !n & (#cp)-i*n}
wrap:{[cp;n] $[0=#cp; (,!0); wrapLine[cp;n;]' !1|`i$((#cp)+n-1) div n]}
/ LINES is a global list of per-line codepoint vectors (mapped by index, like
/ edit.k, so the row builder captures no vector — ink lambdas don't close over locals).
LINES: (,!0)
relayText:{[] LINES:: wrap[u8 TEXT; 1 | `i$ (WINW-2.*MARGIN)%ADV]}
drawLine:{[r] cnv.moveTo[TX0; (TY0+ASC)+LINEH*r]; cnv.text[FONT; SZ; LINES r; PEN]}
drawText:{[] $[0<#LINES; drawLine' !#LINES; 0]}
relayText[]                                          / lay out the initial help/prompt text

/ ── audio actions (each multi-statement op is a named fn — $[…] can't hold [;]) ──
doStopPlay:{[] audio.stop PH; audio.unload PH; PH:: -1}
stopPlayIfAny:{[] $[PH>-1; doStopPlay[]; 0]}
startRec:{[] stopPlayIfAny[]; BUF::0#0.; DIRTY::1; audio.rec.speech[]; ST::`rec}
appendRec:{[s] BUF::BUF,s; DIRTY::1; LEVEL::LEVEL|(|/abs s)}
drainRec:{[] s:audio.rec.read[]; $[0<#s; appendRec s; 0]}
/ Transcription blocks for a few seconds, so it runs on the NEXT frame — this one
/ just paints the busy state so the window doesn't look hung.
stopRec:{[] drainRec[]; audio.rec.stop[]; DIRTY::1; ST::`busy; PEND::1
  TEXT:: "Transcribing..."; relayText[]}
doPend:{[] PEND::0; transcribe BUF; ST::`idle; relayText[]}
chkPend:{[] $[PEND=1; doPend[]; 0]}
beginPlay:{[] stopPlayIfAny[]; audio.save[PATH;1;RATE;BUF]; PH::audio.load PATH; audio.start PH; ST::`play}
startPlay:{[] $[0<#BUF; beginPlay[]; 0]}
endPlay:{[] stopPlayIfAny[]; ST::`idle}
endIfDone:{[e] $[1=e; endPlay[]; 0]}
chkEnd:{[] $[PH<0; 0; endIfDone (audio.state PH)`atEnd]}
onEnter:{[] $[ST=`idle; startRec[]; ST=`rec; stopRec[]; ST=`busy; 0; endPlay[]]}
onSpace:{[] $[ST=`idle; startPlay[]; 0]}
onKey:{[code] $[code=257; onEnter[]; code=32; onSpace[]; 0]}

/ ── frame ────────────────────────────────────────────────────────────────────
keyCodes:{[E] (E`code)@&(`key=(E`kind))&(1=(E`down))}
procEvents:{[props] E:props`events; $[0<#E; {onKey x}' keyCodes E; 0]; $[ST=`rec; drainRec[]; 0]}
run:{[props]
  LEVEL::LEVEL*0.85
  procEvents props
  chkPend[]                                           / deferred transcription
  $[ST=`play; chkEnd[]; 0]
  w:props`width; h:props`height
  $[needWave[w;h]; rebuildWave[w;h]; 0]
  cnv.new[]
  fillRect[0.; 0.; w; h; BGV]                         / background
  drawWave[]
  drawIcon[]
  drawText[]
  cnv.render[w; h]}
window.run[run; WINW,WINH]
