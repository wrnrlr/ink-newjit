# Changelog

## 2026-08-04 — The repl is written in ink

`ink` on a terminal now runs `tools/repl.k`. The prompt, the entry reader, the
`\q` / `exit` / EOF handling and the multi-line dict, table and keyed-table grids
are all k; the Zig loop (`runRepl`, ~55 lines of byte-at-a-time line reading) is
gone. `ink repl` starts the same tool explicitly. Session output is byte-identical
to the old loop — `test/repl.k` pins the grids, the trimming and the continuation
rule.

- **`. "1+2"` evaluates source**, as in ngn/k. Monadic `.` on a char vector used
  to parse a *number* out of the string (undocumented, unused; `` `i$"12" ``
  is the cast). A failure is an error VALUE, never an abort, so the repl can
  print it: a runtime failure is the usual `!type`, a parse failure interns its
  whole message, `` !"parse_error: UnexpectedToken at 1:7" ``.
- **`` `show x ``** renders a value the way the repl prints it — `$x` for atoms
  and flat vectors, but nested lists may break across lines.
- **Module auto-loading no longer runs on repl input.** Typing `json.parse …`
  at the prompt will not pull in the module; `\l json` or `2:"json"` first.
  Scripts and `\l` are unaffected.
- **`\t:n expr` no longer resets the stack**, so it is safe inside a nested eval
  (`2:` a module, or the repl's `. src`). It used to run through `runFrom`, whose
  `resetStack` cut the caller's values out from under it — the k repl turned that
  latent bug into a panic on the first `\t` typed at the prompt. `runFrom` is now
  `runNested`, which pushes a frame above the caller's stack the way `2:` does.
- **A tool is resolved once**, by `runTool` — `ink <tool>`, `ink repl` and the
  bare-`ink` terminal path share it.
- **`src/cmd/repl.zig` → `src/cmd/eval.zig`, `Repl` → `Eval`.** Nothing outside
  `tools/repl.k` is called "repl" any more: what is left evaluates a source text
  statement by statement, printing as it goes (`stream`, for scripts and piped
  stdin) or collecting (`collect`, for a Jupyter cell). With the interactive
  caller gone, `Result.source`, the byte-offset bookkeeping that built it and
  `emitGapComments` (comment pass-through results the only remaining caller
  skipped) all went with it, along with the now-unreachable `VM.runFrom` — 282
  lines out, 190 back, and the two entry points share one statement splitter and
  one renderer instead of each having their own.

## 2026-08-04 — Null is the identity verb `::`

The `blank` type is gone from `K` and `V`. k's null is now the monadic identity
verb written as a value, `::`, exactly as in ngn/k — one fewer type in the value
model, one fewer row in every dispatch table.

- **`V.nil` is `{ .o = Fn.monad(.@":") }`** — an ordinary function value. So
  `@::` is `` `o `` (it used to be `` ` ``), `` $:: `` is `"::"`, `#::` is `1`,
  and the null test is `` x~:: ``. Three places treat it specially: it is falsy,
  it marks an elided argument, and the REPL prints nothing for it (so
  assignments and I/O stay quiet, as before).
- **`::` parses as a noun wherever a statement or value can start** — as a list
  item, a call argument, a `$[]` branch, an operand. `(1;;2)` now prints
  `(1;::;2)` and round-trips. Typing `::` at the prompt used to print `:`, the
  *dyadic* right verb, because it parsed as "return the `:` verb".
- **The global-bind digram still wins after a noun.** `a::1` and `a,::x` are
  assignments. With nothing after it the `::` is the null literal again, so
  `a~::` is a null test and `1,::` a join — a non-assignable left operand
  (`1`, `::`) reads the same way.
- **`K.COUNT` 24 → 23.** The monad table drops 352 B, the sparse dyad rows 94
  slots (~1.3 KB of dispatch tables in total). Raw K value 0 is now unused; the
  other tags keep their numbers so the `VEC_BIT` layout is unchanged, but
  `serCode()` shifts by one — the binary serialization VERSION is bumped to
  0x06 and old blobs will not load.
- **`#` now counts callables**, so `#{x}` and `#::` are both `1` instead of
  `!type`; that restores the old `#null` answer.
- **`test/kkgrp.k`'s last assertion was passing vacuously.** Its inner
  set-builders read `perm`/`goff`/`gcnt`/`idx`, which are the *caller's* locals —
  and lambdas do not capture. Both sides degenerated to the same error value, so
  `~` said `1b`. They are top-level helpers taking explicit arguments now, and
  the check actually runs.

## 2026-08-03 — Round brackets for literals, square brackets for statements

`[…]` was doing two unrelated jobs — dict literal and, after a noun, apply — and
`(…)` was doing statement sequencing that nothing else needed. Swapped them, so
each bracket has one meaning.

- **Dicts, tables and keyed tables move to round brackets.** `(a:1 2 3;b:4 5 6)`,
  `([]a:1 2;b:3 4)`, `([a:1 2]b:3 4)`. A `(` commits to a dict the moment its
  first item reads `key:` (and not `key::`); every remaining item must then be
  `key:value`. That makes both mixed shapes — `(a:1;2)` and `(1;a:2)` — parse
  errors instead of quietly meaning a list of assignments. It also means an
  assignment can no longer be a top-level item of `(…)`; that is now
  `error.AssignInParens`, which points at the progn.
- **`[…]` in noun position is a progn.** `[0;1;2;3]` → `3`. Every statement runs,
  the last one's value is the block's, and it opens no scope — so the names it
  binds are the enclosing function's locals. Multi-statement `$[]` branches work
  directly now; they used to need a helper function. `[` directly after a noun is
  still apply/index, so `f[x;y]` is unchanged.
- **`:x` in statement position is an early return.** From the enclosing lambda,
  in a body, a progn or a `$[]` branch: `{$[x<0;:0;x*2]}`, `{[a] [t:a*2; :t+1]}`,
  and `{:}` returns null. In *value* position — a call argument, a list element —
  `:` keeps its verb reading, so `@[v;`px;:;99.]` still passes the assign verb.
  Outside a lambda there is no frame to unwind and `:x` stays plain identity.
- **The `[[` and `[[]` lexer tokens are gone.** They had to be, or `[[1;2];3]`
  could not parse as a nested progn. Their removal also retires the
  `f[[dict;…];…]` apply-with-dict special case in the parser — that call spells
  as `f[(k:v;…);…]` now, an ordinary argument.
- **There is no empty-dict literal.** `[]` used to be one; write `()!()`, which is
  also what an empty dict prints as. The `` `t@[] `` niladic-call idiom is
  unaffected — `[]` there is an empty progn, i.e. null.
- The printer, the `parse` CST (`progn` and `ret` kinds, plus `utable` children,
  which were never emitted), `lib/syntax.k` highlighting, the tree-sitter grammar
  and its highlight queries all follow. The ~180 literals across `lib/ demo/
  test/ tools/ bench/` were migrated mechanically.

## 2026-07-31 — IPC: caller identity, timers, functions on the wire

The transport worked; the process model didn't. A handler was handed only the
message, so a process could answer *only* whoever it was mid-dispatch for — it
could not park a handle and reply later, which is the one thing a gateway or a
load balancer is built on. Closed that, and the surrounding gaps.

- **Handlers are arity-dispatched: `z.pg:{[h;m] …}` is given the handle the
  message arrived on.** This is what `.z.w` is for in q; ink cannot spell `.z`
  because `.` is a verb, so the caller's identity is simply a second argument. A
  handler can now stash the handle and answer out of band, from a different
  dispatch — `test/ipcgate.k` forwards a query to a backend and routes the answer
  back to the client that asked. The monadic form `z.pg:{[m] …}` is unchanged.
- **The hooks live in a `z` namespace** — q's `.z` minus the dot. They were bare
  globals, which squatted five short names in every program; `ts` in particular
  is a name anyone with timestamps would reach for. They are ordinary globals
  that the compiler mangles to `z.member`, so `z.pg:{…}` and a `pg:{…}` inside a
  `\d z` block are the same definition. Only the *callbacks* moved: the services
  a script calls into (`` `on ``, `` `timer ``, `` `poll ``, …) stay backtick
  symbols, which are already outside the global namespace — and the split keeps
  "I call the runtime" visibly distinct from "the runtime calls me".
- **`z.ps` now means what its name says.** `z.pg` replies with a non-blank
  result; `z.ps` is the async side and never replies, even when it returns one.
- **New hooks:** `z.po:{[h] …}` a peer connected, `z.pc:{[h] …}` a peer went away
  (q's `.z.pc` — previously a connection was dropped silently, so the failure
  handling that all three `doc/architecture/*.q` files hang off had no
  equivalent), `z.ts:{[] …}` timer tick.
- **`` `timer[ms] `` drives `z.ts` from the event loop**; `` `timer[0] `` stops it,
  `` `timer[] `` reads it. `\t` was and stays a *benchmark* (time n runs of an
  expression), which is why the timer is a symbol and not a command. The
  reconnect-with-backoff loop in `service.q`/`gateway.q` is now expressible.
- **Functions travel.** A lambda, projection, derived verb or train serializes as
  its source text and is re-compiled by the receiver, arriving callable —
  `f: rt[{[a;b] a*b}]` then `f[6;7]` → `42` across a socket. Only foreign objects
  (`x`, e.g. GPU handles) are still rejected. The text is compiled, not run, on
  arrival, but any global it names resolves in the *receiver's* scope.
- **Atoms travel.** `h 2: 42` and `` h 2: `sym `` were `!type`: the `2:` dispatch
  table had rows for the vector types but none for the scalars, so the codec —
  which handled atoms all along — was never reached. The reply direction always
  worked, which is what made it hard to spot. Tier-2 `d`/`h` floats and their
  vectors are on the wire now too.
- **Attaching a handler moved to `` `on[h;f] ``** (`` `on[h;] `` detaches,
  `` `on[h] `` reads it back). It used to be `h 2: f`, which is exactly the
  spelling needed to *send* a function. `2:` means "send" for every type now,
  with no row that quietly means something else.
- **New: `` `sleep[ms] ``** (fractional ok, ≤0 a no-op, restarts on EINTR),
  **`` `conns[] ``** open handles, **`` `peer[h] ``** the far end's `"ip:port"`,
  **`` `poll[] ``** one non-blocking pass of the loop, **`` `serve[] ``** run it
  forever.
- **A client can run the event loop.** It used to start only if the script had
  opened a listening port, so a process that just made outbound connections had
  to block on `2: h`. It now starts if there is a port, a timer, *or* a handler
  attached to any connection.
- **No more silent starvation past 64 connections.** The poll set was a fixed
  64-entry buffer with `if (n >= MAX_CONNS) break`, and `HashMap` iteration order
  is not stable — so past 64 handles a *different* arbitrary subset went unpolled
  each pass. It is sized to the live connection count now, and `POLLHUP`/`POLLERR`
  are handled rather than only `POLLIN`.
- **Docs.** `doc/reference.md` had the socket verbs backwards — `<c` OpenFile,
  `<s` OpenSocket, `>n` CloseHandle — since forever; it is `>` to open and `<` to
  close. Added an IPC section covering the whole model, and `\p`, which was
  undocumented. `test/client.k` claimed `-h 0: msg` was an async write "same as
  sync for now"; negative handles were never implemented and the sync/async
  choice belongs to the receiving side, so the comment is gone.
- `test/ipc.sh` now runs a three-tier binary suite (`ipcback` → `ipcgate` →
  `ipccli`, 18 assertions) alongside the existing text-protocol pair.
- On-wire format version 0x04 → 0x05.

## 2026-07-30 (later) — calls: over-application errors, `f . args` applies, 16 parameters

- **Over-application is a `!rank` error instead of a silent truncation.** `{x+y}[1;2;3]`
  returned `3` and `{[a;b]a}[1][2;3]` quietly dropped the `3`; a mis-typed call produced
  a plausible wrong answer rather than failing. Both the interpreted call path
  (`call.zig applyCallable`/`applyPartial`) and the tail-call fast path check it now —
  the latter simply declines the fast path and lets the generic one report. A niladic
  still takes the one discarded argument that calls it (`{5}1` → `5`, the k way), so the
  ceiling is `max(arity,1)`; a gap counts as a slot, so `{x+y}[1;;3]` errors too.
- **`x . y` applies a function to a list of arguments**, matching ngn/k: `{x+y} . 1 2`,
  `{x+y} . (1;2)`, `.[{x+y};1 2]` → `3`; an atom is a single argument (`{x+y} . 1` →
  `{x+y}[1;]`) and `f . ()` applies nothing. This is the one way to call with an
  argument count that is only known at runtime. `ApplyN` — the deep-index half of `.`,
  documented since forever — turned out to be **dead code**: the struct was never listed
  in `verbs.zig`'s dispatch declarations, so *every* dyadic `.` was `!type`, including
  `(1 2 3;4 5) . 1 0`. Wired up, and both halves are generated over the type table now.
- **Lambdas take up to 16 parameters, and a 17th is rejected at the definition.** The
  cap is one constant, `operator.zig MAX_ARGS`, that everything sizes off: `Fn.arity`
  (u5), `Partial.args` + its `ArgMask` fill word, the MakePartial gap mask in the
  bytecode (now u16 — all four operand decoders updated), and the compiler's call-site
  check. Previously the parser accepted any number of parameters and the 9th blew past
  `Partial`'s 8-slot array — a debug panic, an out-of-bounds read in ReleaseFast.
- Measured before changing it (`bench/call.k`, `bench/sweep.sh`, ReleaseFast, min-of-5,
  ms/1M calls). 8 → 16 is free; 32 is not, because `Partial` doubles again:

  | MAX_ARGS | monad | dyad | triad | heptad | partial | nested | fib | powerset |
  |---|---|---|---|---|---|---|---|---|
  | 8  | 49 | 56 | 93 | 177 | 36 | 82 | 136 | 332 |
  | 16 | 51 | 58 | 94 | 178 | 38 | 80 | 136 | 329 |
  | 32 | 50 | 58 | 94 | 178 | **50** | **91** | 135 | 328 |

  The argument buffers are `undefined` rather than `.{.blank} ** N` — nothing reads past
  `argc`, so their size is pure stack arithmetic and costs nothing. Handing the callee
  the VM stack slice instead of a buffer (no copy at all) was tried and is *slower* —
  54 vs 49 ms/1M on the monad line, because the callee pushes into that same array and
  every argument access becomes aliasing to the optimizer.

## 2026-07-30 — parse errors have a location; two parser bugs fixed
- **Parse errors now report `line:col` with the offending line and a caret.** The
  parser records the byte offset of the token it stopped on (`Parser.err_pos`, set by
  an `errdefer` in `parse()`, so every error site gets a position without threading
  one through) and the REPL resolves it. Compile-time only — the VM is untouched.
  ```
  !parse_error: UnexpectedToken at 3:13
    $[x=1; 2; [3;4]]
                ^
  ```
  It paid for itself immediately: `test/llm.k` had been failing to parse for who knows
  how long with a bare `UnexpectedToken`, and the location pointed straight at
  `{[in] …}` — a lambda parameter named after the keyword verb `in`. Renamed; the test
  now runs, and `make test` is fully green for the first time this session.
- **Spacing no longer changes what `\` and `'` mean.** `sep \ str` was the scan adverb
  while `sep\str` was split, so `"\n" \ 1: path` silently returned the whole file as
  ONE line (this is what made `nnLoadVocab` return a 1-entry vocab and every ASR
  transcript come out empty), and `f ' xs` errored where `f'xs` worked. Only the
  operand to the LEFT decides now. `/` deliberately keeps its spacing rule — ` / ` is
  a comment.
- **Every closing bracket is now checked.** All 12 sites consumed their closer as
  `_ = self.eat(…)`, discarding the result, so a missing one left the cursor parked on
  someone else's token and the production returned "successfully" — swallowing the rest
  of the file with exit 0. `[3;4]` yielded an EMPTY dict plus a stray `4` statement;
  inside `$[…]` it ate the `]` and absorbed the following statement. This also explains
  the long-standing "deeply-nested inline layout silently halts execution" report from
  demo/earth.k (`.plan/triage.md`): that expression has an extra `)`, and the parser
  simply stopped without saying so.
  The new `Parser.close()` errors mid-source but stays lenient at EOF, because
  `parse` must tolerate HALF-TYPED source — lib/syntax.k re-parses on every keystroke
  to highlight, so `f:{[a;` still has to yield a partial tree. (The syntax suite caught
  exactly that when the first cut was strict everywhere.)

**Runtime** error locations are NOT included. Every hook lands on the hot path: the
dispatch loop has no error branch at all today, and adding `if (r == .err)` to
`doApply` measured **+3.7% on dot and +7.7% on fibonacci** — a real slowdown, so it
was reverted. See "Runtime error locations" in `.plan/tasks.md`; a comptime debug-only
flag is the obvious way to get them for free in release builds.

## 2026-07-29 (later) — DCE purity hardened; `.Apply` was classified pure
`isEffectful()` was a blocklist with `else => false`, so anything nobody thought about
was assumed pure and removable: `.Apply` (what `f'x` lowers to) and every IO verb
under `Apply1`/`Apply2` counted as pure, and `inlineLambdas` hard-coded
`is_pure = true` when folding an effectful `.Call` into an Apply. Now `isPure()` is an
ALLOWLIST that fails safe on new opcodes, and `Op1.purity()`/`Op2.purity()` are
exhaustive switches with no `else`, so adding a primitive is a compile error until it
is classified. Benchmarks unchanged (dot 351 vs 353, avg 32 vs 35, deltas 526 vs 537,
iota 668 vs 698).

This is hardening, NOT a bug fix — I could not construct a case where the old pass
loses an effect. Discarded statement values get a `Drop`, which was already effectful
and anchors them.

Two attempts at catching enclosing-local reads were tried and BACKED OUT; see
"Diagnostics for silent blanks" in `.plan/tasks.md`:
- A compile-time error had a 100% false-positive rate across lib/. GPU kernel and
  shader bodies (`gpu.kernel`, `shader.*`) are ordinary lambdas to this compiler but
  are INLINED by dye, where enclosing locals ARE in scope (`gemmK` in lib/nn.k, the
  slug fragment shader); and lib/fbx.k deliberately mirrors a param into a same-named
  global (`target::target`) so an inner lambda can see it.
- A dedicated `GlobalCk` opcode that raised only when the global was actually blank
  worked and cost nothing, but it is too narrow a mechanism to carry in the opcode
  set — especially with `.blank` itself slated for removal.

## 2026-07-29 — ASR another 2.2× (12× total); 8–10× real time
A 2.5 s clip now transcribes in ~315 ms (was ~680 ms yesterday, 3.8 s originally);
14.7 s takes 1.39 s, i.e. **10.6× real time**. Token ids still match NeMo exactly.
Profiling first, so the work went where the time actually was — at T'=32 the encoder
split roughly 73% GPU kernels / 15% host+allocation / 12% dispatch overhead, with the
matmuls only ~33% of it. So the wins were *not* where I expected:
- **The rel-pos embedding was rebuilt and re-uploaded every layer.** It depends only
  on (T,D), so all 24 layers were computing the identical [2T−1,D] table host-side —
  ~45 ms per encoder run, plus 24 uploads. Cached on the device (`nnPosEmbB`).
- **LayerNorm gave each ROW one thread.** A [32,1024] norm launched 32 threads that
  each walked 2048 dependent global loads: ~0.38 ms of pure latency per dispatch, and
  there are 5 per layer. `lnStat2K` gives each row a whole workgroup (coalesced
  strided slices + a shared-memory fold), same two-pass formulation. ~50 ms.
- **`gpu.bufferN[n]`** (new, in gpu_vk.zig) allocates a storage buffer with NO upload.
  The nn scratch buffers are fully overwritten by the kernel that fills them, so
  `gpu.buffer[n#0.]` was building an n-float zero vector host-side and memcpy'ing it
  in — and in the interpreter that host array is the expensive half. ~60 ms.
- **`nnMvT`: hold decoder weights COLUMN-wise.** Reading a matrix-vector product as
  Σ_k x[k]·W[:,k] instead of n separate dot products collapses n·(alloc+multiply+
  reduce) into k·(scalar×vector) plus one fold. Same k order, so **bit-identical** —
  3.4× at the decoder's 2560×640 shape. Decode 208 → 49 ms at 2.5 s (4.2×).
  `nnPrepDec`/`TdtGreedyP` hoist the transpose out of the per-utterance path.

Measured and rejected: memoising the predictor across blank steps. It looks free
(state unchanged ⇒ identical LSTM output) but the hit rate is **0%** — TDT advances
time with its duration head rather than emitting blanks, so essentially every step
emits. Noted in the code so nobody re-derives it.

Beware when profiling this stack: several micro-benchmarks reported sub-microsecond
"per-call" times for work that never ran. (I first blamed dead-code elimination —
wrong, see the 2026-07-29 entry. The real causes were building GPU resources outside
`gpu.computeRun`, and nested lambdas reading enclosing locals.) Every number here
came from timing the real pipeline with kernels stubbed out group by group.

## 2026-07-28 (later) — ASR is ~6× faster, and now runs faster than real time
Transcription was 3.8 s for a 2.5 s clip. It is now 0.63 s, and a 14.7 s clip went
from 14.7 s to 2.1 s — i.e. from roughly 1× real time to **~6.8×**. Output is still
bit-identical to NeMo (`make asr-test` covers both an aligned and an unaligned T').
Measured, not guessed — the encoder was 85% of the time and scaled at 124 ms/layer.
- **`LinearR` used a naive one-thread-per-output kernel.** Every output re-read a
  full row of X and of W, so each weight was fetched M times, and adjacent threads
  read K floats apart (completely uncoalesced). Added `lin2dK`: gemm2dK's shared
  memory tiling with B transposed (W is [N,K]) and the bias folded into the store.
  Encoder 2663 → 583 ms.
- **The tile must not require an aligned row count.** A first cut demanded M%16=0.
  M is the encoder frame count T', an arbitrary function of utterance length, so
  that silently dropped most real utterances back to the slow kernel — a 10 s clip
  (T'=126) still took 10.6 s. The launch now rounds rows up to a whole tile and
  threads outside [0,M) neither load nor store. 10 s clip: 10.6 s → 1.5 s.
- **`nnMv` rebuilt an index vector per output row.** `W@(o*k)+!k` constructs a
  k-long index and gathers, for every one of n rows. `nnMvR` takes W pre-split into
  rows (done once in `TdtGreedy`'s setup, not once per decode step): 3.1× faster at
  the decoder's 2560×640 shape, bit-identical. Decode 531 → 180 ms.
- **`EncoderRW`** runs over weights already on the device. Uploading the 24 layers
  is ~300 ms, which was most of a short utterance's encode time and was being paid
  on every transcription; `demo/asr.k` now uploads once, on the first transcription
  (there is no GPU context to upload into until `window.run` is live).

Still on the table: the GEMM has no register blocking — each thread computes one
output with two shared-memory reads per multiply-add, which is why it sits at
~74 GFLOP/s against ~5 TFLOP/s of hardware. A 4×4 register micro-tile is the next
big win. The host-side TDT decode is now the second bottleneck (~38% at 14.7 s).

## 2026-07-28
- **`demo/asr.k` actually transcribes now**, and the pipeline is pinned to NeMo
  itself rather than to our reading of the paper. `doc/parakeet-oracle.py` runs the
  real `.nemo` model over a wav and dumps every stage (mel, subsample, encoder,
  token ids) into a safetensors; `test/asr.k` (`make asr-test`) recomputes each
  stage in ink and diffs. End result on the 2.5 s test clip: mel/subsample/encoder
  match to ~1e-5 relative, and the decoder emits the **exact same 19 token ids**,
  detokenizing to `The quick brown fox jumps over the lazy dog.`
  Four real bugs came out of that diff:
  - **The predictor was 1-layer; the model is 2-layer** (`prednet.pred_rnn_layers: 2`).
    The export already wrote `dec.wih0/whh0/b0` + `dec.wih1/whh1/b1`, which
    `nnLoadDecoder` didn't even look for, so decoding produced nothing at all.
    `TdtGreedy`'s weight list is now 12 tensors and its state carries `(h0,c0,h1,c1)`.
  - **The joint activation was `tanh`; NeMo's is `relu`** (`jointnet.activation: relu`).
  - **The featurizer skipped preemphasis and mis-framed the STFT.** NeMo applies
    `preemph 0.97`, then `torch.stft(center=True, pad_mode="constant")` — note
    *constant*, i.e. ZERO padding, not torch's default reflect. Since `|X|²` is
    invariant to a time shift, we get this exactly by zero-padding `nfft÷2 −
    (nfft−win)÷2` samples and keeping the cheap win-point transform. The log guard
    is `2⁻²⁴`, not `1e-5`.
  - **Per-feature normalization used the wrong frame count and the wrong std.**
    NeMo's `get_seq_len` is one LESS than the number of STFT frames: the trailing
    frame is excluded from the mean/std and then zeroed. The std is UNBIASED
    (÷ n−1) and the `1e-5` is added to the std, not to the variance.
  `nnFeatures` now wraps that whole preprocessor as one call.
- **`nnLoadVocab` returned a 1-entry vocab** because `"\n" \ 1: path` used a SPACED
  `\`, which parses as the scan adverb rather than split — a silent wrong answer.
  Every transcript detokenized to the empty string. Glued (`"\n"\s`) is correct;
  noted in AGENT.md and `.plan/triage.md`.
- The demo auto-detects the weights (no more `LOADMODEL` flag), defers the ~4 s
  transcription to the frame after it paints a "Transcribing..." state so the window
  doesn't look hung, and reports too-short clips instead of silently doing nothing.

## 2026-07-26
- **Syntax highlighting in `demo/edit.k`, driven by `parse` itself.** The editor is
  rebuilt on two new libraries and the Iosevka font.
  - **`lib/syntax.k` — configurable highlighting.** A highlighter is a function
    `codepoints → role index per codepoint`; a THEME maps each role
    (`num str sym bool dyad mono over scan assign bracket cond …`) to an rgba from
    `lib/color.k`'s Tailwind/OKLCh palette. Both halves swap: register another
    language with `syn.reg[name;fn]`, hand `syn.setTheme` another role→colour dict
    (`syn.themeDark` / `syn.themeLight` ship, matching the Zed extension's colours).
    `syn.runs` collapses the role vector into the runs a renderer draws.
  - **The ink highlighter has no lexer of its own.** `parse` returns the CST as a
    column table with CODEPOINT ranges, so a highlight is "paint each node's range,
    let children overwrite their parents" — whatever a container still owns is
    exactly its own punctuation (a call's `[`/`]`, an assignment's `:`, a fold's
    `/`). Valence comes from the tree, so `+` is purple in `1+2` and the rest falls
    out: `*` monadic in `*1 2 3`, `@` red in `@[x;i;:;v]`. `parse` tolerates
    half-typed source, so this re-runs on every keystroke; no second parser, no LSP
    round trip (and so no UTF-16 offsets). `syn.enc`/`syn.dec` bridge UTF-8 source
    text and codepoints.
  - **Adverbs are coloured by ARITY, not by glyph.** An adverb taking one left
    argument (`+/1 2 3` fold, `f'x` each, `24 60 60\n` encode) is an ordinary
    adverb; the DIGRAM forms that take two (seeded fold `10+/`, zip `x f'`, stencil
    `3 f'`, n-do `5 f/`, while `f f/`, seeded eachprior `10-':`, eachright `x f/:`)
    get their own colour — any of `' / \` can be either. In the CST that is exactly
    "the term sits in the dyadic verb slot", so it reads straight off `field`. The
    verb underneath follows: only plain Each applies its verb monadically, so `#`
    is dyadic in the zip `2 3#'"ab"` but monadic in `#'x`.
  - **`lib/rope.k` — a SumTree rope.** Text lives in a B-tree of ~64-codepoint
    chunks, each node carrying a `(codepoints; newlines)` summary, so offset→row,
    row→offset and line fetch are O(log n) descents. A leaf-local edit rewrites one
    chunk and pushes a summary delta up the parent chain; an edit that would
    over/underflow a leaf re-chunks and rebuilds bottom-up from the leaf list
    (O(#leaves), vectorised, re-using untouched chunks by reference).
  - **The editor**: Iosevka (a TTC — `font.read` returns every face), line-number
    gutter, current-line highlight, wheel scrolling, page up/down, sticky-column
    vertical motion, a status bar, `cmd+shift+=`/`cmd+shift+-` to change the font
    size, and `cmd+shift+T` (or F1) to flip the theme live.
  - **`slug.SCCAP` 262144 → 1048576 floats.** The old scene buffer stopped a text
    editor at ~600 glyphs — half a screen — and truncated silently; `sceneFlush`
    now clamps to capacity instead of overrunning.
- **Canvas text is ~125× cheaper per frame** (~310 ms → ~2.5 ms for a screenful of
  1392 glyphs), which is what made typing in the editor feel laggy. Two causes, both
  fixed in `lib/canvas.k` + `lib/slug.k`:
  - **A persistent glyph cache.** A glyph's banded curve data depends only on
    (face; size; gid), never on colour or position, so it is built once and reused
    instead of re-extracting the outline (`font.quads`) and re-binning it every frame.
    Face and size resolve to registry indices ONCE per `cnv.text` call, packed with the
    gid into an int cache key. The registries are keyed by face NAME: `?` cannot look up
    a face value (given a non-atomic right argument it vectorises over it instead of
    matching it whole) and `~` on two faces deep-compares the whole font, ~2 ms a go.
    Bounded, with a frame-start sweep, so animating text size recycles rather than leaks.
  - **`slug.addFillN`** appends a whole batch of pre-banded fills in ONE join. Adding
    a screenful of glyphs one at a time re-copied the accumulator each time — quadratic,
    ~170 ms of the old cost.
  Text now records less per glyph too: the clip-baked paint block is built once per
  `cnv.text` call rather than per glyph (`TXCOL`/`TXCLM`/`TXCLE`/`TXFACE`/`TXSZ` are gone).
- **`demo/edit.k` lays out in framebuffer pixels.** `props`width/height/mx/my` are
  framebuffer px and `props`dpr` is the ratio, so sizes written straight into draw calls
  came out half-size on a retina display. Layout constants are now logical points scaled
  by `dpr` each frame (as `lib/ui.k` already did).
  - Tests: `test/rope.k` (59 assertions) and `test/syntax.k` (51, pinning the role
    of every codepoint of each sample line); both wired into `make test`.

## 2026-07-21
- **Canvas/Slug 2D renderer → ONE analytic backend.** Fills, gradients, clips,
  strokes, text, and image paint all render through the Slug scene buffer
  (`lib/slug.k` + `lib/canvas.k`); tessellation is retired from the canvas path.
  Design/gotchas: `doc/design/canvas-slug.md`.
  - **Gradients + clip in the fill shader.** Each fill packs its 44-float NanoVG
    paint block (linear/radial/box gradient or solid, with the active clip baked in)
    into the scene buffer; the fragment evaluates `scissorMask` + the rounded-rect
    gradient SDF at its screen position and folds paint × coverage into the alpha.
  - **Strokes via Slug.** A stroke becomes a fill outline: each vertex offset ±½-width
    along its miter bisector (`canvas.miterContour`). Open paths → a ribbon (butt
    caps); closed paths → an annulus (two contours). Then it's a normal fill.
  - **Image paint.** `cnv.image[img;x;y;w;h;rgba]` (img = `cnv.loadImg[path]`) samples
    an image texture × analytic coverage × clip. Enabler: `shader.fragmentBufTex` —
    a dye fragment that reads both storage buffers and a texture.
  - **CFF/OTF fonts.** `font.quads` now works for PostScript (CFF) outlines: the
    native charstring interpreter gained a quads mode (each cubic split to 2
    quadratics, exported `cffQuads`), so OTF text renders analytically like glyf.
  - **Scene-buffer compaction.** An indexed band layout (per-band `(offset,count)` +
    a packed curve pool, no `slugMPB` padding) shrinks a fill ~10× — a 250+-glyph
    paragraph now fits (was capped at ~85 fills).
  - **Double-buffered scene/quad-pool** (parity-cycled, in lockstep with the GPU
    frame) removes the FRAMES-in-flight write-vs-read data race — no engine change.
  - **Robustness:** independent-aspect band normalisation (flat shapes spread across
    all bands instead of truncating), and the pull pipeline's depth compare relaxed
    to `LESS_OR_EQUAL` so overlapping coplanar 2D quads (packed glyphs) all pass.

## 2026-07-16
- **`kk.compile` placed tables** (kk2 §2.5, the last §2 milestone): `gpu.holdT[t]`
  places a k table as a structured buffer — one resident buffer per column
  (planar/splayed) — and `kk.compile` binds only the columns a kernel actually
  reads. A column access `(t`c)` (an apposit var+symbol) resolves to that column's
  buffer, element-loaded at the thread index (`xTableCol`; `shader.table`). Binding
  inference (`kkTableColNames`) prunes unreferenced columns — the kdb splayed
  property on the device. Since `t`c` on the CPU already IS the column, the same
  lambda runs both sides. Verified in test/kkc.k (22/22): column arithmetic vs CPU
  + a pruning check. Deferred: interleaved layout, placed dicts (ragged CSR), and
  tables composed with gather/reduce/scatter. **This completes the kk2 §2 roadmap
  (gather, matrix-reduce, amend, scatter-add, tables) on top of the walk.k
  headline.**
- **`kk.compile` scatter-add `@[x;I;+;v]`** (kk2 §2.4-5): compiles to
  `shader.scatadd` — one thread per index, `acc[I[d]] += i32(v)` via `OpAtomicIAdd`
  (`kScatAdd`) so duplicate buckets accumulate race-free. acc is an i32 accumulator
  (zero-inited); I is padded with a sentinel into acc's padding tail; v is a
  constant (baked) or a single value vector. Result descriptor is tagged `t:`i` and
  `gpu.fetch` reads it via `gpu.readI`. Verified in test/kkc.k with count, skewed,
  and weighted histograms vs CPU `@[…;+;…]` (19/19). Deferred: float fixed-point
  scaling and paired/multi-value scatters.
- **`kk.compile` amend-scatter + ping-pong iterate — walk.k acceptance met**
  (kk2 §2.4-4): `@[x;I;:;v]` compiles to `shader.amend` — one thread per interior
  index, the value expr (`1.+.25*+/x@W`) computed through the gather-reduce IR and
  scattered to `out[I[d]]` (`kScatStore`); I is padded with a sentinel index into
  out's padding so over-dispatched threads can't clobber, and out starts as a copy
  of x so boundary cells carry through. **`kk.loop[f; x0; niter]`** ping-pongs two
  buffers via `gpu.dispatchLoop` (one encoder, barriers handled). walk.k's
  `f:{@[x;I;:;1.+.25*+/x@W]}` compiles **verbatim** and 30k sweeps on the 100×100
  grid converge to **E@center = 2887.3418** — the documented Jacobi f32 fixpoint
  (test/walkgpu.k PASS; small-grid checks in test/kkc.k, 17/17). This is the
  headline increment-5 acceptance. (walk.k's `f/` converge → fixed-count `n f/`
  here; true device-side converge is tier-2.)
- **`kk.compile` host-vector auto-upload** (kk2 §2.4-3, milestone 3 core
  complete): a `+/x@W` gather operand that isn't a param (x/y/z) is treated as a
  host global — `kkResolve`/`kkUpload` reads its value and `gpu.hold`s it
  read-only, taking the `(k;n)` shape from the value. So **walk.k's
  `1.+.25*+/x@W` with `W` a host global compiles and matches the CPU bit-for-bit**
  (test/kkc.k 14/14). Gotcha: `gpu.hold . nm` parses `.` as dyadic (name on its
  left) → applies to the symbol, not its value; take the value in its own
  statement first. Minor remaining gap: single gather `x@w` still needs both
  operands passed as placements (auto-upload is wired only through the matrix
  path, which is what walk.k uses).
- **`kk.compile` matrix gather-reduce: `+/x@W` → walk.k interior** (kk2 §2.4-3,
  milestone 3's core done): `xApposAdv` now recognises a `/`-fold over an
  `@`-transit and emits a real `rsum`/`rmax` region node whose body gathers
  `x[W[(j*n)+d]]` (`xRedGather`); `k`,`n` come from W's `(k;n)` descriptor shape,
  baked into the kernel (cache key carries them), output length = n. kk.compile
  branches to the matrix path on `kkIsMatReduce[]`. **walk.k's interior update
  `1.+.25*+/x@W` compiles and matches the CPU bit-for-bit** (test/kkc.k, 13/13);
  `|/x@W` (max) works too. Two traps fixed: joining `` `x`y `` with an empty INT
  vector `!0` upcasts to a boxed list and breaks the env dict (use `0#\``), and
  the rsum path needs `kAlloc` with `hasLoop=1` for its loop constants. Remaining
  in milestone 3: host-vector free-name auto-upload (W/I as host globals).
- **`kk.compile` gather: `x@y` → index-buffer gather** (kk2 §2.4-3, milestone 3
  starts): a param used as the LEFT of `@` is a gather SOURCE (a whole buffer,
  indexed); every other param is an index that's auto-loaded at the thread index
  d, so `kk.compile[{x@y}; (data;idx)]` computes `out[d] = data[idx[d]]` and
  returns a descriptor. New dye machinery: an `elem` env role (a bare buffer name
  means buf[d] — `xVarE`/`xElem`), `@` lowering to a nested buffer index
  (`xGather`), and a gather kernel builder `shader.gmap[fn; bufNames; elemNames]`.
  Verified in test/kkc.k against CPU `data@idx`. (Host-vector auto-upload of free
  names + the `+/x@W` matrix reduce — the rest of milestone 3 — are next.) Fixed
  an empty-typed-vector trap found here: `f'(!0)` yields a general-list `()`, and
  `&()` then `v@…` spuriously returns one element, so a no-`@` body looked like a
  gather — the has-`@` scan now guards the empty case.
- **`kk.compile` — elementwise whole-array lambdas on placements** (kk2 §2.4-2,
  increment 5 starts): `kk.compile[fn; descriptors]` takes a whole-array lambda
  in implicit-param form (`{2.*x}`, `{x+y}`, `{(x+y)*z}`, `{sqrt x}`,
  `{$[x<y;y;x]}`), compiles it to a per-thread map (dye's new
  `shader.map[fn; nIn]`, generalising compCompute/compute2 to N inputs), runs
  it over the placed arrays (one thread per element), and returns an OUTPUT
  descriptor — so `8: kk.compile[{2.*x}; ,a]` reshapes like any placed array.
  Pipeline cached by (lambda source; #inputs); output padded to the ×64 grid
  (descriptor n/s stay real → 2-D shapes round-trip). A subset classifier
  (`kkClassify`) rejects gather/amend/adverbs/non-math applies, NAMING the
  offending verb (no silent fallback — those forms are later milestones).
  Oracle test/kkc.k: GPU vs CPU bit-for-bit (sqrt at f32 tol), cache reuse, and
  rejection (9/9). Fixed a latent trap this surfaced: `str in list` runs
  char-wise (a string is a char vector), so string dict keys give false `$[]`
  hits — kk uses symbol cache keys.
- **Fragment/vertex compile through the neutral IR; direct `comp*` walker
  deleted** (kk2 §3, the seam finished): `shader.fragment`/`fragmentTexN` now
  go through `kSeqIr`, and `shader.vertex`/`vertexU` through `xSeqEnv` + a new
  `vstore` effect node that pins each output store (gl_Position through the
  gl_PerVertex block member, varyings direct) at its build position — so
  lowering in build order reproduces the id sequence exactly. Added a `sample`
  IR node (image+sampler loads → OpSampledImage → ImageSample) and a `consc`
  node (vector-literal OpConstantComposite) so the fragment subset is fully
  covered. With every entry point on the IR, the ~376-line direct expression/
  loop/seq walker (`compNode`/`compSeq`/`compApply`/`compRsum`/… + `dispUn`/
  `splat`/`compVar`/`compSeqEnv`) is removed — single-pipeline dye (1498→1122
  lines). Oracle: 7 new fragment/vertex/texture cases added to test/kkgold.k
  and captured BEFORE the migration; all byte-identical after, and each passes
  spirv-val vulkan1.2. test/spirv.k 85/85, test/ir.k 7/7, test/nn.k GPU maxerr
  unchanged, planes.k renders (30% non-black).
- **Compute/vertex const-fold + multi-root DCE** (kk2 §3, finishes the seam):
  new `xOpt` flag (default 0 = lower every node, byte-identical). `xOpt=1`
  runs `xFold` then keeps only nodes reachable from a multi-root set — the
  value result **plus every store** (setb/sadd/isetb/vstore) **plus every loop
  and its result phi(s)** — so stores never get culled and loop bodies (reached
  only via `xVal`, not `xArg`) keep the top-level values they read; `xLoRegion`
  now gates owned nodes on `xRe` too, giving intra-loop DCE. Verified: with
  xOpt on, the whole nn suite is **bit-identical** GPU output (semantics
  preserved), all 19 kkgold modules stay spirv-val-clean, and it's genuinely
  effective (a dead `g[1]` load and a `0.5*0.5` const both vanish) while the two
  atomic scatters / loop phis survive. New oracle test/kkopt.k (9 checks).
  Still TODO in §3: i32 index arithmetic.
- **`+/{[k] e}'!K` is the canonical in-kernel reduction spelling** (kk2
  §2.4-1/§8-3): dye recognizes fold-over-each-over-enumerate (`+/` → rsum
  region node, `|/` → rmax) in xAppos→xFoldEach and lowers it through the
  shared xRed builder — byte-identical to the intrinsic `rsum[K;{[k] e}]`/
  `rmax[…]` spelling by construction (no range materialised). The intrinsic
  names stay as documented equivalents; any other monadic adverbed verb in a
  kernel now warns + bakes NaN instead of silently compiling as negate.
  test/kkgold.k asserts the two spellings' byte-identity for gemm + softmax
  (12 gold dumps unchanged); lib/nn.k migrated to the full syntax (15 sites,
  all 12 kernels byte-identical; test/nn.k GPU maxerr unchanged).

## 2026-07-15
- **Monadic `%` = Shape** (the glyph was free since sqrt moved to the
  prelude; dyad stays divide): rectangular extent as an int vector, ragged
  lists stop at the first non-uniform level (`%(1 2;3 4;5 6)`→`3 2`,
  `%(1 2;3 4 5)`→`,2`, atoms→`!0`); inverse of reshape. New
  src/primitive/verb/shape.zig + unit tests. Placed-array descriptors gain
  `s: %x` — `9:` flattens nested rectangular input for upload and `8:`
  reshapes the readback, so `8: 9: (N;N)#x` round-trips (kk2.md §8-4).
- **Compute bodies compile through the neutral IR** (kk incr 3, the seam
  migration): kSeqIr builds typed SSA for every compute entry point and
  lowers it in build order. New IR ops: bufidx/igetb loads, setb/sadd/isetb
  effects, f2s conversions, bufp binding refs, and rsum/rmax/ndo/whileL as
  opaque region nodes (xRgn owner column; loop lowerers replay their owned
  nodes inside loopOpen/loopClose blocks; nesting via saved RK* phi globals).
  All 12 kkgold modules byte-identical to the retired direct path; golden,
  walk3, nn, clothgpu, baking, inference, fragment-IR all verified. The
  second backend (bits → FusedMap) and IR-level rewrites now have the full
  compute dialect to target.
- **Binding inference: `shader.kernel[fn]` + `gpu.pipeline[fn]`** (kk incr 3,
  bindings-from-the-lambda): params passed to scatterAdd/iget/iset are i32
  accumulators (must come first; warned otherwise), the last param is the
  thread index, the rest are f32 buffers. Byte-identical to
  `gpu.kernel[fn;nAcc;nBuf]` with the right counts. `gpu.pipeline[fn]`
  compiles lambda→SPIR-V→cached pipeline in one call (nbind published as
  KKnb). New gotcha documented in code: `kVal *kF[…]` is kVal TIMES kF
  (noun-adjacency); use kF1.
- **Host-global baking in kernels** (kk increment 3, first slice): a name in a
  dye kernel that isn't a param/local now resolves to the HOST global's current
  value, baked as an f32 constant at kernel-compile time — "host globals are
  invisible inside shaders" is gone, and with it the keep-in-sync-by-comment
  literals (clothgpu.k's `SC` now referenced directly in kCon/kApp). Unknown or
  non-scalar names warn and bake NaN (loud, since ink has no signal verb).
  Both compiler paths (compVar + IR xVar).
- **Fix: ReleaseFast GPU builds crashed at vkCreateInstance** — the release
  link dead-stripped static MoltenVK's ObjC selector metadata
  (`+[NSProcessInfo processInfo]: unrecognized selector`). `link_gc_sections =
  false` on libgpu.dylib (and `--no-gc-sections` in `ink bundle`'s link).
  Debug builds only worked because they don't gc sections.

## 2026-07-14
- **`9:`/`8:` io verbs** (kk increment 4, verb surface): the GPU is an io
  channel — `9: x` places (upload → descriptor `[gpu;t;n]`), `d 9: x`
  overwrites in place, `8: d` fetches, `n 8: d` fetches n. Implemented as
  `io.zig` trampolines to `gpu.hold`/`holdInto`/`fetch`/`fetchN` (new, in
  lib/gpu.k); `8:` added to the grammar (`9:` was a reserved stub); `!io`
  when lib/gpu.k isn't loaded.
- **`gpu.caps`** (completes kk increment 0): device capability dict from the
  live Vulkan device (`Vk.queryCaps` → `gpuCaps` FFI). M1 Pro/MoltenVK reports
  ALL of: subgroup arithmetic (32 lanes), descriptor indexing + runtime
  descriptor arrays, buffer device address, f16, and VK_EXT_shader_atomic_float
  f32 add — so subgroup reductions, bindless, and native float scatter-add are
  all on the table (features still need enabling at device creation to use).
- **Vulkan cutover** (kk increment 0 / migration Phase 5): Dawn/WebGPU backend
  deleted (`lib/gpu/gpu.zig`, `render.zig`, `fill.wgsl`, `blit.wgsl`,
  `patches/`, zon deps, `gpuWgsl`); raw Vulkan/MoltenVK (`gpu_vk.zig`) is the
  only backend; `zig build static` merges gpu+MoltenVK+GLFW into
  `libgpu-bundle.a` (11MB, was ~20MB). Run `make install` to refresh the stale
  Dawn dylib under `~/.ink`.
- **SPIR-V 1.4 native** (kk increment 2 / migration Phase 6): dye.k emits
  version `0x00010400` with the full-interface `OpEntryPoint` rule in all four
  assemblers (compute `kAsm`, fragment `buildMod`, `shader.vertexU`,
  `lib/instancing.k`); the `INK_SPV14`/`maybeBump` live transform is removed.
  12/12 kkgold modules pass `spirv-val --target-env vulkan1.2`; golden +
  walk3/nn/sphere/circle/eyes/earth/clothgpu all verified.
- **kk design** (`doc/design/kk.md`): plan for compiling idiomatic k to both
  SPIR-V and ink bytecode — io verbs `9:` (place on GPU) / `8:` (fetch), the
  k-primitive→compute rewrite table (each/gather/amend/fold/scan tiers), placed
  arrays as the data layer, SPIR-V 1.4 flip + caps-gated bindless, and the
  IR→FusedMap CPU backend (`bits`).
- **dye consolidation** (kk increment 1): the eight compute emitters in
  `lib/dye.k` (`shader.compute{,U,2}`, `shader.stencil{,U,IP}`,
  `shader.scatter`, `gpu.kernel`) are now thin wrappers over one shared
  prologue/assembler (`kAlloc`/`kGidX`/`kGidF`/`kElem`/`kStore`/`kAsm`);
  ~370 lines deleted, one `hdr:` site remains (prereq for the SPIR-V 1.4 flip).
  `gpu.kernel` with no accumulators no longer emits dead i32 types/constants.
  Oracle: `test/kkgold.k` module dumps (9/12 byte-identical, 3 improved),
  `spirv-val` on all, `walk3`/`nn`/`clothgpu`/`spirv.k` end-to-end.
