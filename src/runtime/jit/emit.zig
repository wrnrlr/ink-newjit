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
  int_:          usize,
  const_:        usize,
  global:        usize,
  local:         usize,
  local_last:    usize,
  assign_global: usize,
  assign_local:  usize,
  apply1:        usize,
  apply2:        usize,
  jump:          usize,
  jump_false:    usize,
  jump_true:     usize,
  return_:       usize,
};

/// Stencil machine-code fragments for chainable ops.
/// Null entries fall back to handler calls.
pub const StencilTable = struct {
  gap:          ?st.StencilInfo = null,
  int_:         ?st.StencilInfo = null,
  const_:       ?st.StencilInfo = null,
  local:        ?st.StencilInfo = null,
  local_last:   ?st.StencilInfo = null,
  assign_local: ?st.StencilInfo = null,
  apply1:       ?st.StencilInfo = null,
  apply2:       ?st.StencilInfo = null,
};

pub const MAX_JIT_BYTES = 128 * 1024;

pub const EmitResult = struct {
  size:    usize,
  stop_ip: usize,
};

pub fn emitLambda(
  buf:      []u8,
  chunk:    *const Chunk,
  start_ip: usize,
  h:        Handlers,
  stencils: StencilTable,
) EmitResult {
  var b   = a64.Buf{ .data = buf };
  const code = chunk.code.items;

  // ── Phase 1: stencil copy-and-patch ──────────────────────────────────────
  // For each stencil we record where in the output buffer the NEXT hole sits,
  // so we can patch it once we know the address of the following stencil.

  var pending_next_hole: ?usize = null; // byte offset into `b.data` of pending NEXT hole

  var ip       = start_ip;
  var stop_ip  = start_ip;

  while (ip < code.len) {
    const op: OpCode = @enumFromInt(code[ip]);

    // Determine if this op has a stencil and read its operand bytes.
    const maybe_info: ?st.StencilInfo = switch (op) {
      .Gap         => stencils.gap,
      .Int         => stencils.int_,
      .Const       => stencils.const_,
      .Local       => stencils.local,
      .LocalLast   => stencils.local_last,
      .AssignLocal => stencils.assign_local,
      .Apply1      => stencils.apply1,
      .Apply2      => stencils.apply2,
      else         => null,
    };

    const info = maybe_info orelse break; // fall through to Phase 2

    ip += 1; // consume the opcode byte

    // Read operand bytes (before consuming ip further for the next iteration).
    const operand: u16 = switch (op) {
      .Const, .Local, .LocalLast, .AssignLocal, .Apply1, .Apply2 => blk: {
        const v = code[ip]; ip += 1;
        break :blk v;
      },
      .Int => blk: {
        const lo = code[ip]; ip += 1;
        const hi = code[ip]; ip += 1;
        break :blk @as(u16, lo) | (@as(u16, hi) << 8);
      },
      else => 0,
    };

    // The start of this stencil copy in the output buffer.
    const copy_start = b.pos;

    // Patch the PREVIOUS stencil's NEXT hole to jump HERE.
    if (pending_next_hole) |hole_off| {
      st.patchNext(b.data, hole_off, @intFromPtr(b.data.ptr) + copy_start);
      pending_next_hole = null;
    }

    // Copy stencil bytes from text segment into JIT buffer.
    const src: [*]const u8 = info.bytes;
    @memcpy(b.data[b.pos..][0..info.size], src[0..info.size]);
    b.pos += info.size;

    // Patch operand hole (if the stencil has one).
    if (info.operand_offset) |op_off| {
      st.patchOperand(b.data, copy_start + op_off, operand);
    }

    // Remember where this stencil's NEXT hole is for the next iteration.
    pending_next_hole = copy_start + info.next_offset;
    stop_ip = ip;
  }

  // ── Phase 2: handler section for remaining ops ────────────────────────────
  // All pending NEXT holes (from Phase 1) are patched to jump to HERE.

  const handler_start = b.pos;

  if (pending_next_hole) |hole_off| {
    st.patchNext(b.data, hole_off, @intFromPtr(b.data.ptr) + handler_start);
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
  b.emit(a64.stpFpLr(32));        // stp x29, x30, [sp, #-32]!
  b.emit(a64.stpX19X20at16());    // stp x19, x20, [sp, #16]
  b.emit(a64.movFpSp());           // mov x29, sp
  b.emit(a64.mov(.x19, .x0));     // save vm in x19

  // Emit handler calls for each remaining op.
  while (ip < code.len) {
    const op: OpCode = @enumFromInt(code[ip]);
    ip += 1;

    switch (op) {
      .Nop  => { b.emit(a64.nop()); stop_ip = ip; },
      .Gap  => { emitCall0(&b, h.gap);  stop_ip = ip; },
      .Drop => { emitCall0(&b, h.drop); stop_ip = ip; },
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
  b.emit(a64.ldpX19X20at16());
  b.emit(a64.ldpFpLr(32));
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
