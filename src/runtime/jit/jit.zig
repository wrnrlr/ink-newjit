// JIT cache.  One JitCache lives inside the VM.
// Handler function pointers and stencil info are passed in from vm.zig
// (which defines them), avoiding a circular import.

const std   = @import("std");
const Alloc = std.mem.Allocator;
const Chunk = @import("../tape.zig").Chunk;
const mem   = @import("mem.zig");
const emit  = @import("emit.zig");

pub const Handlers     = emit.Handlers;
pub const StencilTable = emit.StencilTable;

/// Type pair encoding for profile-guided stencil selection.
/// Stored in JitCache.type_hints keyed by lambda_idx.
///   0    = unobserved / no useful hint yet
///   1    = i×i  (scalar int × scalar int)
///   2    = f×f  (scalar float × scalar float)
///   3    = I×I  (int array × int array)
///   4    = F×F  (float array × float array)
///   0xFF = polymorphic (conflicting types observed — do not specialize)
pub const TYPE_PAIR_NONE : u8 = 0;
pub const TYPE_PAIR_ii   : u8 = 1;
pub const TYPE_PAIR_ff   : u8 = 2;
pub const TYPE_PAIR_II   : u8 = 3;
pub const TYPE_PAIR_FF   : u8 = 4;
pub const TYPE_PAIR_POLY : u8 = 0xFF;

pub const JitFn = struct {
  code:          *const fn(*anyopaque) callconv(.c) void,
  stop_ip:       usize,
  complete:      bool,
  /// Type pair that was in effect when this entry was compiled.
  /// 0 = compiled without type specialization.
  compiled_hint: u8 = 0,
};

pub const JitCache = struct {
  alloc:      Alloc,
  jit_mem:    mem.JitMem,
  entries:    std.AutoHashMap(u24, JitFn),
  handlers:   Handlers,
  stencils:   StencilTable,
  /// Per-lambda observed type pair for Apply2 sites.
  type_hints: std.AutoHashMap(u24, u8),

  pub fn init(alloc: Alloc, handlers: Handlers, stencils: StencilTable, text_hint: usize) !JitCache {
    return .{
      .alloc      = alloc,
      .jit_mem    = try mem.JitMem.initNear(text_hint, 1 * 1024 * 1024),
      .entries    = std.AutoHashMap(u24, JitFn).init(alloc),
      .handlers   = handlers,
      .stencils   = stencils,
      .type_hints = std.AutoHashMap(u24, u8).init(alloc),
    };
  }

  pub fn deinit(jc: *JitCache) void {
    jc.jit_mem.deinit();
    jc.entries.deinit();
    jc.type_hints.deinit();
  }

  /// Record the type pair observed at an Apply2 site for `lambda_idx`.
  /// Call from apply2Worker (Phase 2) or specDyad slow path on first call.
  pub fn recordTypePair(jc: *JitCache, lambda_idx: u24, pair: u8) void {
    // NO_LAMBDA sentinel — top-level code, no JIT entry to update.
    if (lambda_idx == std.math.maxInt(u24)) return;
    if (pair == TYPE_PAIR_NONE or pair == TYPE_PAIR_POLY) return;
    const existing = jc.type_hints.get(lambda_idx);
    if (existing == null) {
      jc.type_hints.put(lambda_idx, pair) catch {};
    } else if (existing.? != pair) {
      // Conflicting observation — mark polymorphic to stop re-JIT loops.
      jc.type_hints.put(lambda_idx, TYPE_PAIR_POLY) catch {};
    }
  }

  /// Returns true if the lambda should be recompiled with a newer type hint.
  pub fn needsRejit(jc: *const JitCache, lambda_idx: u24) bool {
    const hint = jc.type_hints.get(lambda_idx) orelse return false;
    if (hint == TYPE_PAIR_NONE or hint == TYPE_PAIR_POLY) return false;
    const existing = jc.entries.get(lambda_idx) orelse return false;
    return existing.compiled_hint != hint;
  }

  pub fn getOrCompile(jc: *JitCache, lambda_idx: u24, chunk: *const Chunk) !JitFn {
    if (jc.entries.get(lambda_idx)) |f| {
      // If apply2Worker observed a new type pair since last compilation, recompile.
      if (!jc.needsRejit(lambda_idx)) return f;
      _ = jc.entries.remove(lambda_idx);
    }
    const type_hint = jc.type_hints.get(lambda_idx) orelse TYPE_PAIR_NONE;
    return jc.compile(lambda_idx, chunk, type_hint);
  }

  fn compile(jc: *JitCache, lambda_idx: u24, chunk: *const Chunk, type_hint: u8) !JitFn {
    const offset    = jc.jit_mem.currentOffset();
    const remaining = jc.jit_mem.len - offset;
    const max       = @min(remaining, emit.MAX_JIT_BYTES);
    if (max < 64) return error.JitMemFull;

    jc.jit_mem.beginWrite();
    const buf    = jc.jit_mem.ptr[offset .. offset + max];
    const result = emit.emitLambda(buf, chunk, 0, jc.handlers, jc.stencils, type_hint);
    jc.jit_mem.endWrite();

    const aligned = std.mem.alignForward(usize, result.size, 16);
    jc.jit_mem.used = offset + aligned;

    const code_ptr: *const fn(*anyopaque) callconv(.c) void =
      @ptrCast(@alignCast(jc.jit_mem.ptr + offset));

    const jf = JitFn{
      .code          = code_ptr,
      .stop_ip       = result.stop_ip,
      .complete      = result.stop_ip >= chunk.code.items.len,
      .compiled_hint = type_hint,
    };
    try jc.entries.put(lambda_idx, jf);
    return jf;
  }
};
