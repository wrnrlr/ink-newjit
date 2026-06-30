// `ink disasm <script.k>` — compile a script without running it and print the
// resulting bytecode.
const std = @import("std");
const VM = @import("../runtime/vm.zig").VM;
const disasm = @import("../runtime/disasm.zig");

pub fn run(vm: *VM, file: []const u8) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  var d = disasm.Disassembler.init(vm.compiler);
  d.compileFile(vm.parser.?, file) catch |err| {
    std.debug.print("error compiling {s}: {}\n", .{ file, err });
    std.process.exit(1);
  };
  var buf: [4096]u8 = undefined;
  var w = std.Io.File.stdout().writer(io, &buf);
  try d.print(&w.interface);
}
