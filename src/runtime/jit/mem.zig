// Executable memory allocator for the JIT.
// On Apple Silicon, the OS enforces W^X: a page cannot be both writable and
// executable at the same time.  MAP_JIT + pthread_jit_write_protect_np lets
// us switch modes without remapping.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const PAGE_SIZE = 16384; // 16 KB pages on Apple Silicon

pub const JitMem = struct {
  ptr:  [*]align(PAGE_SIZE) u8,
  len:  usize,
  used: usize,

  pub fn init(capacity: usize) !JitMem {
    const aligned = std.mem.alignForward(usize, capacity, PAGE_SIZE);
    const raw = try mapJit(aligned);
    return .{ .ptr = raw, .len = aligned, .used = 0 };
  }

  /// Try to allocate JIT memory within ±128 MB of `hint` (a text-segment address)
  /// so that emitted `BL` instructions can reach handlers without MOV64+BLR.
  /// Falls back to ordinary `init` if no nearby region is found.
  pub fn initNear(hint: usize, capacity: usize) !JitMem {
    const aligned = std.mem.alignForward(usize, capacity, PAGE_SIZE);
    const prot  = std.c.PROT{ .READ = true, .WRITE = true, .EXEC = true };
    const flags = std.c.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true };
    const LIMIT: usize = 120 * 1024 * 1024; // 120 MB — leaves margin below ±128 MB
    const STEP:  usize =   4 * 1024 * 1024; // probe every 4 MB

    var off: usize = STEP;
    while (off <= LIMIT) : (off += STEP) {
      for ([2]usize{ hint + off, hint -| off }) |try_addr| {
        const page_addr = std.mem.alignBackward(usize, try_addr, PAGE_SIZE);
        const hint_ptr: ?*align(PAGE_SIZE) anyopaque = @ptrFromInt(page_addr);
        const raw = std.c.mmap(hint_ptr, aligned, prot, flags, -1, 0);
        if (raw == std.c.MAP_FAILED) continue;
        const got = @intFromPtr(raw);
        const delta: usize = if (got >= hint) got - hint else hint - got;
        if (delta <= LIMIT)
          return .{ .ptr = @ptrCast(@alignCast(raw)), .len = aligned, .used = 0 };
        _ = std.c.munmap(@alignCast(raw), aligned);
      }
    }
    return JitMem.init(capacity);
  }

  pub fn deinit(m: *JitMem) void {
    _ = std.c.munmap(@ptrCast(m.ptr), m.len);
  }

  // Switch to write mode, run writer_fn, then switch to execute mode.
  pub fn write(m: *JitMem, comptime T: type, ctx: T, writer_fn: fn(T, []u8) usize) void {
    jitWriteProtect(false);
    const written = writer_fn(ctx, m.ptr[m.used..m.len]);
    jitWriteProtect(true);
    m.used += written;
  }

  // Reserve a slice, fill it while in write mode.
  pub fn reserve(m: *JitMem, size: usize) []u8 {
    assert(m.used + size <= m.len);
    const slice = m.ptr[m.used .. m.used + size];
    m.used += size;
    return slice;
  }

  pub fn beginWrite(m: *JitMem) void  { _ = m; jitWriteProtect(false); }
  pub fn endWrite(m: *JitMem) void    { _ = m; jitWriteProtect(true); }

  pub fn sliceAt(m: *JitMem, offset: usize, size: usize) []u8 {
    return m.ptr[offset .. offset + size];
  }

  pub fn currentOffset(m: *const JitMem) usize { return m.used; }
};

fn mapJit(size: usize) ![*]align(PAGE_SIZE) u8 {
  const prot  = std.c.PROT{ .READ = true, .WRITE = true, .EXEC = true };
  const flags = std.c.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true };
  const raw = std.c.mmap(null, size, prot, flags, -1, 0);
  if (raw == std.c.MAP_FAILED) return error.MmapFailed;
  return @ptrCast(@alignCast(raw));
}

// pthread_jit_write_protect_np: false = writable, true = executable
extern fn pthread_jit_write_protect_np(enabled: c_int) void;

fn jitWriteProtect(exec: bool) void {
  pthread_jit_write_protect_np(if (exec) 1 else 0);
}
