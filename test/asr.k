/ test/asr.k — record speech and transcribe it with Parakeet-TDT, all in ink.
/ Combines test/replay.k (mic + waveform) with test/edit.k (font text rendering)
/ and the lib/nn.k ASR pipeline (LogMel → ConvSubsample → Encoder → TDT → detok).
/
/ Build first:  zig build gpu && zig build audio && zig build font && zig build safetensors
/ Run:          ink test/asr.k
/
/ Keys:  ENTER = start recording / stop+transcribe;  SPACE = play back the clip.
/
/ WEIGHTS: this needs Parakeet exported to f32 safetensors + a vocab.txt (see
/ doc/parakeet-export.py).  With LOADMODEL:0 (default) it records/plays/plots but
/ shows setup instructions instead of a transcript; set LOADMODEL:1 once the files
/ below exist.

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/nn.k"
2: "lib/font.k"
/ audio.* autoloads lib/audio.k on first reference.

/ ── model + featurizer config (verified vs parakeet-tdt-0.6b-v2 model_config.yaml) ─
/ Set LOADMODEL:1 once MODELPATH exists (convert model_weights.ckpt → safetensors,
/ see doc/parakeet-export.py). vocab.txt is already extracted from the .nemo.
LOADMODEL: 0
MDIR:      "data/parakeet-tdt-0.6b-v2/"
MODELPATH: MDIR,"parakeet.safetensors"
VOCABPATH: MDIR,"vocab.txt"
/ encoder
Dm:1024; NLAYERS:24; Hh:8; Dff:4096; KS:9; SUBC:256; EPS:0.00001
/ featurizer (16 kHz)
SR:16000; NFFT:512; WINL:400; HOP:160; NMELS:128; FMIN:0.; FMAX:8000.; MELEPS:0.00001
NFREQ: (NFFT div 2) + 1
/ decoder  (NB pred_rnn_layers:2 — the predictor is a 2-LAYER LSTM; TdtGreedy is
/ currently 1-layer, so the decoder needs extending before real transcription.)
VOCABN:1024; EMBD:640; PREDH:640; JOINTH:640; DUR:0 1 2 3 4; MAXSYM:10

RATE: 16000                        / record at the model's rate (no host resample)

/ ── model load (gated) ───────────────────────────────────────────────────────
HAVE: 0
MODEL:0; ENC:0; SUB:0; DEC:0; VOCAB:0; CRb:0; CIb:0; MELFBb:0
loadModel:{[]
  MODEL:: safetensors.read MODELPATH
  ENC::   nnLoadEncoder[MODEL; NLAYERS]
  SUB::   nnLoadSubsample MODEL
  DEC::   nnLoadDecoder MODEL
  VOCAB:: nnLoadVocab VOCABPATH
  wnd: nnHann WINL
  dft: nnDft[NFFT; WINL; wnd]; CRb:: dft 0; CIb:: dft 1
  MELFBb:: nnMelFb[SR; NFFT; NMELS; FMIN; FMAX]
  HAVE:: 1}
$[LOADMODEL; loadModel[]; 0]

/ ── ASR pipeline (one shot on the recorded buffer) ───────────────────────────
/ per-feature (per mel bin) normalization over frames — NeMo does this pre-encoder.
FNmu::(); FNsd::()
fnDev:  {[r] r - FNmu}
fnNorm: {[d] d % FNsd}
featNorm:{[mel;nfr;nm]
  M: (nfr;nm)#mel
  FNmu:: (+/M) % nfr
  dev: fnDev' M
  FNsd:: sqrt MELEPS + (+/ {x*x}' dev) % nfr
  ,/ fnNorm' dev}
runAsr:{[buf]
  nfr: nnFrames[#buf; WINL; HOP]
  mel: featNorm[LogMel[buf; CRb; CIb; MELFBb; (HOP;WINL;NFREQ;NMELS;nfr;MELEPS)]; nfr; NMELS]
  Tp:  nnSub2 nnSub2 nnSub2 nfr
  sub: ConvSubsample[mel; SUB; (nfr; NMELS; SUBC; Dm)]
  enc: Encoder[sub; ENC; (Tp; Dm; Hh; Dff; KS; EPS)]
  ids: TdtGreedy[enc; DEC; (Tp; Dm; EMBD; PREDH; JOINTH; VOCABN; DUR; MAXSYM)]
  nnDetok[VOCAB; ids]}
transcribe:{[buf]
  $[HAVE & 0<#buf; TEXT:: runAsr buf; 0]}

HELP: "Convert model_weights.ckpt to parakeet.safetensors (doc/parakeet-export.py), then set LOADMODEL:1."
TEXT: $[HAVE; "Press ENTER to record, ENTER again to transcribe."; HELP]

/ ── layout / colours ─────────────────────────────────────────────────────────
pi:3.14159265359
WINW:900.; WINH:560.; MARGIN:22.
ICX:52.; ICY:44.; ICR:22.
BGV:0.10 0.11 0.14
BG:      gpu.solid[0.10;0.11;0.14;1.]
WAVEG:   gpu.solid[0.25;0.68;0.85;1.]
IDLEC:0.72 0.72 0.80; RECC:0.92 0.22 0.22; PLAYC:0.34 0.80 0.46
PEN:     gpu.solid[0.90;0.90;0.84;1.]

/ ── state ────────────────────────────────────────────────────────────────────
ST:`idle; BUF:0#0.; PH:-1; LEVEL:0.
WAVE:0#0.; DIRTY:1; WVW:0.; WVH:0.
PATH:"/tmp/ink-asr.wav"

/ ── shapes ───────────────────────────────────────────────────────────────────
ellipsePts:{[cx;cy;rx;ry;n] t:(2.*pi%(n+0.))*!n; pts:@[(2*n)#0.;2*!n;:;cx+rx*cos t]; @[pts;1+2*!n;:;cy+ry*sin t]}
fillEllipse:{[cx;cy;rx;ry;c] gpu.fill[gpu.tessellate ellipsePts[cx;cy;rx;ry;40]; gpu.solid[c 0;c 1;c 2;1.]]}
quad:{[x;y;w;h] gpu.tessellate (x,y,(x+w),y,(x+w),(y+h),x,(y+h))}
fillRect:{[x;y;w;h;c] gpu.fill[quad[x;y;w;h]; gpu.solid[c 0;c 1;c 2;1.]]}
ring:{[cx;cy;rad;c] fillEllipse[cx;cy;rad;rad;c]; fillEllipse[cx;cy;rad-4.;rad-4.;BGV]}
drawIcon:{[] $[ST=`idle; ring[ICX;ICY;ICR;IDLEC]; ST=`rec; fillEllipse[ICX;ICY;ICR;ICR;RECC]; fillEllipse[ICX;ICY;ICR;ICR;PLAYC]]}

/ ── waveform (from replay.k) ─────────────────────────────────────────────────
peaks:{[buf;ncols] n:#buf; b:1|`i$((n+ncols)-1)%ncols; pad:buf,((ncols*b)-n)#0.; |/'(ncols;b)#abs pad}
barFn:{[x0;colw;cy;sc;pk;c] bh:1.|sc*(pk c); quad[x0+(colw*c);cy-bh;1.|colw*0.8;2.*bh]}
bldWave:{[w;h]
  x0:MARGIN; ww:w-(2.*MARGIN); cy:96.; hh:52.
  ncols:1|`i$700.&ww; pk:peaks[BUF;ncols]; mx:|/pk
  sc:hh*$[mx>0;1.%mx;1.]; colw:ww%ncols
  ,/ barFn[x0;colw;cy;sc;pk;]' !ncols}
waveVerts:{[w;h] $[0=#BUF;0#0.;bldWave[w;h]]}
rebuildWave:{[w;h] WAVE::waveVerts[w;h]; WVW::w; WVH::h; DIRTY::0}
needWave:{[w;h] DIRTY | ~ (w~WVW)&(h~WVH)}

/ ── font text (from edit.k) ──────────────────────────────────────────────────
FONT:*font.read "font/FiraCode-Regular.ttf"
SZ:20.; SCALE:font.scale[FONT;SZ]; AV:(FONT`hmtx)`adv; ADV:SCALE*AV 0
FMET:font.metrics[FONT;SZ]; ASC:FMET 0; LINEH:6.+(FMET 0)-FMET 1
TX0:MARGIN; TY0:170.                                 / transcript origin
contByte:{[out;need;acc;c] a:(acc*64)+c-128; $[need=1;(out,a;0;0);(out;need-1;a)]}
u8step:{[st;c] out:st 0; need:st 1; acc:st 2; $[need>0; contByte[out;need;acc;c]; c<128;(out,c;0;0); c<224;(out;1;c-192);(out;2;c-224)]}
u8:{[s] (u8step/[(!0;0;0);`i$s]) 0}
shift:{[t;ox;oy] t + ((#t)#ox,oy,0.,0.)}
CKEYS:!0; CVALS:()
cacheGlyph:{[gid] cs:font.outline[FONT;gid;SZ]; v:$[0=#cs;0#0.;0.+gpu.tessellate(,/{x,0n,0n}'cs)]; CKEYS,::gid; CVALS,::,v; v}
glyphLocal:{[gid] i:CKEYS?gid; $[i<#CKEYS; CVALS i; cacheGlyph gid]}
RowGids:!0; RowBase:0.
glyphAt:{[i] shift[glyphLocal RowGids i; TX0+ADV*i; RowBase]}
rowVerts:{[cp;r] RowGids::font.shape[FONT;cp]; RowBase::TY0+ASC+LINEH*r; n:#RowGids; $[0=n;0#0.;,/{glyphAt x}' !n]}
/ greedy char-wrap the transcript codepoints into lines that fit the window.
wrapLine:{[cp;n;i] cp@ (i*n) + !n & (#cp)-i*n}
wrap:{[cp;n] $[0=#cp; (,!0); wrapLine[cp;n;]' !1|`i$((#cp)+n-1) div n]}
/ LINES is a global list of per-line codepoint vectors (mapped by index, like
/ edit.k, so the row builder captures no vector — ink lambdas don't close over locals).
LINES: (,!0)
gRow:{[r] rowVerts[LINES r; r]}
bldTextIx:{[] n:#LINES; $[0=n;0#0.; ,/ gRow' !n]}
relayText:{[] LINES:: wrap[u8 TEXT; 1 | `i$ (WINW-2.*MARGIN)%ADV]; GLYPHS:: bldTextIx[]}

GLYPHS:0#0.

/ ── audio actions (each multi-statement op is a named fn — $[…] can't hold [;]) ──
doStopPlay:{[] audio.stop PH; audio.unload PH; PH:: -1}
stopPlayIfAny:{[] $[PH>-1; doStopPlay[]; 0]}
startRec:{[] stopPlayIfAny[]; BUF::0#0.; DIRTY::1; audio.rec.speech[]; ST::`rec}
appendRec:{[s] BUF::BUF,s; DIRTY::1; LEVEL::LEVEL|(|/abs s)}
drainRec:{[] s:audio.rec.read[]; $[0<#s; appendRec s; 0]}
stopRec:{[] drainRec[]; audio.rec.stop[]; DIRTY::1; ST::`idle; transcribe BUF; relayText[]}
beginPlay:{[] stopPlayIfAny[]; audio.save[PATH;1;RATE;BUF]; PH::audio.load PATH; audio.start PH; ST::`play}
startPlay:{[] $[0<#BUF; beginPlay[]; 0]}
endPlay:{[] stopPlayIfAny[]; ST::`idle}
endIfDone:{[e] $[1=e; endPlay[]; 0]}
chkEnd:{[] $[PH<0; 0; endIfDone (audio.state PH)`atEnd]}
onEnter:{[] $[ST=`idle; startRec[]; ST=`rec; stopRec[]; endPlay[]]}
onSpace:{[] $[ST=`idle; startPlay[]; 0]}
onKey:{[code] $[code=257; onEnter[]; code=32; onSpace[]; 0]}

/ ── frame ────────────────────────────────────────────────────────────────────
keyCodes:{[E] (E`code)@&(`key=(E`kind))&(1=(E`down))}
procEvents:{[props] E:props`events; $[0<#E; {onKey x}' keyCodes E; 0]; $[ST=`rec; drainRec[]; 0]}
run:{[props]
  LEVEL::LEVEL*0.85
  procEvents props
  $[ST=`play; chkEnd[]; 0]
  w:props`width; h:props`height
  $[needWave[w;h]; rebuildWave[w;h]; 0]
  $[0=#GLYPHS; relayText[]; 0]                        / lay out the initial help/prompt text
  gpu.fill[quad[0.;0.;w;h]; BG]
  $[0<#WAVE; gpu.fill[WAVE; WAVEG]; 0]
  drawIcon[]
  gpu.fill[GLYPHS; PEN]}
window.run[run; WINW,WINH]
