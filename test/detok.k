/ test/detok.k — SentencePiece detokenize (token ids → text).  Pure k.
/   Run:  ink test/detok.k

2: "lib/spirv.k"
2: "lib/gpu.k"
2: "lib/nn.k"

sp: `c$226 150 129                    / ▁ marker
/ synthetic vocab (piece id = index); ▁-prefixed pieces start a word
VOCAB: (sp,"he"; "llo"; sp,"wor"; "ld"; "!"; sp,"hi")

demo:{[]
  `0 0:"ids 0 1 2 3     -> \""; `0 0: nnDetok[VOCAB; 0 1 2 3];   `0 0:"\"  (want hello world)\n"
  `0 0:"ids 0 1 2 3 4   -> \""; `0 0: nnDetok[VOCAB; 0 1 2 3 4]; `0 0:"\"  (want hello world!)\n"
  `0 0:"ids (empty)     -> \""; `0 0: nnDetok[VOCAB; !0];        `0 0:"\"  (want empty)\n"
  / full chain: a TDT decode emitting 5 5 5 (piece 5 = ▁hi) → text
  `0 0:"decode 5 5 5    -> \""; `0 0: nnDetok[VOCAB; 5 5 5];     `0 0:"\"  (want hi hi hi)\n"
  0}
demo[]
