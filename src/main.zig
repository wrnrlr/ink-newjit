// Executable entry point. The command line implementation lives in src/cmd/;
// this shim keeps the module root at src/ so cmd/*.zig can import the rest of
// the tree (runtime/, parser/, noun/, …) by relative path.
pub const main = @import("cmd/runner.zig").main;
