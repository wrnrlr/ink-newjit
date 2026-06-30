// Static-library root for the ink interpreter, used by `ink bundle` to link a
// self-contained executable.  Exposes a single C-ABI entry the generated glue
// calls; the glue @embedFile's the script+modules archive and passes the linked
// extensions' init functions.  (The `ink` executable proper uses src/main.zig.)
const runner = @import("cmd/runner.zig");

const ExtInit = *const fn (*anyopaque) callconv(.c) void;

export fn ink_run_bundle(
  archive_ptr: [*]const u8,
  archive_len: usize,
  inits_ptr: [*]const ?ExtInit,
  inits_len: usize,
) callconv(.c) c_int {
  return runner.runBundle(archive_ptr[0..archive_len], inits_ptr[0..inits_len]);
}
