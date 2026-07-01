# Copy-and-Patch for ink — design & remaining work

Status: **design / roadmap. Nothing here is implemented yet.** This documents how
a copy-and-patch (C&P) backend would slot into ink, how primitives, k modules,
and native extensions get stitched into one body of machine code via
continuation-passing style (CPS), and the concrete steps to build it.

Background reading: `doc/copy-and-patch.md` (the paper). The companion piece is
the extension-ABI redesign already shipped (see the `ink-extension-abi-redesign`
notes and `src/ffi.zig`): C&P is the third "binding time" of the same idea — see
*The through-line* below.

---

## 1. Why C&P for ink (and what the real prize is)

C&P is a code-generation technique: precompile small CPS code fragments
("stencils"), one per IR operation, into relocatable objects with "holes"
(relocations) for constants, operand locations, and the address of the next
fragment. Codegen is then `memcpy` the stencil + patch the holes — no
instruction selection, register allocation, or optimization passes. Reported:
~interpreter-build-speed codegen, near-`-O2` execution.

For a **scalar** language the headline win is eliminating per-op interpreter
dispatch. ink is an **array** language, so that win is muted: the dispatch loop
in `VM.run` (`src/runtime/vm.zig`, `switch (@enumFromInt(b))`) already amortizes
over whole-array work — one `Apply2` opcode adds a million elements inside a
tight Zig loop. Dispatch is a rounding error there.

The real prize for ink is **fusion**: `+/ a*b` today materialises the temporary
`a*b`, then reduces it. ink already hand-codes *one* fused kernel — the
`ReduceZip` opcode dispatching to `fuse.reduceZip` (`primitive/derived/fuse.zig`).
A C&P backend generalises that: stitch scalar stencils (`load`, `mul`, `add`,
`accumulate`) into a single generated per-element loop, killing both dispatch
*and* the intermediate allocation, for *arbitrary* element-wise chains rather
than the one hand-written case. The byte-at-a-time pure-k code (the FBX/USD
inflate, the regex NFA, the parsers) is the other beneficiary — that code is
genuinely dispatch-bound today.

So the goal is **two tiers** (see §5): cheap dispatch elimination for the whole
bytecode, and scalar fusion for element-wise subgraphs.

---

## 2. The mechanism, in ink terms

A **stencil** is one IR op compiled as a CPS function: it does its work against
the VM state and *tail-calls its continuation* instead of returning. The
continuation address is an undefined `extern` symbol → a relocation → a hole.

```zig
// conceptual stencil for an element-wise op, CPS form
export fn st_add(sp: [*]V) callconv(.c) void {
    // ... pop two, push sum, against the value stack ...
    return @call(.always_tail, CONT, .{sp});   // CONT is a hole, patched to next stencil
}
extern fn CONT(sp: [*]V) callconv(.c) void;     // undefined → relocation
```

The **state threaded through CPS** is ink's value-stack pointer (and, where
needed, the frame pointer) — the same `[STACK_MAX]V` the interpreter walks. So
stencils push/pop exactly like the interpreter ops do; the only change is *how
control flows between them* (patched tail calls instead of a `switch`).

**Holes** come in four kinds:
1. **continuation** — address of the next stencil (straight-line flow);
2. **branch targets** — for `Jump`/`JumpFalse`/`JumpTrue`, patched to a basic
   block's stitched address (ink already computes the CFG: `Chunk.buildBlocks`
   in `tape.zig`);
3. **immediates / constants** — `Int` operand, `Const` pool index, local/global
   slot numbers;
4. **callee addresses** — the target of `Apply*`/`Call`/`Command` (see §4).

Codegen = walk the `Chunk`, pick a stencil per op, `memcpy` its `.text`, apply
its relocations. The stencil library is built once per target by compiling a
`stencils.zig` at `-O2` and reading the object file's `.text` + relocation
entries.

---

## 3. Mapping ink's opcodes to stencils

ink's IR is small and already C&P-shaped (`OpCode` in `tape.zig`):

| opcode group | stencil treatment |
|---|---|
| `Const`, `Int`, `Global`, `Local`, `LocalLast`, `Dup`, `Drop` | trivial stack-shuffling stencils; operand = a hole |
| `AssignGlobal/Local`, `ListAssign*` | store stencils; slot index = a hole |
| `Jump`, `JumpFalse`, `JumpTrue` | branch stencils; target = a BB-address hole |
| `Apply1..4`, `Apply`, `ReduceZip` | call the existing verb impls via `dispatch1..4` (tier 1), or fuse (tier 2) |
| `Call`, `TailCall`, `Return`, `MakePartial`, `Derive` | the k-function calling convention; targets are holes (§4) |
| `MakeList`, `Command` | call into the runtime helper; arg counts are immediates |

Crucially the **primitives don't get rewritten**. ink's ~60 verbs and ~15
adverbs stay as the compiled Zig functions they are; in tier 1 a stencil is just
a CPS shim that calls `dispatch.dispatch2(vm, op, a, b)` and tail-calls the
continuation. The interpreter and the stitched code share one runtime (value
model, RC/COW, primitive impls), so they can coexist and the interpreter remains
the fallback/oracle (see §8).

---

## 4. Modules and extensions stitch in the same way — *the through-line*

The shipped extension ABI already established the principle: **how a call is
wired is decoupled from when** (`registry-by-name`, `k_register`, `ext_fns` in
`src/ffi.zig`). A call site never names the dynamic loader; it resolves a target
through the registry. C&P is the *patch-time* binding of that same idea:

- **Primitives** → stencils whose callee is a known runtime symbol (resolved at
  stencil-build time).
- **k functions / modules** → a k module is just more k source → the same IR →
  the same stitching. A module function's body is a stencil chain ending in
  `Return`. A cross-module `Call` is a **call stencil whose callee address is a
  hole**, patched to the callee function's stitched entry. Modules thus link
  into one stitched graph exactly like the bundler links `.a`s today.
- **Extensions** → a `2:(`Name;arity)` call becomes a leaf call stencil whose
  callee is the **registered function pointer from `ext_fns`** — i.e. the hole
  is filled from the same registry the interpreter uses. Statically-linked
  extensions (the bundle path) resolve to a relocation against the linked
  symbol; dlopen'd ones resolve to the runtime pointer. Same hole, three binding
  times: runtime (dlopen), link (static bundle), patch (C&P).

This is why the ABI work was a prerequisite: with resolution already funnelled
through one registry, the C&P backend has exactly one kind of "callee hole" to
fill for primitives, module functions, and extensions alike.

---

## 5. Two tiers

**Tier 1 — dispatch elimination (whole-array stencils).** Map every opcode to a
CPS stencil that does what the interpreter case does (calling the existing verb
impls). Removes the `switch` dispatch and per-op decode. Modest speedup for
vectorised code, real speedup for control-flow- and call-heavy k. Lowest risk;
build this first as the skeleton.

**Tier 2 — scalar fusion (the prize).** A compiler pass recognises element-wise
verb chains over conforming unboxed arrays (`B`/`I`/`F`) — generalising the
existing `ReduceZip` — and lowers them to a single generated loop whose body is
*scalar* stencils (`load aᵢ`, `load bᵢ`, `mul`, `add`, `store`/`accumulate`).
No intermediate arrays, no V boxing inside the loop. This is where an array
language gets `-O2`-class kernels for free. Restrict to unboxed numeric paths;
fall back to tier 1 / interpreter for boxed (`L`/`m`/`M`) or ragged operands.

---

## 6. AOT vs JIT — and the bundle angle

The stencil-stitcher runs at either time:

- **JIT (load time):** stitch the program's chunks into an `mmap`'d
  `PROT_EXEC` buffer on first run; jump in. Interpreter handles anything without
  a stencil.
- **AOT (bundle time):** this is the payoff for `ink bundle`. Instead of (or
  alongside) embedding bytecode the runtime interprets, **stitch the program
  (main + needed module functions) into native code at bundle time and emit it
  as an object linked into the bundle** next to `libink-core.a`. The bundle runs
  native on the hot path, no interpreter loop. Extension calls are real
  relocations against the linked extension `.a` (already how static bundles
  link — see `bundleStatic`).

AOT needs the **target's** stencil library, exactly like cross-target bundling
needs the target's static `.a`s today. Reuse the per-platform infra:
`make static-all` → `share/<platform>/`; add `stencils-<platform>.o`/table
beside the `.a`s.

---

## 7. Roadmap (ordered)

1. **Stencil library + extractor.** Author `src/runtime/stencils.zig` (CPS op
   bodies). Add a build step that compiles it at `-O2` per target and extracts
   each stencil's `.text` + relocations into a generated table. Start tiny:
   `Const`, `Int`, `Global`, `Local`, `Jump`, `JumpFalse`, `Return`, and
   `Apply2` for a couple of arithmetic verbs.
2. **C&P emitter** (`src/runtime/cp.zig`). Walk a `Chunk`'s basic blocks
   (`buildBlocks`), select a stencil per op, `memcpy` + apply relocations into a
   code buffer; resolve branch holes to BB addresses.
3. **JIT runner + mixed execution.** `mmap` exec, define the entry/calling
   convention, and a clean fallback to the interpreter for any op lacking a
   stencil (so the two share the value stack and can hand off mid-chunk).
4. **Call/Apply target holes** wired to the registry (§4): primitives, module
   functions, extensions — one resolution path.
5. **Fusion pass** (tier 2): detect element-wise chains; lower to scalar-stencil
   loops; generalise `fuse.reduceZip`.
6. **AOT bundle mode:** stitch at `ink bundle` time, emit an object, link it;
   build per-target stencil libs and ship them in `share/<platform>/`.
7. **Hardening:** per-arch relocation kinds (x86-64 + aarch64; Mach-O/ELF/COFF),
   RC/COW correctness across stencils, disasm/debug of stitched code, a deopt
   path.

A reasonable first milestone is steps 1–3 on aarch64-macos for a dozen opcodes,
running a scalar-heavy benchmark (e.g. the regex NFA) through the stitcher with
interpreter fallback, and measuring against the interpreter.

---

## 8. Open problems / risks

- **Register allocation across stencils.** The paper fixes a calling convention
  and threads a few values in registers; ink's "everything via the in-memory
  value stack" model sidesteps most of it but leaves performance on the table.
  The paper's *stack caching* (keep top-of-stack in a register) is the upgrade.
- **The `V` tagged union + RC/COW.** Stencils must honour refcounting and
  copy-on-write exactly as the interpreter does. The clean win (tier 2) operates
  on *unboxed* `B`/`I`/`F` element data inside the fused loop, touching no `V`
  headers — keep fusion to that sweet spot and leave boxed/general paths to
  tier 1 / the interpreter.
- **Object-format portability.** Relocation types differ across x86-64/aarch64
  and Mach-O/ELF/COFF; the extractor must handle each target it stitches for.
- **Keep the interpreter forever.** It's the correctness oracle and the
  fallback for unsupported ops/deopt. C&P augments it; it never replaces it.

---

## 9. Why this is the natural next step for ink

The interpreter (`vm.zig`), the small flat IR with a prebuilt CFG (`tape.zig`),
the type-based `dispatch`, the existing `ReduceZip` fused kernel, and — now — a
registry-by-name ABI where call targets are already late-bound holes: every
piece ink needs for copy-and-patch is in place. C&P turns "binding time is a free
variable" from a *linking* property (what the ABI redesign gave us) into a
*code-generation* one.
