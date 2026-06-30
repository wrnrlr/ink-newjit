const std = @import("std");

const HELP =
  \\ink — an array programming language interpreter
  \\
  \\Usage:
  \\  ink                       Start the REPL (when stdin is a tty)
  \\  ink < script.k            Evaluate source read from stdin
  \\  ink <script.k> [args...]  Run a script; extra args bind to `x`
  \\  ink <subcommand> [...]    Run a subcommand (see below)
  \\
  \\Subcommands:
  \\  help                      Show this message
  \\  version                   Print the ink version
  \\  disasm <script.k>         Compile a script and print its bytecode
  \\  bundle <script.k> [opts]  Ship a k script as a single executable
  \\                              -o <out>        output path
  \\                              -t <platform>   cross-bundle (e.g. linux-x64)
  \\  lsp                       Run the language server over stdio (JSON-RPC)
  \\  jupyter -f <conn-file>    Run a Jupyter kernel over ZeroMQ
  \\  jupyter install           Install the Jupyter kernelspec
  \\
  \\Options:
  \\  -unfocus                  Open the GPU window without grabbing keyboard focus
  \\  -top                      Keep the GPU window always-on-top
  \\  -monitor <N>              Place the GPU window on monitor N (0-based)
  \\  -size <WxH>               Set the GPU window size (e.g. -size 1280x720)
  \\  -snap [t0,t1,...]         Capture headless PNG screenshots at the given
  \\                            sim-times (seconds); bare -snap shoots once
  \\
  \\Examples:
  \\  echo "1+2" | ink
  \\  ink test/planes.k
  \\  ink -snap 0.5,2 test/eyes.k
  \\
;

pub fn run(_: std.mem.Allocator) !void {
  const io = std.Io.Threaded.global_single_threaded.io();
  var buf: [4096]u8 = undefined;
  var writer = std.Io.File.stdout().writer(io, &buf);
  try writer.interface.writeAll(HELP);
  try writer.interface.flush();
}
