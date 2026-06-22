const std = @import("std");
const builtin = @import("builtin");

// ─── W^X executable memory (Apple Silicon JIT) ────────────────────────────────
//
// Backing store for runtime-generated machine code. On Apple Silicon the
// hardened runtime forbids RWX pages, so we map with MAP_JIT and toggle the
// per-thread write/execute permission with pthread_jit_write_protect_np around
// each install, then flush the instruction cache. This is the load-bearing
// foundation for the copy-and-patch backend; it is platform-gated and only
// exercised behind tests until the codegen path is wired in.

pub const supported = builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;

extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) *anyopaque;
extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
extern "c" fn getpagesize() c_int;
extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

const PROT_READ: c_int = 0x1;
const PROT_WRITE: c_int = 0x2;
const PROT_EXEC: c_int = 0x4;
const MAP_PRIVATE: c_int = 0x0002;
const MAP_ANON: c_int = 0x1000;
const MAP_JIT: c_int = 0x0800;
const MAP_FAILED: usize = ~@as(usize, 0); // (void*)-1

pub const Error = error{ Unsupported, MapFailed };

pub const ExecBuf = struct {
  ptr: [*]u8,
  len: usize,

  pub fn alloc(min_size: usize) Error!ExecBuf {
    if (!supported) return Error.Unsupported;
    const page: usize = @intCast(getpagesize());
    const size = std.mem.alignForward(usize, @max(min_size, 1), page);
    const raw = mmap(null, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (@intFromPtr(raw) == MAP_FAILED) return Error.MapFailed;
    return .{ .ptr = @ptrCast(raw), .len = size };
  }

  /// Copy `code` in while the page is writable, then flip it to executable and
  /// flush the icache. After this returns the buffer is read+execute only.
  pub fn install(self: ExecBuf, code: []const u8) void {
    pthread_jit_write_protect_np(0); // writable
    @memcpy(self.ptr[0..code.len], code);
    pthread_jit_write_protect_np(1); // executable
    sys_icache_invalidate(self.ptr, code.len);
  }

  /// Reinterpret the buffer entry point as a C-ABI function pointer.
  pub fn entry(self: ExecBuf, comptime Fn: type) Fn {
    return @ptrCast(@alignCast(self.ptr));
  }

  pub fn free(self: ExecBuf) void {
    _ = munmap(self.ptr, self.len);
  }
};
