Help me to better understand this paper about writing a JIT compiler, I am pretty new to this topic but would potentially like to use this technique to optimize the runtime of my k like array programming language runtime.

First of what are instruction encoding, register allocation and instruction selection?

Great question to start with — these three concepts are the heart of what a compiler back-end does, and understanding them well will make the rest of the paper click. Let me walk through each one with examples relevant to your situation (a k-like array language).
Instruction Selection
This is the problem of choosing which machine instructions to emit for a given operation in your IR (intermediate representation).
Your IR might have a high-level operation like "add two 64-bit integers." But the CPU has many possible ways to compute that:

On x86-64: ADD r1, r2 (register + register), ADD r1, [mem] (register + memory), ADD r1, 42 (register + immediate constant), LEA r3, [r1+r2] (uses the address-calculation unit but performs addition without touching flags), etc.
On AArch64: ADD x1, x2, x3, ADD x1, x2, #42, MADD (multiply-add fused), etc.

A smart instruction selector tries to pick combinations that are efficient. For example, if your IR says "load from address (base + index*8 + 16)," a good selector emits one x86 MOV r, [base + index*8 + 16] instead of three separate add/shift/load instructions, because x86 addressing modes can do the arithmetic for free.
For a k-like language, instruction selection matters a lot because array operations often have patterns like "load, multiply, accumulate" that map to fused instructions (FMA on modern CPUs), or strided memory accesses that map directly to addressing modes.
Register Allocation
CPUs have a small fixed set of registers (x86-64 has 16 general-purpose; AArch64 has 31). Your IR, in SSA form, can have unlimited "virtual" values. Register allocation is the problem of deciding which virtual values live in which physical registers at each point in the program, and what to do when you run out.
The two main subproblems:

Assignment: pick a register for each value. Two values that are "live at the same time" (both still needed) must get different registers.
Spilling: when you run out of registers, pick some value to evict to memory (the stack), then reload it later when needed.

This is genuinely hard. The classical formulation is graph coloring, which is NP-hard in general. Production compilers like LLVM use sophisticated algorithms (linear scan, greedy with live-range splitting, PBQP) that take significant time. Fast compilers like TPDE use simpler greedy local heuristics — they give up some code quality for huge compile-time wins.
For a k runtime, this matters because tight inner loops over arrays benefit enormously from keeping accumulators and pointers in registers across iterations.
Instruction Encoding
Once you've chosen the instruction and its operands, you have to write the actual bytes into memory. x86-64 instructions are variable-length (1 to 15 bytes) with a fiendishly complex encoding scheme — prefixes, opcodes, ModR/M bytes, SIB bytes, displacements, immediates. AArch64 is simpler (every instruction is exactly 4 bytes) but still has bit-field patterns to fill in.
For example, ADD rax, rbx on x86-64 encodes to the bytes 48 01 D8. The 48 is the REX prefix saying "64-bit operation," 01 is the opcode for "ADD r/m, r", and D8 is the ModR/M byte encoding the two registers.
Most compilers separate encoding from selection: the selector produces some abstract instruction object, then a later pass encodes it to bytes. TPDE merges these to save time — the instruction compiler directly calls an assembler that writes bytes immediately.
How the three normally interact
Traditionally, compilers run these as three separate passes:

Selection produces a stream of abstract machine instructions using virtual registers
Allocation assigns physical registers, inserts spills/reloads
Encoding writes the final bytes

Each pass has a global view, so it can make smart non-local decisions — e.g., the allocator can see that a value is used 50 instructions later and decide it's worth spilling now.
What makes TPDE different
The paper's key trick is doing all three in a single pass. As you compile each IR instruction in order, you immediately:

Select the machine instruction (locally, without looking ahead far)
Decide which registers it uses (greedily, spilling if needed)
Write the bytes to memory right then

This is much faster (no separate IR-in-memory between passes, no second traversal), but you lose the ability to make global decisions. Once bytes are written, you can't easily change them. The paper's section 2 ("Challenges of Single-Pass Compilation") is exactly about the tradeoffs this creates — for instance, the register allocator can't know how many registers will be needed later, so it has to make locally greedy choices.
For your k-like language
A few thoughts on relevance:

Array languages typically have fewer, larger operations than C-like IRs (a single "add two vectors" rather than a loop of scalar adds). Your "instructions" might be calls to runtime routines or generated loop kernels, which changes the selection problem significantly — often you just need to emit a call or paste in a small kernel.
Register allocation matters most for scalar glue code between array operations, and for keeping loop induction variables / accumulators hot.
The paper's snippet encoder idea (section 4 — write semantics in C, extract machine code from LLVM's Machine IR) might be very useful for you: you could write your array primitives in C and have TPDE-style snippets generated.

Want me to go deeper on any of these, or move on to how TPDE's two-pass architecture (analysis + codegen) actually works? The liveness analysis part is probably the next thing to understand.You said: Ok, I understand what is next?Ok, I understand what is next?19:14Claude responded: Good — let's look at TPDE's overall architecture next, then drill into the analysis pass.Good — let's look at TPDE's overall architecture next, then drill into the analysis pass. This is sections 3.1 through 3.3 of the paper.
The big picture: two passes
Despite the title saying "single-pass code generation," TPDE actually does two passes over your IR:

Analysis pass — figures out things you need to know before generating code (liveness, loop structure, block ordering)
Code generation pass — does instruction selection + register allocation + encoding all together, in one linear walk

The "single-pass" claim refers specifically to the code generation step. The analysis pass is cheap and produces information that makes the code gen pass produce much better code without slowing it down much.
Why you need the analysis pass at all
Imagine you're generating code linearly and you hit this IR:
%a = load %ptr
%b = add %a, 1
%c = mul %a, 2
%d = add %b, %c
return %d
When you compile %b = add %a, 1, you need to know: is %a still going to be used afterwards? If yes, you must preserve it. If no, you can clobber its register.
In this case %a is used again by %c, so you can't clobber it. But for %c = mul %a, 2, that's the last use of %a, so its register becomes free.
Without this knowledge, a single-pass compiler would have to be pessimistic — always preserve everything, generating tons of unnecessary copies. That's exactly why the copy-and-patch compiler in the benchmarks produces 4x larger code and runs 2.4x slower than TPDE.
So the analysis pass computes liveness: for each value, when does it stop being needed?
What liveness actually means
A value is "live" at a program point if it might be read later. Once it's no longer live (dead), its register can be reused.
Classical liveness analysis is iterative: you walk the control-flow graph repeatedly until information stops changing. This can be slow for large functions. TPDE uses a clever algorithm by Kohn et al. that runs in linear time by exploiting loop structure — which is why TPDE also has to do a loop analysis first.
The key insight: in straight-line code, a value's live range is just "from definition to last use." But with loops, a value defined before a loop and used inside the loop must stay live for the entire loop, even if its last syntactic use is at the top. So you need to know where loops are.
Block ordering
Here's another thing the analysis pass does that's easy to miss but important. When you have branches, you must decide what order to emit basic blocks in the final code. TPDE uses reverse post-order with loops kept together.
Why does this matter for a single-pass compiler? Two reasons:
Reason 1: Forward references are cheap, backward references aren't. If block B branches to block A, and you've already emitted A, you know A's address — easy. If you haven't emitted A yet, you write a placeholder and patch it later — also fine, but you need to track these "fixups." Reverse post-order minimizes the number of forward references in straight-line regions.
Reason 2: Live ranges become contiguous. TPDE represents liveness very compactly as just "start block number, end block number." This only works if blocks are numbered such that a value defined in block N is used in blocks N, N+1, N+2, ... up to its last use. RPO gives you this property for non-loop code; keeping loops together extends it.
For a k-like language: if your runtime currently has loops over arrays, the loop body becomes a basic block (or several), and your loop header (where the induction variable lives) becomes a phi-node block. The "keep loops together" rule means the loop body gets compiled in sequence, which keeps the induction variable's register hot.
The actual steps of the analysis pass
From section 3.3, the analysis pass does this in order:

Number blocks temporarily so the loop analysis can store per-block data in an array (faster than a hashmap)
Find loops using Wei et al.'s algorithm, which handles even weird "irreducible" loops (loops with multiple entry points — rare in source code but they happen)
Compute final block layout in reverse post-order, keeping loops contiguous, and renumber blocks to this layout
Compute liveness using Kohn et al.'s algorithm, also counting how many times each value is used

The output is, for every IR value: a live range [start_block, end_block], a flag for "does it die in the middle of end_block or at the very end," and a use count.
How the code gen pass uses this
During code generation, TPDE tracks a remaining use count for each value. Every time the value is used, the count decreases. When it hits zero and the live range ends in the current block, the value is dead — its register is freed immediately.
If the count hits zero but the live range continues past this block (because of a backedge in a loop), the value must stay live. This is the loop-induction-variable case: the value isn't textually used again until next iteration, but its register must be preserved.
This is a really nice piece of engineering. It's coarse-grained (block-level resolution, not instruction-level), but combined with the use counter, it gives you instruction-level precision within a block while only requiring block-level data structures.
For your k-like runtime
A few things worth thinking about:

If your IR is small and mostly linear (typical for array language kernels — load, op, op, op, store), the analysis pass will be very fast. Liveness in straight-line code is trivial.
If you compile expressions to SSA directly (rather than going through a stack-machine bytecode first), most values will have short live ranges with few users — TPDE's coarse-grained liveness will be plenty.
The "keep loops together" layout matters most if you have nested loops, which array languages often do (e.g., matrix operations).

Want to continue to the code generation pass next? That's section 3.4 and it's where things get concrete — value assignments, how registers are tracked, how the prologue/epilogue work, instruction fusion. Or if anything above is unclear, ask and I'll unpack it.You said: Ok, continue explaining the next sectionOk, continue explaining the next section19:18Claude responded: Now we get into the meat of how TPDE actually generates code.Now we get into the meat of how TPDE actually generates code. This is section 3.4 — the code generation pass.
The core data structure: value assignments
For every live IR value, TPDE keeps a small struct called an assignment in an array indexed by the value's number. This is the bookkeeping that tracks "where is this value right now?"
An assignment contains:

A stack slot reserved for spilling (allocated lazily when first needed)
The in-memory size
The remaining use count (decremented as the value is consumed)
For each "part" of the value: which register it's currently in (if any), its size, and whether the stack slot has an up-to-date copy

That last flag is important. If a value is in a register and also has a fresh copy in its stack slot, evicting the register is free — just drop it. But if the register holds the only copy, eviction means actually writing to the stack first.
The data structure is tightly packed: 16 bytes for a single-part value. With potentially tens of thousands of values, that size matters for cache behavior.
Two special flags are worth knowing about:

Trivially recomputable: for values like "address of a stack variable," no spilling is needed — if evicted, just recompute from frame pointer + offset on demand. Saves a stack slot and the spill instruction.
Locked: prevents eviction while the value is being actively used by an instruction. Without this, you could load a value into a register for use as an operand, then have that register stolen by the very same instruction's allocation of another operand.

Multi-part values
This is a slightly unusual design choice. An IR value isn't necessarily one thing in one register — it can be multiple "parts," each independently register-allocated.
Why? Because real IRs have:

128-bit integers (need two 64-bit registers on most architectures)
Struct or array values (LLVM allows these; each field is a part)
Multi-result instructions (some IRs let one instruction produce multiple values)

By treating everything as a list of parts, TPDE handles all these cases with one mechanism. A normal 64-bit integer is just a "value with one part." For your k-like language, this is relevant if you have boxed values like (type_tag, pointer) pairs — those can be naturally modeled as two-part values.
The prologue problem
A function prologue (the code at the start) needs to:

Save callee-saved registers
Set up the frame pointer
Allocate the stack frame

But at the moment the prologue is emitted — right at the start — TPDE doesn't yet know:

How many callee-saved registers it'll need to save (depends on register allocation, which hasn't happened)
How big the stack frame is (depends on how many spill slots are needed)

The solution is elegant: emit a maximally pessimistic prologue with space reserved for saving all possible callee-saved registers, then patch it at the end of compilation. Unused space gets padded with no-ops.
This is one of those things that sounds wasteful but is actually fine. The wasted prologue bytes are tiny compared to function bodies, and the patching is one quick pass at the end.
The frame pointer (rather than stack pointer) is always used for addressing stack slots. This costs one extra register but means stack slot addresses don't shift around as you push/pop things during the function — vastly simplifying things in a single-pass compiler.
The instruction compilation protocol
This is the key abstraction. When TPDE wants to compile an IR instruction, it calls your instruction compiler. Your job is to:

Get handles to the operand values — TPDE returns a ValuePartRef for each operand part. Holding a handle locks the value's register so it can't be evicted.
Force operands into registers — call something like val_as_reg(ref). If the value is spilled, this reloads it. If you need the value in a specific register (e.g., x86-64 division requires the dividend in rax), you pass a register constraint.
Allocate result registers — get handles for the values your instruction will produce. Helpfully, TPDE provides result_ref_will_overwrite() which tries to reuse an operand's register if that operand is at its last use; otherwise it generates a copy. This is crucial for x86-64 where ADD rax, rbx overwrites rax.
Emit the machine code — actually write the instruction bytes. If you need temporary registers for intermediate computations, TPDE provides "scratch registers" that are guaranteed not to get evicted.
Tell TPDE where the result ended up — call set_value() so it updates the assignment.

Listing 1 in the paper shows exactly this pattern for x86-64 ADD. Read it again now — it should make sense:
cppValuePartRef lhs_ref = val_ref(inst->getOperand(0), 0);
ValuePartRef rhs_ref = val_ref(inst->getOperand(1), 0);
ValuePartRef res_ref = result_ref_will_overwrite(inst, 0, std::move(lhs_ref));
AsmReg rhs_reg = val_as_reg(rhs_ref);
ASM(ADD64rr, res_ref.cur_reg(), rhs_reg);
set_value(res_ref, res_ref.cur_reg());
Read top to bottom: grab both operands, ask for a result register that can clobber lhs, ensure rhs is in a register, emit the ADD, register the result. Notice TPDE handles the mechanism (which register to pick, whether to copy lhs first); you provide the semantics (it's an addition, use the ADD instruction).
For your k-like language, you'd write one of these for each operation in your IR. add_vector, index_into_array, apply_dyadic, whatever your primitives are.
Instruction fusion
This is where some of the "smart" instruction selection lives. The paper's example: comparison followed by conditional branch.
In LLVM-IR you have:
%cmp = icmp slt %a, %b
br %cmp, %then_block, %else_block
If you compile these separately, you'd emit CMP then SETcc to produce a 0/1 in a register, then TEST + JMP. But the better code is CMP then Jcc directly using the flags.
TPDE handles this with fusion: when compiling the icmp, the instruction compiler can detect that the only user is the branch in the same block, and choose to emit the combined CMP + Jcc sequence, marking the icmp as fused so no register is allocated for it.
The constraint is that fusion only looks at later instructions (because earlier ones are already emitted). It's also constrained to the same basic block (because crossing blocks requires more bookkeeping). Both these limits are exactly what a single-pass design imposes.
For your language, fusion opportunities probably include:

Loading an array element address and immediately dereferencing it
Generating a constant and immediately using it as an immediate operand
Type-tag check followed by a conditional dispatch
Bounds check followed by an indexed load

Register allocation in detail
Section 3.4.5 lays out the actual register allocation policy. It's deliberately simple:

When a register is needed and one is free: pick the one with the lowest number. (Arbitrary, but deterministic and cache-friendly.)
When all registers are busy: evict one in round-robin order. The evicted value gets spilled to its stack slot if not already there.
Locked registers (currently held by handles or scratch): never evicted.

There's one non-trivial optimization: fixed registers for loop-carried values. If a value is used across multiple blocks inside the innermost loop, it gets pinned to a callee-saved register that the allocator won't touch. This targets phi-nodes in loop headers — almost always loop induction variables and accumulators. Without this, naive round-robin eviction could thrash the loop's hot values.
For an array language, this is exactly what you want. The classic k-style "sum the array" inner loop has an accumulator phi-node that must absolutely stay in a register across iterations, and TPDE's heuristic correctly identifies and pins it.
Cross-block register state
Here's a subtle and important design choice. Tracking the exact register state at every block entry would require complex merging logic at join points (where multiple predecessors meet). Single-pass compilers can't easily do this.
TPDE's solution: at any block boundary that's a merge point (multiple predecessors, or a non-fallthrough successor), spill everything that's live. Every live value goes to its stack slot, and on entry to the merge block, values are in well-known locations (either stack slot or fixed register, nothing else).
This is the main code-quality cost of the single-pass approach. After every join, you're reloading from the stack. But it's tractable: the spilling is deterministic, no per-block state needs to be tracked, and the loads are fast on modern hardware.
Phi-node resolution happens at the end of the predecessor block, right before the branch: move values to where the phi expects them. Critical edges (where this would be ambiguous) are split by inserting a small fixup block.
Putting it together
So here's what compiling a function actually looks like, end to end:

Analysis pass runs: liveness, loops, block layout
Prologue is emitted with maximum-pessimistic space
For each block in layout order:

For each instruction, call the instruction compiler, which uses the value-handle protocol to allocate registers and emit bytes
At block end: spill live values if next block is a merge, resolve phi-nodes, emit branch


Patch up prologue with actual frame size and callee-saved register list
Write exception unwind info

That's the whole code generation pass. The IR-specific parts (instruction compilers) plug in via the value-handle protocol; everything else is reusable framework code.
For your k-like runtime
A few practical thoughts:

Your IR design matters a lot. TPDE assumes SSA form. If your runtime currently uses a tree-walking interpreter or stack-machine bytecode, you'd need to build an SSA IR first. The good news is the paper notes this construction can be cheap if you're not converting from imperative code — from k expressions it's pretty direct.
Multi-part values are useful for boxed/tagged representations. A k value with (type, length, pointer) could be a three-part value.
Fusion is your friend for tag-dispatched operations. A typeof + conditional in your IR can fuse into a single test+branch.
The result_ref_will_overwrite pattern maps naturally to the fact that most array operations are in-place when possible.

Next up, if you want, is section 4 — the snippet encoder approach, which is the other big contribution. It's how TPDE avoids hand-writing assembly for every IR operation on every architecture. This is probably the part most directly relevant to you, since you'd otherwise face the prospect of hand-writing x86-64 and AArch64 code for every k primitive. Want to go there?You said: Yes explain snippets, is this different from the templates in the copy and patch paper?Yes explain snippets, is this different from the templates in the copy and patch paper?23:00Claude responded: Great question — yes, snippets and copy-and-patch templates look similar from a distance (both pre-compile small chunks of machine code from a high-level langu…Great question — yes, snippets and copy-and-patch templates look similar from a distance (both pre-compile small chunks of machine code from a high-level language), but they're solving the problem differently and the differences are exactly why TPDE produces much better code. Let me build up to the comparison.
The problem snippets solve
Look back at Listing 1 in the paper — the hand-written x86-64 ADD compiler. It works, but think about what writing a real compiler involves:

Hundreds of IR operations, each needing an instruction compiler
Each one has to know the exact target instruction mnemonics
Different operand types (register/immediate/memory) may need different instruction encodings
And you do it all again from scratch for AArch64

The previous TPDE implementation, without snippets, was 12.8k lines of code, 11.6k of which were target-specific. With snippets, it's 7.5k lines, only 1.7k target-specific. That's a huge reduction.
The goal of snippets: write the semantics of an IR operation once, in a high-level language like C, and have the compiler automatically generate code that emits the right machine instructions at runtime.
How snippet extraction works
Look at Figure 3 in the paper. The flow is:

You write a C function expressing the semantics:

c   uint32_t muli32(uint32_t a, uint32_t b) { return a * b; }

Clang compiles it through normal LLVM all the way to Machine IR (MIR) — the late-stage representation right before LLVM would write bytes. At this point, every instruction is a real target instruction with real physical registers chosen by LLVM's register allocator:

   $w0 = MADDWrrr killed $w1, killed $w0, $wzr
   RET undef $lr, implicit killed $w0

A tool processes this MIR and generates a C++ function — the snippet encoder — that, when called at compile time, will emit those instructions but with your runtime's registers substituted in.

The output (Figure 3c) is roughly: "ensure both operands are in registers (reuse if possible), allocate a result register, call the assembler with MADDw, release operands."
When TPDE compiles a multiply IR instruction, your instruction compiler just calls encode_muli32(lhs, rhs, result) and TPDE figures out registers and emits the machine code dynamically.
What MIR gives you that raw bytes don't
This is the key technical point. LLVM's Machine IR is rich with information:

Which registers are inputs vs outputs for each instruction
Register constraints (this operand must be in rax, etc.)
"Killed" markers — LLVM knows when a register's value is no longer needed
Data flow between instructions within the snippet
Constant pool references and relocations

Because the snippet generator can see all this, it can produce a parameterized encoder rather than a fixed byte sequence. When you call the encoder, it dynamically decides:

Which physical register to use for each role
Whether an operand can be reused for a result (the killed markers tell it which operands LLVM considered dead after use)
Whether to fold a constant into an immediate field
Whether to use a complex addressing mode

This is fundamentally different from copy-and-patch.
Now: copy-and-patch
Copy-and-patch (the Xu & Kjolstad paper, used by Python 3.13's JIT and Drescher's MLIR work) pre-compiles templates the same way — C code → LLVM → machine code. But it stops at machine code bytes, not Machine IR.
A copy-and-patch template is literally a binary blob: maybe 50 bytes of x86-64 instructions, with a few "patch points" marked via relocations where constants need to be filled in at runtime.
To compile an IR instruction, copy-and-patch:

Looks up the template for that operation
memcpys its bytes into the output buffer
Patches in any runtime constants (immediate values, jump targets)

That's it. Extremely fast — almost no work at compile time. This is why copy-and-patch beats TPDE on compile-time speed (18.6x vs 12.15x faster than LLVM -O0 on x86-64).
Why copy-and-patch produces bad code
But look at run-time performance: TPDE is on par with LLVM -O0, while copy-and-patch is 2.38x slower. That's a huge gap. Why?
Because once the template is compiled to bytes, the register assignments are frozen. The template might say add rax, rbx → rax. So:

Every operand of every operation has to land in the specific registers the template expects
Between every two operations, you need MOV instructions to shuffle values into the right registers
The template can't take advantage of the fact that an operand is, say, a small constant — you have to materialize the constant into a register first
The template can't use complex addressing modes — the address has to be in the exact register the template wants
There's no liveness analysis, so values get moved/spilled even when they didn't need to be

The paper's section 8 puts it bluntly: copy-and-patch produces "frequent register moves and stack spills/reloads, causing a substantial slowdown." It's also why copy-and-patch generates code that's 4.44x larger than LLVM -O0 — all those move instructions add up.
You could compile multiple variants of each template (one for each register assignment, one for each constant size, etc.) but the combinatorial explosion is brutal — you'd need thousands of variants per operation.
The TPDE snippet approach is different
Snippet encoders are not binary blobs. They are code that emits binary blobs, parameterized at the level the MIR understood: registers, immediates, addressing modes.
When TPDE calls a snippet encoder at compile time, the encoder looks at the actual operands you passed (which might be in any register, or might be a constant, or might be a stack slot reference), and dynamically morphs the instruction sequence to fit. If your left-hand operand happens to be a constant that fits in an immediate field, the encoder can fold it in and emit a shorter instruction. If your right-hand operand is at its last use, the encoder reuses its register for the result, skipping a move.
This is what sections 4.2 and 4.3 are about:

Section 4.2 (non-register operands): if an operand is a constant, try encoding it as an immediate. If it's an expression like base + index*scale + offset, try folding it into a memory addressing mode. This is huge for stack variable access — instead of "compute address, then load," you get one instruction that does both.
Section 4.3 (omitting register moves): LLVM-compiled snippets often contain moves to satisfy the calling convention. The snippet encoder recognizes these and replaces them with register aliasing — pretending the destination is just another name for the source, without emitting any move at all.

So you get the convenience of writing semantics in C (like copy-and-patch) plus the code quality of a real register allocator (because the snippet encoder is doing local register allocation at compile time, guided by MIR metadata).
A concrete example of the difference
Consider the IR operation "add a constant 5 to a value." On x86-64:
Copy-and-patch: Has a template like ADD rax, rcx. To use it, must:

Move your operand into rax (one MOV)
Materialize 5 into rcx (one MOV with immediate)
Copy the template bytes
Move rax to wherever the result needs to go (one MOV)

Roughly 4 instructions for what should be 1.
TPDE snippet: The snippet encoder sees that the right operand is a small constant. It chooses the immediate-form encoding directly:

ADD reg, 5 where reg is whichever register already holds the value

One instruction. And if the value's register is going to be overwritten anyway (it's at its last use), no moves at all.
The discussion section (4.4) is worth reading
It covers some interesting choices:

Which MIR stage? They originally used pre-register-allocation MIR but found it too complex. Late-stage MIR (post-register-allocation) is simpler because LLVM has already lowered pseudo-instructions and chosen physical registers — they just remap those physical registers to TPDE's allocation.
Writing optimizable snippets: Sometimes constant inputs reveal optimizations that aren't expressible in the generic snippet (Figure 4 shows a 128-bit shift where a constant shift amount could produce much better code). The fix is to write multiple snippets — one generic, one specialized for small constants, etc. — and have the instruction compiler pick based on operand properties.
Functions with control flow: Some operations (like unsigned-int-to-float on x86) require branching. Snippets can include multiple basic blocks; the snippet encoder reproduces the same control flow in the generated code, just with possibly different registers.
What snippets can't do: Function calls (would need a stack frame), indirect jumps, anything that uses the frame/stack pointer. These get hand-written instead, but the set of such cases is small.

The portability win
This is maybe the biggest practical benefit. Adding AArch64 support to TPDE was "merely a matter of days" because most instruction compilers didn't need to be rewritten — the same C snippets compile to AArch64 MIR, which produces AArch64 snippet encoders.
You write the snippet generator infrastructure once per architecture (mapping LLVM mnemonics to your assembler, describing encoding-specific optimizations), but the IR semantics — the actual operations of your language — are architecture-independent.
For your k-like language: if you've ever thought "I'd love to support both my Mac and my Linux box but writing two code generators is too much work," this is the answer.
For your k-like runtime: should you use snippets?
A few thoughts:

Snippets are especially nice when your operations have non-trivial semantics. Your add_i64 is trivial to hand-write, but something like parse_number_from_string or transpose_matrix_2d would be tedious to express in raw assembly across two architectures.
If your runtime already has these primitives written in C (which it probably does), snippet extraction lets you reuse them rather than reimplementing them as machine code generators.
The infrastructure cost is real, though. You need a tool that runs Clang/LLVM, walks Machine IR, and generates C++ encoder functions. The TPDE authors built this; if you adopt TPDE you get it for free, but if you're rolling your own thing, that's a meaningful chunk of code.
An interesting hybrid for k: many k primitives are best expressed not as inline machine code but as runtime calls to vectorized C functions. For those, you don't need snippets at all — you just emit a CALL instruction. Snippets help most for the scalar glue code: index computation, type dispatch, loop induction, simple arithmetic.

So the answer to "is this different from copy-and-patch?" is yes, substantially: snippets are parameterized encoders rather than frozen bytes, which is why they produce ~2.4x faster generated code while still being almost as fast to compile.
Next reasonable step: section 5, where they actually build the LLVM-IR back-end and benchmark it on SPEC. That's where you see the engineering effort and performance results in detail. Or if you want to skip ahead to the WebAssembly or Umbra case studies (which are closer in spirit to JIT compilation for your language), we can do that. Which would you prefer?You said: explain LLVM-IR back-end and benchmark it on SPEC then explain the umbra case study.explain LLVM-IR back-end and benchmark it on SPEC then explain the umbra case study. Also explain the spec benchmark23:05Claude responded: Good plan.Good plan. Let me first explain what SPEC is, then walk through the LLVM-IR back-end and its results, then the Umbra case study.
What is SPEC CPU2017?
SPEC (Standard Performance Evaluation Corporation) is a non-profit consortium that publishes industry-standard benchmark suites. SPEC CPU2017 is their benchmark for evaluating CPU and compiler performance — it's basically the canonical benchmark suite that compiler papers use to demonstrate they're not cheating with cherry-picked microbenchmarks.
SPEC CPU2017 contains real-world programs, not synthetic loops. The "integer" subset (SPECint 2017, which TPDE uses) includes:

600.perl — the Perl interpreter
602.gcc — a version of the GCC compiler itself
605.mcf — a transportation scheduling solver using network simplex
620.omnetpp — a discrete event network simulator (C++)
623.xalanc — an XSLT processor (C++)
625.x264 — the x264 video encoder
631.deepsjeng — a chess engine
641.leela — a Go-playing engine
657.xz — the xz compression utility

These programs are large (gcc is hundreds of thousands of lines), cover diverse workloads, and exercise lots of language features and compiler behaviors. A compiler that does well on SPEC has to handle real production code, not just toy examples.
There are two ways to use SPEC for compiler research:

Measuring runtime of compiled binaries — does the compiler produce fast code?
Measuring compile time — how long does the compiler take to process all this code?

TPDE measures both, since the whole point is "fast compilation with reasonable code quality."
"Geomean" in the charts means geometric mean across all benchmarks — the standard way to summarize relative speedups (arithmetic mean would over-weight benchmarks with huge ratios).
Building the LLVM-IR back-end
Now to section 5. The case study is: use TPDE to build a fast compiler for LLVM-IR itself. This is significant because LLVM-IR is the lingua franca of modern compilation. Clang produces it from C/C++, Rust produces it, lots of JIT systems produce it. If you can compile LLVM-IR fast, you make all those systems faster.
Importantly: this new back-end doesn't use LLVM's existing code generation at all. It only uses LLVM as a library for parsing and representing the IR. Code generation is 100% TPDE.
The scope is intentionally limited to unoptimized code patterns — what Clang produces with -O0. So they skip:

Vectors (SIMD types)
Integers larger than 128 bits
Floating-point types other than float/double
Inline assembly
Garbage collection support, computed gotos, other rare features

This is the right scope for a baseline JIT. Optimized code uses these features, but if you're compiling fast for quick startup, you're compiling unoptimized code.
The IR adapter implementation
Recall from section 3 that you need to write an "IR adapter" — the bridge between TPDE's framework and whatever your IR happens to be. For LLVM-IR, this is mostly straightforward because LLVM exposes everything you need. But there's a preparation pass that runs before TPDE's analysis pass:

Number all values, blocks, and globals. TPDE wants integer indices into arrays, but LLVM uses pointers and names. The preparation pass walks the function and assigns sequential numbers, storing the mapping in an array for later lookup.
Convert constant expressions to instructions. LLVM has a weird feature where constants can be arbitrary expressions like getelementptr (i32, ptr @global, i32 5). These can appear inline anywhere a value can appear, including inside phi nodes. To avoid handling them in every instruction compiler, the preparation pass extracts them into explicit instructions.
Rewrite thread-local accesses. LLVM lets you reference a thread-local variable directly as a value. But on most platforms, getting a thread-local's address requires an actual function call (depending on the ABI). Rather than handle this magic in every instruction that touches a value, the prep pass rewrites these accesses to use an explicit llvm.threadlocal.address intrinsic call. Now every thread-local access is a normal call instruction.

This is a recurring pattern when adapting an existing IR: do a small preprocessing pass to canonicalize awkward constructs, then your main code generation is uniform.
Compilation strategy
Most LLVM-IR instructions are implemented with snippet encoders — the C-based instruction snippets from section 4. So most of the back-end is architecture-independent.
The exceptions are:

Calls and returns — need to handle the calling convention (which registers hold which arguments, etc.), which is platform-specific
Branches — snippets can't currently express control flow to arbitrary basic blocks
Integer comparisons — written architecture-specific because they're usually fused with branches, and the fusion logic needs to know the architecture's compare-and-branch instruction
Target/ABI-specific intrinsics — things like varargs access

The integer-comparison-fusion point is worth highlighting. In LLVM-IR you typically see:
%cmp = icmp slt %a, %b
br i1 %cmp, label %then, label %else
The naive approach generates a CMP instruction that sets flags, then a SETcc instruction to materialize the boolean into a register, then a TEST + Jcc on that register. The good approach is CMP followed directly by Jcc using the flags from the compare. This is exactly the fusion mechanism from section 3.4.4 — when compiling the icmp, the compiler checks whether its only use is the immediately-following branch, and if so, fuses them.
Code size and complexity
7.5k lines total. Only 1.7k are architecture-specific for x86-64 and AArch64 combined. Compare to the previous version without snippets: 12.8k lines, 11.6k target-specific. The snippet approach roughly halved the total code and cut target-specific code by 85%.
Adding AArch64 support took "merely a matter of days." That's the headline number for portability.
SPEC benchmark results: compile-time
Figure 5a shows compile-time speedup over LLVM -O0 when compiling unoptimized LLVM-IR.
The geomean numbers:

x86-64: 12.15x faster than LLVM -O0
AArch64: 18.96x faster than LLVM -O0

Why is AArch64 better? Because LLVM uses a different instruction selector on AArch64 by default — GlobalISel — which is more flexible but slower than the x86-64 default FastISel. So LLVM is slower on AArch64 in absolute terms, making TPDE's relative speedup larger. TPDE doesn't have this asymmetry — it's about equally fast on both architectures.
Some benchmarks (gcc, omnetpp, xalanc — the C++ ones) hit nearly 30x speedup. C++ code generates lots of small inline functions and template instantiations, which LLVM's pipeline handles less efficiently. TPDE's single-pass approach scales linearly with code volume.
Copy-and-patch is still faster (18.6x geomean on x86-64 — faster than TPDE). This is honest of the authors to report. Copy-and-patch wins on compile time because it does essentially zero work per IR instruction — just memcpy a template. But:
SPEC benchmark results: run-time
Figure 5b shows runtime of the generated code relative to LLVM -O0.

TPDE: within ±9% of LLVM -O0 performance — basically on par.
Copy-and-patch: 2.38x slower on geomean.

This is the killer comparison. Copy-and-patch compiles faster, but its output runs 2.38x slower. In any scenario where the code is going to run for more than a tiny moment, you'd rather use TPDE.
Figure 6 shows the time distribution within compilation:

2% of total compilation time is spent in TPDE itself
98% is in the front-end (Clang parsing C++) and LLVM IR setup
End-to-end Clang compilation is 17% faster on average just by swapping out the back-end

Within TPDE specifically:

49% code generation
14% LLVM preparation pass (the slowness here is mostly LLVM's own data structure overhead)
12% analysis pass
The rest is misc

Code size: a trade-off
Figure 7 shows that TPDE-generated code is 43–49% larger than LLVM -O0 code. This is the cost of single-pass compilation. The main culprits:

Pessimistic prologues/epilogues — always reserve space for saving all callee-saved registers, even unused ones
Spilling at merge points — values get reloaded after every join, generating extra instructions
Weak symbols instead of comdat sections — duplicate inline functions don't get linker-deduplicated
No instruction-combining — the single-pass approach can't merge multiple IR instructions into one machine instruction in many cases

For comparison, copy-and-patch generates 4.44x larger code. So TPDE's overhead is significant but bounded.
Optimized IR results
Figure 8 covers running TPDE on -O1-optimized LLVM-IR (variables in SSA form, fewer redundancies). Interesting findings:

Compile-time speedup vs LLVM -O1 is now 80-85x (because LLVM -O1 is much slower than -O0)
Generated code runs 5-11% faster than LLVM -O0 code (the input IR is better, so the output is too)
But code is 1.54-1.77x slower than LLVM -O1 output (because LLVM's full pipeline does much better instruction selection and register allocation)

So TPDE benefits from getting better input IR, but it can't match an optimizing back-end. That's expected and fine — TPDE's job is fast baseline compilation, not optimization.
The Umbra case study
Now section 7. This one is more directly relevant to your situation — adapting TPDE to a custom domain-specific IR for a runtime system.
What is Umbra?
Umbra is a research database system from TUM (same group as the TPDE authors) that compiles SQL queries to machine code rather than interpreting them. The lineage here is HyPer and Umbra, two systems that pioneered JIT compilation of database queries. The performance argument: interpretation is too slow for analytical SQL queries; an optimizing compiler is also too slow because the compile time itself becomes the query latency.
So Umbra has multiple compilation back-ends:

LLVM optimized — for long-running queries where compile time amortizes
LLVM -O0 — for medium queries
DirectEmit — a hand-written custom back-end optimized for fastest possible compilation while still producing decent code

DirectEmit is fast. It compiles Umbra IR directly to machine code in two passes without any IR translation. It's described in [20] (Kersten et al., "Tidy Tuples and Flying Start"). The price is complexity: 11k lines of code, mostly architecture-specific, with code largely duplicated between x86-64 and AArch64 ports.
Umbra IR
Umbra has its own SSA IR designed for database query compilation. It's roughly LLVM-IR-shaped but:

Restricted type set: 8/16/32/64/128-bit integers, pointers, double, and data128 (a 16-byte value often used for strings)
Special instructions for common DB operations, like ssubtrap — a signed subtract that calls a trap function on overflow and otherwise returns the result
Designed for fast iteration with dense data structures and cache-friendly layout

The dense layout is important for fast compilation: instructions are stored in arrays with stable integer IDs, not linked structures with pointers.
The TPDE Umbra back-end
The IR adapter is easier to write than the LLVM one because Umbra IR is already designed for compilation speed. Specifically:

Umbra already has per-function unique IDs for instructions and blocks — TPDE can use these directly as value/block references with zero overhead
No preparation pass needed — all instructions map cleanly to TPDE's model
Global value numbering can be done lazily during code generation

So the boilerplate that took space in the LLVM adapter (numbering, constexpr lowering, thread-local rewriting) just isn't there.
For instruction compilation: many Umbra IR instructions are semantically similar to LLVM instructions, so they reuse the LLVM back-end's snippets. The simpler type system makes implementations simpler — fewer cases to handle.
One nice JIT-specific optimization: in Umbra (and any JIT scenario), the addresses of runtime functions and global variables are known at compile time. So instead of generating relocations and patching them later, the compiler can hardcode addresses directly into the generated code. Faster compilation, smaller code.
Code complexity: 3.6k lines total, 1.6k architecture-specific. Compare to DirectEmit at 11k lines almost entirely target-specific. That's roughly a 3x reduction in total code and even more in maintenance burden because the architecture-specific parts are smaller.
Benchmark: TPC-DS
TPC-DS is the Transaction Processing Performance Council's "Decision Support" benchmark — the SQL equivalent of SPEC CPU. It models a retail data warehouse with complex analytical queries (joins, aggregations, window functions). "Scale factor 1" means 1GB of test data. There are 99 standard queries covering various analytical workloads.
The point of TPC-DS for compilation research: real, varied SQL queries that exercise different codegen patterns.
Results
Figure 10 shows accumulated compile-time and run-time over all TPC-DS queries:
Back-endx86-64 compilex86-64 runAArch64 compileAArch64 runLLVM optimized16.193s0.615s7.341s0.936sLLVM -O02.504s0.650s1.187s1.209sTPDE-LLVM0.290s0.651s0.196s1.069sDirectEmit0.110s0.644s0.069s1.024sTPDE (native)0.087s0.652s0.067s1.055s
Key observations:
TPDE matches DirectEmit on compile time. 0.087s vs 0.110s on x86-64 — TPDE is actually slightly faster than the specialized hand-written back-end. This is remarkable: a general-purpose framework matched a system specifically engineered for one IR with custom assembly emission.
Run-time is also comparable: 0.652s vs 0.644s on x86-64. Within 1%.
The TPDE-LLVM back-end is much slower than native-TPDE for Umbra: 0.290s vs 0.087s. Why? Because using the LLVM back-end requires translating Umbra IR to LLVM-IR first. That translation step is pure overhead that's avoided when TPDE adapts directly to Umbra IR.
This is exactly the argument the paper makes for the framework's design. If you have your own IR (like Umbra's, or like your k runtime would have), you don't want to translate to LLVM-IR just to use a fast back-end. The IR translation can dominate compile time. By making TPDE adaptable to any SSA IR, you avoid this entirely.
AArch64 run-time anomaly: TPDE-LLVM is faster than LLVM -O0 on AArch64 (1.069s vs 1.209s). The paper attributes this to TPDE generating better instruction sequences for complex Umbra IR operations. When going through LLVM, those complex operations get decomposed into many simpler LLVM-IR instructions that LLVM -O0 doesn't fuse back together. By having an instruction compiler that directly handles the high-level Umbra operation, TPDE can emit better code.
Discussion
The Umbra case study is the strongest demonstration of TPDE's value proposition. It shows you can:

Take an existing custom IR
Write a relatively small adapter and instruction compilers (3.6k lines vs 11k for the bespoke back-end)
Match the bespoke back-end's compile time
Match its run-time performance
Get cross-architecture support nearly for free
Skip the IR translation overhead that would come from using a general framework like LLVM

This is the path forward for systems that currently maintain their own JIT back-ends.
What this means for your k-like runtime
A few takeaways:

You probably want your own IR, not LLVM-IR. The Umbra case study shows the win from adapting TPDE directly to your IR vs translating to LLVM-IR first is large — 3.3x on compile time. For a JIT, that's the difference between "feels instant" and "noticeable pause."
Your IR can be tailored to k semantics. Domain-specific instructions like Umbra's ssubtrap are a good model. Things like vector_index_with_bounds_check, apply_dyadic_to_arrays, replicate_atom_to_length could be first-class IR operations rather than expanded sequences. The instruction compiler for each one can pick the best machine code sequence and fuse with surrounding operations.
SSA form is the entry ticket. This is the main constraint. If your IR is tree-shaped expressions or stack-machine bytecode, you'd need to lift to SSA first. For an array language, this lifting is usually cheap because k expressions are themselves SSA-like — most values are immutable intermediates.
The snippet approach amortizes well if you plan to write many primitives. The infrastructure pays back as you add more operations.
For the array-operation hot paths, you probably don't even need snippets. A k inner loop like +/x is probably best implemented as a call into a vectorized C library function. TPDE handles call instruction emission for you. Snippets help most for scalar glue code: indexing, conditionals, type tags, loop bounds.

Section 6 (WebAssembly via Cranelift) is also interesting if you want to see another adaptation example — it has more emphasis on JIT integration and the difficulty of adapting to a third-party IR with block arguments rather than phi nodes. But the LLVM and Umbra cases probably tell you what you need.
Want to dig into anything specific — maybe how you'd actually design an SSA IR for k, or the mechanics of integrating TPDE as a JIT?You said: How can I use the TPDE as a JIT, how does the snippet fit into the build pipeline, what does TPDE even stand for?How can I use the TPDE as a JIT, how does the snippet fit into the build pipeline, what does TPDE even stand for?23:09Claude responded: Three good questions.Three good questions. Let me take them in reverse order because they build on each other.
What does TPDE stand for?
The paper doesn't actually say. I searched the PDF and there's no expansion of the acronym anywhere — they just introduce it as "our novel compiler framework TPDE" and reference the GitHub repo (tpde2). Let me check if the authors or repo explain it.Searched the webSearched the webNone of these expand the acronym. Let me check the docs directly — sometimes project documentation explains the name.Fetched: TPDE: TPDEFetched: TPDE: TPDEThe official docs don't expand the acronym either. The name appears to be intentionally just a project name without a public expansion. My best guess (and it's only a guess) would be something like "Two-Pass Direct Emitter" given that it does two passes (analysis + codegen) and directly emits machine code without an intermediate IR — but the authors haven't published a meaning. If you really want to know, an email to Engelke would probably get an answer.
The repo name tpde2 suggests there was an earlier "tpde" effort that got reworked, which is consistent with the paper mentioning "a previous implementation without encoding snippets" that had 12.8k lines.
Now let me give you something more useful — the actual structure of the project. I found a few important things:

TPDE is the core framework (the IR-agnostic part)
TPDE-Encodegen is the snippet generator tool (section 4 of the paper)
TPDE-LLVM is the ready-made LLVM-IR back-end (section 5 of the paper)

These are three separate pieces. Important for understanding what you'd actually integrate.
How snippets fit into the build pipeline
This is a build-time vs. run-time distinction that's important to get straight.
Build time (when you compile your runtime)
This happens once, on your machine, before you ship anything:

You write C/C++ files containing your instruction semantics (the snippets):

c   uint32_t muli32(uint32_t a, uint32_t b) { return a * b; }
   int64_t add_with_check(int64_t a, int64_t b) { /* ... */ }
   // ... one function per IR operation you want to support

TPDE-Encodegen runs Clang/LLVM on these files, takes them all the way to target-specific Machine IR (just before LLVM would write actual bytes), and processes that MIR.
For each snippet function, TPDE-Encodegen emits a C++ file containing a corresponding encode_xxx() function — the "snippet encoder" from Figure 3c.
You compile those generated C++ files as part of your runtime, alongside your hand-written instruction compilers.
The final binary contains:

Your runtime code
The TPDE framework
The generated snippet encoders (which are now plain compiled C++ functions)
Your hand-written instruction compilers, which call those encoders



So the LLVM toolchain is only used at your build time to generate the snippet encoders. The shipped runtime doesn't depend on LLVM at all — that's the whole point. You get LLVM-quality target instruction sequences without LLVM being a runtime dependency.
This is actually crucial for the JIT use case. If TPDE itself required LLVM to be loaded into your process to generate code at runtime, it would be just as slow to start up as LLVM-based JITs. By doing the LLVM-using parts ahead-of-time, TPDE ships as a small, fast library.
Run time (when your runtime executes)
When your k runtime is running and decides to JIT-compile something:

Your runtime builds a k expression tree → converts to your SSA IR
Your runtime calls into TPDE with that IR
TPDE walks the IR (analysis + codegen passes)
Per-instruction, TPDE calls your instruction compiler
Your instruction compiler calls the pre-generated snippet encoders
The snippet encoders write actual machine bytes into a memory buffer
TPDE finishes, returns a pointer to the executable bytes
You call into that memory and your code runs

No LLVM involved at runtime. The snippet encoders are doing what they were generated to do — emit instructions with the right registers and addressing modes — but they're just normal compiled C++ at this point.
What this looks like in practice
The TPDE-Encodegen step is essentially a code generator that produces source code. You'd add it to your build system like any other code generator (think Bison, protoc, etc.):
my_snippets.c
       │
       │ (build time)
       ▼
[TPDE-Encodegen] → generated_encoders.cpp
       │
       │ (build time)
       ▼
   [your C++ compiler] → libmyruntime.so
       │
       │ (run time)
       ▼
   your k runtime, which JITs k expressions
For your runtime, you'd write your snippets once, set up the Encodegen step in your build, and from then on adding a new IR operation is roughly: write the C semantics, rebuild, write a thin instruction compiler that calls the encoder.
Using TPDE as a JIT
There are essentially two paths.
Path 1: Use TPDE-LLVM (the easy path)
If you're willing to produce LLVM-IR from your k expressions, you can use TPDE-LLVM directly. From the docs: "usable as library (e.g., for JIT)."
The flow:

Walk your k AST and emit LLVM-IR (using LLVM's C++ API to build the IR in memory)
Hand the IR module to TPDE-LLVM
Get back executable machine code
Map it executable in memory and call into it

This is the lowest-effort way to get fast compilation. Costs:

You depend on LLVM at runtime (because you need it to construct the IR)
You eat the IR-translation overhead the Umbra case study showed is significant
You don't get to design an IR specifically for k

For prototyping or for a first version, this might be fine. You'd get the 10-20x compile-time win over LLVM -O0 without much engineering, and you could measure where time is actually going before deciding to build something custom.
Path 2: Adapt TPDE to your own IR (the powerful path)
This is what Umbra did and what gives the best results. Steps:
1. Design an SSA IR for k. Decide what your "instructions" are. Sketch:

A Function has Blocks, each with Instructions
Each Instruction produces zero or more SSA values
Use integer IDs for everything (values, blocks, functions) — store these in dense arrays
Decide your "primitive" operations: things like index_atom, apply_dyadic_to_array, bounds_check, box_int, unbox_int, call_runtime_fn

Think hard about where to draw the line between "IR instructions" and "calls to runtime helpers." Array language hot paths probably want to be runtime calls (so you can use vectorized libraries). Scalar logic, type dispatch, loop induction, and control flow want to be in the IR so they can be optimized.
2. Write your IR adapter. This is the C++ class that exposes your IR to TPDE in its canonical form. The required methods are listed in Figure 2 of the paper. Most translate directly to one-line getters on your IR. If you can shape your IR like Umbra's (dense integer-indexed structures), the adapter is trivial.
3. Write your snippet semantics. A C file with one function per IR operation. For simple stuff:
cint64_t k_add_i64(int64_t a, int64_t b) { return a + b; }
int64_t k_neg_i64(int64_t a) { return -a; }
double k_add_f64(double a, double b) { return a + b; }
For things like type-dispatched operations, you'd write multiple variants. For complex array operations, you'd just emit a CALL to your runtime in the instruction compiler rather than using a snippet.
4. Write your instruction compilers. One C++ function per IR operation. Most look like:
cppvoid compile_add_i64(IRValueRef inst) {
  auto lhs = val_ref(operand(inst, 0), 0);
  auto rhs = val_ref(operand(inst, 1), 0);
  auto result = result_ref(inst, 0);
  encode_k_add_i64(lhs, rhs, result);  // call the generated snippet encoder
  set_value(result, ...);
}
The handful that need hand-written code (branches, comparisons, calls, special intrinsics) are architecture-specific but small.
5. Wire up JIT execution. TPDE will give you a memory buffer of bytes. You need to:

mmap an executable memory page (or use the platform equivalent)
Copy the bytes in (or have TPDE write directly into it)
mprotect to make it executable
Cast a pointer to a function type and call it

Most platforms have well-known patterns for this. On Linux you'd use mmap with PROT_READ | PROT_WRITE initially, then mprotect with PROT_READ | PROT_EXEC after writing.
6. Handle the runtime interface. Your compiled code needs to call back into your runtime (for things like memory allocation, garbage collection, calling builtins on values that exceed inline handling). These are normal function calls — the generated code does CALL <runtime_function_address>.
Pragmatic suggestion: start with path 1, migrate to path 2
If you're new to compiler back-ends, start with path 1. Use TPDE-LLVM. Get a working JIT for a small subset of k. Measure: how fast does it compile? How fast does the generated code run?
Then evaluate: is the IR translation overhead actually a problem for you? For Umbra it was 3.3x. For a k REPL where each line of input is small, even the LLVM IR construction overhead might be irrelevant compared to the user typing speed. For batch scripts processing lots of small functions, it might matter a lot.
If you do hit the wall where translation overhead becomes the bottleneck, then design your own IR and adapt TPDE to it. By that point you'll understand both your runtime's needs and TPDE's API well enough to make good design choices.
A concrete first project
If you want to start hands-on, I'd suggest something small:

Clone tpde and read the LLVM back-end (tpde-llvm/) as your reference example. The Umbra back-end isn't open source as far as I know, but the LLVM one is.
Build it locally with the cmake instructions from the docs above. Run their tests.
Try writing a minimal "calculator language" back-end before you tackle k: an IR with just integer add/sub/mul, variables, and conditionals. About 500 lines. This forces you to encounter every part of the framework (adapter, instruction compilers, snippets, JIT execution) without the complexity of k's semantics.
Then think about k. By this point you'll have intuition for what TPDE wants and what's idiomatic, which will help you design a k IR that fits well.

Want me to walk through what a minimal IR design for k might look like, or talk about the specific places where array-language semantics interact with TPDE's design assumptions?
