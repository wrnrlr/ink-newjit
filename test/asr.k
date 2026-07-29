/ test/asr.k — validate the ink Parakeet-TDT pipeline against a NeMo oracle.
/ doc/parakeet-oracle.py transcribes each test wav with the real .nemo model and
/ dumps every stage (sig, mel, sub, enc, ids) into <clip>.safetensors; we recompute
/ each stage here and diff.   Run:  make asr-test   (or INK_SNAP=0 ink test/asr.k)
/
/ Needs the exported weights (data/parakeet-tdt-0.6b-v2/parakeet.safetensors).

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/nn.k"
2: "lib/conformer.k"
2: "lib/feat.k"
2: "lib/asr.k"

MDIR:  "data/parakeet-tdt-0.6b-v2/"
MODEL: safetensors.read MDIR,"parakeet.safetensors"
VOCAB: asr.load.vocab MDIR,"vocab.txt"

/ config (mirrors demo/asr.k)
Dm:1024; NLAYERS:24; Hh:8; Dff:4096; KS:9; SUBC:256; EPS:0.00001
NFFT:512; WINL:400; HOP:160; NMELS:128
NFREQ: (NFFT div 2) + 1
VOCABN:1024; EMBD:640; PREDH:640; JOINTH:640; DUR:0 1 2 3 4; MAXSYM:10

/ NeMo's own window + mel filterbank ride along in the export, so the diff isolates
/ the framing/preemph/log/normalize logic rather than re-deriving the tables.
DFT: feat.dft[NFFT; WINL; (MODEL[`feat.window])`data]
CRb: DFT 0; CIb: DFT 1
MELFBb: (MODEL[`feat.fb])`data
SUB: asr.load.subsample MODEL
ENC: asr.load.encoder[MODEL; NLAYERS]
DEC: asr.load.decoder MODEL

/ ── report helper: max abs error, relative to the oracle's own dynamic range ───
FAILN:: 0
bump: {[] FAILN:: FAILN+1}
chk: {[nm;got;want]
  e: |/ abs got-want
  r: e % 1e-9 + |/ abs want
  `0 0: nm; `0 0: "  n="; `0 0: $#got; `0 0: "  maxerr="; `0 0: $e
  `0 0: "  rel="; `0 0: $r
  `0 0: $[r<0.01; "  OK\n"; "  ** MISMATCH **\n"]
  $[r<0.01; 0; bump[]]}
chkEq: {[nm;got;want]
  `0 0: nm; `0 0: $[got~want; "  OK\n"; "  ** MISMATCH **\n"]
  $[got~want; 0; bump[]]}

REF:: 0
rt: {[nm] (REF[`s$nm])`data}

runClip:{[clip]
  REF:: safetensors.read "test/data/asr/",clip,".safetensors"
  SIG:  rt "sig"
  RIDS: `i$ rt "ids"
  nfr:  feat.nemo.frames[#SIG; HOP]
  Tp:   nn.sub2 nn.sub2 nn.sub2 nfr
  `0 0: "\n== "; `0 0: clip; `0 0: "  samples="; `0 0: $#SIG
  `0 0: "  frames="; `0 0: $nfr; `0 0: "  T'="; `0 0: $Tp; `0 0: "\n"

  / stage 1: featurizer (preemph → zero-padded STFT power → mel → log → normalize)
  mel: logmel[SIG; CRb; CIb; MELFBb; (HOP;WINL;NFFT;NFREQ;NMELS)]
  chk["mel      "; mel; rt "mel"]

  / stage 2: conv subsampling (8x)
  sub: subsample.host[mel; SUB; (nfr; NMELS; SUBC; Dm)]
  chk["subsample"; sub; rt "sub"]

  / stage 3: conformer encoder, 24 blocks, weights+activations resident on-device
  enc: conformer[sub; ENC; (Tp; Dm; Hh; Dff; KS; EPS)]
  chk["encoder  "; enc; rt "enc"]

  / stage 4: TDT greedy decode from the ORACLE encoder output, so a decoder bug
  / can't hide behind an encoder bug
  ids: tdt.once[rt "enc"; DEC; (Tp; Dm; EMBD; PREDH; JOINTH; VOCABN; DUR; MAXSYM)]
  chkEq["ids(ref enc)"; ids; RIDS]

  / stage 5: end-to-end, our encoder output into our decoder
  ids2: tdt.once[enc; DEC; (Tp; Dm; EMBD; PREDH; JOINTH; VOCABN; DUR; MAXSYM)]
  chkEq["ids(own enc)"; ids2; RIDS]
  `0 0: "text: "; `0 0: asr.detok[VOCAB; ids2]; `0 0: "\n"
  0}

demo:{[]
  runClip "fox"
  runClip "ink"
  `0 0: "\n"
  `0 0: $[FAILN=0; "ALL PASS\n"; "FAILURES: "]
  $[FAILN=0; 0; `0 0: $FAILN]
  0}
gpu.computeRun[{[x] demo[]}]
