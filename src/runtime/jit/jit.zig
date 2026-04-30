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

pub const JitFn = struct {
  code:     *const fn(*anyopaque) callconv(.c) void,
  stop_ip:  usize,
  complete: bool,
};

pub const JitCache = struct {
  alloc:    Alloc,
  jit_mem:  mem.JitMem,
  entries:  std.AutoHashMap(u24, JitFn),
  handlers: Handlers,
  stencils: StencilTable,

  pub fn init(alloc: Alloc, handlers: Handlers, stencils: StencilTable, text_hint: usize) !JitCache {
    return .{
      .alloc    = alloc,
      .jit_mem  = try mem.JitMem.initNear(text_hint, 1 * 1024 * 1024),
      .entries  = std.AutoHashMap(u24, JitFn).init(alloc),
      .handlers = handlers,
      .stencils = stencils,
    };
  }

  pub fn deinit(jc: *JitCache) void {
    jc.jit_mem.deinit();
    jc.entries.deinit();
  }

  pub fn getOrCompile(jc: *JitCache, lambda_idx: u24, chunk: *const Chunk) !JitFn {
    if (jc.entries.get(lambda_idx)) |f| return f;
    return jc.compile(lambda_idx, chunk);
  }

  fn compile(jc: *JitCache, lambda_idx: u24, chunk: *const Chunk) !JitFn {
    const offset    = jc.jit_mem.currentOffset();
    const remaining = jc.jit_mem.len - offset;
    const max       = @min(remaining, emit.MAX_JIT_BYTES);
    if (max < 64) return error.JitMemFull;

    jc.jit_mem.beginWrite();
    const buf    = jc.jit_mem.ptr[offset .. offset + max];
    const result = emit.emitLambda(buf, chunk, 0, jc.handlers, jc.stencils);
    jc.jit_mem.endWrite();

    const aligned = std.mem.alignForward(usize, result.size, 16);
    jc.jit_mem.used = offset + aligned;

    const code_ptr: *const fn(*anyopaque) callconv(.c) void =
      @ptrCast(@alignCast(jc.jit_mem.ptr + offset));

    const jf = JitFn{
      .code     = code_ptr,
      .stop_ip  = result.stop_ip,
      .complete = result.stop_ip >= chunk.code.items.len,
    };
    try jc.entries.put(lambda_idx, jf);
    return jf;
  }
};
