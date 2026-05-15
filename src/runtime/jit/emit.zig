// JIT emitter: Copy-and-Patch for leading push ops, handler calls for the rest.
//
// For each lambda the emitter makes two passes over the bytecode:
//
//   Phase 1 — Stencil copy-and-patch
//     Ops: Gap, Int, Local, LocalLast (no alloc, no error path).
//     Each stencil is a machine-code fragment copied from the text segment.
//     Its NEXT hole is patched to point to the next copied fragment (or to the
//     handler section that follows).
//
//   Phase 2 — Handler section
//     Remaining ops use the existing "emit a call to a handler function"
//     strategy.  This section has its own prologue / epilogue so that the
//     BLR calls inside can save/restore x30 correctly.
//     The last stencil's NEXT hole is patched to the start of this section.
//
// Register convention (same as before inside the handler section):
//   x19 = vm pointer (callee-saved)
//   x0  = vm  (set before each handler call)
//   x1  = operand (for handlers that need it)
//   x8  = handler address

const std    = @import("std");
const OpCode = @import("../tape.zig").OpCode;
const Chunk  = @import("../tape.zig").Chunk;
const a64    = @import("arm64.zig");
const st     = @import("stencils.zig");

pub const Handlers = struct {
  gap:           usize,
  drop:          usize,
  dup:           usize,
  int_:          usize,
  const_:        usize,
  global:        usize,
  local:         usize,
  local_last:    usize,
  assign_global: usize,
  assign_local:  usize,
  apply1:        usize,
  apply2:        usize,
  call:          usize,
  tail_call:     usize,
  apply:         usize,
  make_partial:  usize,
  make_list:     usize,
  derive:        usize,
  make_dict:     usize,
  jump:          usize,
  jump_false:    usize,
  jump_true:     usize,
  return_:       usize,
};

/// Stencil machine-code fragments for chainable ops.
/// Null entries fall back to handler calls.
pub const StencilTable = struct {
  gap:          ?st.StencilInfo = null,
  dup:          ?st.StencilInfo = null,
  global:       ?st.StencilInfo = null,
  int_:         ?st.StencilInfo = null,
  const_:       ?st.StencilInfo = null,
  local:        ?st.StencilInfo = null,
  local_last:   ?st.StencilInfo = null,
  assign_local: ?st.StencilInfo = null,
  apply1:       ?st.StencilInfo = null,
  apply2:        ?st.StencilInfo = null,
  drop:          ?st.StencilInfo = null,
  assign_global: ?st.StencilInfo = null,
  make_list:     ?st.StencilInfo = null,
  derive:        ?st.StencilInfo = null,
  make_dict:     ?st.StencilInfo = null,
  return_:       ?st.StencilInfo = null,
  jump_false:    ?st.StencilInfo = null,
  jump_true:     ?st.StencilInfo = null,
  // Type-specialised dyadic stencils (int op int, fast path; slow path calls apply2 handler).
  add_ii: ?st.StencilInfo = null,
  sub_ii: ?st.StencilInfo = null,
  mul_ii: ?st.StencilInfo = null,
  lt_ii:  ?st.StencilInfo = null,
  gt_ii:  ?st.StencilInfo = null,
  eq_ii:  ?st.StencilInfo = null,
  // Array-level SIMD stencils (I×I and F×F). Selected by profile-guided re-JIT.
  // Each stencil calls vm.jit_simd_array2 with the op baked in; fallback to
  // dispatch2 for non-matching types at runtime.
  add_II: ?st.StencilInfo = null,
  sub_II: ?st.StencilInfo = null,
  mul_II: ?st.StencilInfo = null,
  lt_II:  ?st.StencilInfo = null,
  gt_II:  ?st.StencilInfo = null,
  eq_II:  ?st.StencilInfo = null,
  add_FF: ?st.StencilInfo = null,
  sub_FF: ?st.StencilInfo = null,
  mul_FF: ?st.StencilInfo = null,
  lt_FF:  ?st.StencilInfo = null,
  gt_FF:  ?st.StencilInfo = null,
  eq_FF:  ?st.StencilInfo = null,
};

pub const MAX_JIT_BYTES = 128 * 1024;

pub const EmitResult = struct {
  size:    usize,
  stop_ip: usize,
};

pub fn emitLambda(
  buf:       []u8,
  chunk:     *const Chunk,
  start_ip:  usize,
  h:         Handlers,
  stencils:  StencilTable,
  type_hint: u8,
) EmitResult {
  var b   = a64.Buf{ .data = buf };
  const code = chunk.code.items;

  // ── Phase 1: stencil copy-and-patch ──────────────────────────────────────
  // For each stencil we record where in the output buffer the NEXT hole sits,
  // so we can patch it once we know the address of the following stencil.

  var pending_next_hole: ?usize = null; // byte offset into `b.data` of pending NEXT hole

  // Forward-branch patch records: when a branch stencil (or Jump) has a taken-hole
  // that targets a not-yet-emitted ip, we record it here and patch it later.
  const PendingBranch = struct { hole_off: usize, target_ip: usize };
  var pending_branches: [16]PendingBranch = undefined;
  var n_pending_branches: usize = 0;

  var ip               = start_ip;
  var stop_ip          = start_ip;
  var terminal_emitted = false;

  while (ip < code.len) {
    const instr_ip = ip;
    const op: OpCode = @enumFromInt(code[ip]);

    // Nop: no-op — advance ip and continue Phase 1 without emitting anything.
    // OpCode.Nop rarely appears in compiled bytecode but must not force Phase 2.
    if (op == .Nop) { ip += 1; stop_ip = ip; continue; }

    // Unconditional Jump: redirect pending NEXT hole to the target — no stencil emitted.
    if (op == .Jump) {
      ip += 1;
      const lo = code[ip]; ip += 1;
      const hi = code[ip]; ip += 1;
      const off = @as(u16, lo) | (@as(u16, hi) << 8);
      const target_ip = ip + off;
      if (pending_next_hole) |hole_off| {
        if (n_pending_branches < pending_branches.len) {
          pending_branches[n_pending_branches] = .{ .hole_off = hole_off, .target_ip = target_ip };
          n_pending_branches += 1;
        }
        pending_next_hole = null;
      }
      stop_ip = ip;
      continue;
    }

    // Determine if this op has a stencil and read its operand bytes.
    const maybe_info: ?st.StencilInfo = switch (op) {
      .Gap         => stencils.gap,
      .Dup         => stencils.dup,
      .Global      => stencils.global,
      .Int         => stencils.int_,
      .Const       => stencils.const_,
      .Local       => stencils.local,
      .LocalLast   => stencils.local_last,
      .AssignLocal => stencils.assign_local,
      .Apply1      => stencils.apply1,
      .Drop        => stencils.drop,
      .AssignGlobal => stencils.assign_global,
      .MakeList    => stencils.make_list,
      .Derive      => stencils.derive,
      .MakeDict    => stencils.make_dict,
      .Apply2      => blk: {
        const Iop = @import("../tape.zig").Op;
        // Peek at the op byte to select a type-specialised stencil.
        if (ip + 1 < code.len) {
          const opbyte = code[ip + 1];
          // Profile-guided array SIMD stencils (type_hint 3=I×I, 4=F×F).
          // Selected on re-JIT after apply2Worker observes the type pair.
          if (type_hint == 3) {
            const spec: ?st.StencilInfo = switch (opbyte) {
              @intFromEnum(Iop.@"+") => stencils.add_II,
              @intFromEnum(Iop.@"-") => stencils.sub_II,
              @intFromEnum(Iop.@"*") => stencils.mul_II,
              @intFromEnum(Iop.@"<") => stencils.lt_II,
              @intFromEnum(Iop.@">") => stencils.gt_II,
              @intFromEnum(Iop.@"=") => stencils.eq_II,
              else => null,
            };
            if (spec) |s| break :blk s;
          }
          if (type_hint == 4) {
            const spec: ?st.StencilInfo = switch (opbyte) {
              @intFromEnum(Iop.@"+") => stencils.add_FF,
              @intFromEnum(Iop.@"-") => stencils.sub_FF,
              @intFromEnum(Iop.@"*") => stencils.mul_FF,
              @intFromEnum(Iop.@"<") => stencils.lt_FF,
              @intFromEnum(Iop.@">") => stencils.gt_FF,
              @intFromEnum(Iop.@"=") => stencils.eq_FF,
              else => null,
            };
            if (spec) |s| break :blk s;
          }
          // Scalar type-specialised stencils (int×int, float×float fast paths).
          const spec: ?st.StencilInfo = switch (opbyte) {
            @intFromEnum(Iop.@"+") => stencils.add_ii,
            @intFromEnum(Iop.@"-") => stencils.sub_ii,
            @intFromEnum(Iop.@"*") => stencils.mul_ii,
            @intFromEnum(Iop.@"<") => stencils.lt_ii,
            @intFromEnum(Iop.@">") => stencils.gt_ii,
            @intFromEnum(Iop.@"=") => stencils.eq_ii,
            else => null,
          };
          if (spec) |s| break :blk s;
        }
        break :blk stencils.apply2;
      },
      .Return      => stencils.return_,
      .JumpFalse   => stencils.jump_false,
      .JumpTrue    => stencils.jump_true,
      else         => null,
    };

    const info = maybe_info orelse break; // fall through to Phase 2

    ip += 1; // consume the opcode byte

    const is_branch = (op == .JumpFalse or op == .JumpTrue);

    // Read operand bytes (before consuming ip further for the next iteration).
    const operand: u16 = switch (op) {
      .Const, .Global, .Local, .LocalLast, .AssignLocal, .Apply1, .Apply2,
      .AssignGlobal, .MakeList, .Derive, .MakeDict => blk: {
        const v = code[ip]; ip += 1;
        break :blk v;
      },
      .Int, .JumpFalse, .JumpTrue => blk: {
        const lo = code[ip]; ip += 1;
        const hi = code[ip]; ip += 1;
        break :blk @as(u16, lo) | (@as(u16, hi) << 8);
      },
      else => 0,
    };

    // For branch ops, compute the taken target bytecode ip.
    const target_ip: usize = if (is_branch) ip + operand else 0;

    // The start of this stencil copy in the output buffer.
    const copy_start = b.pos;

    // Patch the sequential (fall-through) pending NEXT hole to jump HERE.
    if (pending_next_hole) |hole_off| {
      st.patchNext(b.data, hole_off, @intFromPtr(b.data.ptr) + copy_start);
      pending_next_hole = null;
    }

    // Patch any forward branches whose target_ip is this instruction.
    var k: usize = 0;
    while (k < n_pending_branches) {
      if (pending_branches[k].target_ip == instr_ip) {
        st.patchNext(b.data, pending_branches[k].hole_off, @intFromPtr(b.data.ptr) + copy_start);
        n_pending_branches -= 1;
        pending_branches[k] = pending_branches[n_pending_branches];
      } else {
        k += 1;
      }
    }

    // Copy stencil bytes from text segment into JIT buffer.
    const src: [*]const u8 = info.bytes;
    @memcpy(b.data[b.pos..][0..info.size], src[0..info.size]);
    b.pos += info.size;

    // Patch operand hole (not present on branch or terminal stencils).
    if (info.operand_offset) |op_off| {
      st.patchOperand(b.data, copy_start + op_off, operand);
    }

    // Terminal stencils (e.g. Return) end with RET — no NEXT hole to chain.
    // Return immediately without emitting Phase 2.
    if (info.is_terminal) {
      stop_ip = ip;
      terminal_emitted = true;
      break;
    }

    // Set up pending holes for the next iteration.
    if (is_branch) {
      // Fall-through NEXT hole: entered when the condition does NOT trigger the jump.
      pending_next_hole = copy_start + info.next_offset;
      // Taken NEXT hole: forward branch to the jump target.
      if (info.branch_offset) |branch_off| {
        if (n_pending_branches < pending_branches.len) {
          pending_branches[n_pending_branches] = .{ .hole_off = copy_start + branch_off, .target_ip = target_ip };
          n_pending_branches += 1;
        }
      }
    } else {
      pending_next_hole = copy_start + info.next_offset;
      // Non-branch stencil with a secondary NEXT hole (e.g. type-specialised
      // Apply2 in ReleaseFast where the slow path gets its own NEXT hole).
      // Both holes must jump to the same successor — register the secondary as
      // a pending branch that targets the very next bytecode instruction (ip),
      // so it is patched to the same copy_start as the primary when that
      // instruction is compiled.
      if (info.branch_offset) |branch_off| {
        if (n_pending_branches < pending_branches.len) {
          pending_branches[n_pending_branches] = .{ .hole_off = copy_start + branch_off, .target_ip = ip };
          n_pending_branches += 1;
        }
      }
      if (info.branch_offset2) |branch_off2| {
        if (n_pending_branches < pending_branches.len) {
          pending_branches[n_pending_branches] = .{ .hole_off = copy_start + branch_off2, .target_ip = ip };
          n_pending_branches += 1;
        }
      }
    }

    stop_ip = ip;
  }

  // Phase 1 ended with a terminal stencil (e.g. Return): the stencil's RET
  // already returned from the JIT function.  Skip Phase 2 entirely.
  if (terminal_emitted) return .{ .size = b.pos, .stop_ip = stop_ip };

  // ── Phase 2: handler section for remaining ops ────────────────────────────
  // All pending NEXT holes (from Phase 1) are patched to jump to HERE.

  const handler_start = b.pos;

  if (pending_next_hole) |hole_off| {
    st.patchNext(b.data, hole_off, @intFromPtr(b.data.ptr) + handler_start);
  }

  // Patch any remaining forward branches (targets within Phase 2 bytecode range).
  for (pending_branches[0..n_pending_branches]) |pb| {
    st.patchNext(b.data, pb.hole_off, @intFromPtr(b.data.ptr) + handler_start);
  }

  // If Phase 1 compiled everything (ip reached end with no remaining ops),
  // we still need to emit at least a RET so the caller can return.
  // In practice this only happens for trivially-empty or Return-less bytecode
  // (shouldn't occur for well-formed lambdas).
  if (ip >= code.len) {
    b.emit(a64.ret());
    return .{ .size = b.pos, .stop_ip = stop_ip };
  }

  // Prologue for the handler section.
  b.emit(a64.stpX19X30(16));      // stp x19, x30, [sp, #-16]!
  b.emit(a64.mov(.x19, .x0));     // save vm in x19

  // Emit handler calls for each remaining op.
  while (ip < code.len) {
    const op: OpCode = @enumFromInt(code[ip]);
    ip += 1;

    switch (op) {
      .Nop  => { b.emit(a64.nop()); stop_ip = ip; },
      .Gap  => { emitCall0(&b, h.gap);  stop_ip = ip; },
      .Drop => { emitCall0(&b, h.drop); stop_ip = ip; },
      .Dup  => { emitCall0(&b, h.dup);  stop_ip = ip; },
      .Return => {
        emitCall0(&b, h.return_);
        stop_ip = ip;
        break;
      },
      .Const => {
        const idx = code[ip]; ip += 1;
        emitCall1u8(&b, h.const_, idx); stop_ip = ip;
      },
      .Global => {
        const idx = code[ip]; ip += 1;
        emitCall1u8(&b, h.global, idx); stop_ip = ip;
      },
      .Local => {
        const slot = code[ip]; ip += 1;
        emitCall1u8(&b, h.local, slot); stop_ip = ip;
      },
      .LocalLast => {
        const slot = code[ip]; ip += 1;
        emitCall1u8(&b, h.local_last, slot); stop_ip = ip;
      },
      .AssignGlobal => {
        const idx = code[ip]; ip += 1;
        emitCall1u8(&b, h.assign_global, idx); stop_ip = ip;
      },
      .AssignLocal => {
        const slot = code[ip]; ip += 1;
        emitCall1u8(&b, h.assign_local, slot); stop_ip = ip;
      },
      .Apply1 => {
        const ob = code[ip]; ip += 1;
        emitCall1u8(&b, h.apply1, ob); stop_ip = ip;
      },
      .Apply2 => {
        const ob = code[ip]; ip += 1;
        emitCall1u8(&b, h.apply2, ob); stop_ip = ip;
      },
      .Call => {
        const argc = code[ip]; ip += 1;
        emitCall1u8(&b, h.call, argc); stop_ip = ip;
      },
      .TailCall => {
        const argc = code[ip]; ip += 1;
        emitCall1u8(&b, h.tail_call, argc);
        stop_ip = ip;
        break; // TailCall is always terminal — stop Phase 2 after it.
      },
      .Apply => {
        const argc = code[ip]; ip += 1;
        emitCall1u8(&b, h.apply, argc); stop_ip = ip;
      },
      .MakePartial => {
        const argc = code[ip]; ip += 1;
        const mask = code[ip]; ip += 1;
        const combined: u16 = (@as(u16, argc) << 8) | mask;
        emitCall1u16(&b, h.make_partial, combined); stop_ip = ip;
      },
      .MakeList => {
        const n = code[ip]; ip += 1;
        emitCall1u8(&b, h.make_list, n); stop_ip = ip;
      },
      .Derive => {
        const adv = code[ip]; ip += 1;
        emitCall1u8(&b, h.derive, adv); stop_ip = ip;
      },
      .MakeDict => {
        const n = code[ip]; ip += 1;
        emitCall1u8(&b, h.make_dict, n); stop_ip = ip;
      },
      .Int => {
        const lo = code[ip]; ip += 1;
        const hi = code[ip]; ip += 1;
        const raw: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
        emitCall1u16(&b, h.int_, raw); stop_ip = ip;
      },
      .Jump => {
        const lo = code[ip]; ip += 1;
        const hi = code[ip]; ip += 1;
        const off: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
        emitCall1u16(&b, h.jump, off);
        stop_ip = ip;
        break;
      },
      .JumpFalse => {
        const lo = code[ip]; ip += 1;
        const hi = code[ip]; ip += 1;
        const off: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
        emitCall1u16(&b, h.jump_false, off);
        stop_ip = ip;
        break;
      },
      .JumpTrue => {
        const lo = code[ip]; ip += 1;
        const hi = code[ip]; ip += 1;
        const off: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
        emitCall1u16(&b, h.jump_true, off);
        stop_ip = ip;
        break;
      },
      else => {
        stop_ip = ip - 1;
        break;
      },
    }
  }

  // Epilogue for the handler section.
  b.emit(a64.ldpX19X30(16));
  b.emit(a64.ret());

  return .{ .size = b.pos, .stop_ip = stop_ip };
}

// ── Handler call helpers ───────────────────────────────────────────────────────
// Use BL (PC-relative, 1 word) when the target is within ±128 MB of the JIT
// buffer; otherwise fall back to MOV64+BLR (up to 5 words).

fn callInsn(b: *a64.Buf, fn_ptr: usize) void {
  const from: usize = @intFromPtr(b.data.ptr) + b.pos;
  const delta: i64 = @as(i64, @bitCast(fn_ptr)) - @as(i64, @bitCast(from));
  if (delta >= -(1 << 27) and delta < (1 << 27)) {
    b.emit(a64.bl(@intCast(delta)));
  } else {
    a64.mov64(b, .x8, fn_ptr);
    b.emit(a64.blr(.x8));
  }
}

fn emitCall0(b: *a64.Buf, fn_ptr: usize) void {
  b.emit(a64.mov(.x0, .x19));
  callInsn(b, fn_ptr);
}

fn emitCall1u8(b: *a64.Buf, fn_ptr: usize, operand: u8) void {
  b.emit(a64.mov(.x0, .x19));
  b.emit(a64.movzW(.x1, operand));
  callInsn(b, fn_ptr);
}

fn emitCall1u16(b: *a64.Buf, fn_ptr: usize, operand: u16) void {
  b.emit(a64.mov(.x0, .x19));
  b.emit(a64.movzW(.x1, operand));
  callInsn(b, fn_ptr);
}
