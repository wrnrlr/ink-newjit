const std = @import("std");
const V = @import("../../noun/value.zig").V;
const Err = @import("../../noun/value.zig").Err;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const ParseError = @import("../../parser/parser.zig").ParseError;

pub const GetSymbol = struct {
  pub const op = .@".";
  _s: VM.Monad = getSymbol,
  _C: VM.Monad = evalString,
};

fn getSymbol(vm: *VM, x: V) V {
  const sname = vm.getSymbol(x.s);
  if (vm.names.get(sname)) |idx| {
    return vm.globals[idx].ref();
  }
  return V{ .err = .domain };
}

/// `` . "1+2" `` — evaluate ink source in the global scope, as in ngn/k.  This
/// is what a REPL written in k evaluates each entry with, so a failure must come
/// back as an error VALUE, never as a Zig error that unwinds the caller: a bad
/// entry has to be printable like any other result.  Parse failures intern the
/// whole `parse_error: <what> at <line>:<col>` message as the error's symbol, so
/// `!parse_error: UnexpectedToken at 1:4` survives into k.
fn evalString(vm: *VM, x: V) V {
  return vm.evalNested(x.C.slice()) catch |e| evalError(vm, e, x.C.slice());
}

fn evalError(vm: *VM, e: anyerror, src: []const u8) V {
  const parse_failed = switch (e) {
    error.UnexpectedToken, error.AssignInParens, error.InvalidCharacter, error.Overflow => true,
    else => false,
  };
  if (!parse_failed) {
    const idx = vm.intern(@errorName(e)) catch return V{ .err = .memory };
    return V{ .err = Err.from(idx) };
  }
  const pos = srcPos(src, vm.parser.?.err_pos);
  var buf: [128]u8 = undefined;
  const msg = std.fmt.bufPrint(&buf, "parse_error: {s} at {d}:{d}", .{ @errorName(e), pos.line, pos.col }) catch
    return V{ .err = .memory };
  const idx = vm.intern(msg) catch return V{ .err = .memory };
  return V{ .err = Err.from(idx) };
}

/// A byte offset as a 1-based line/column.
fn srcPos(src: []const u8, off: u32) struct { line: u32, col: u32 } {
  const o = @min(off, src.len);
  var line: u32 = 1;
  var bol: usize = 0;
  for (src[0..o], 0..) |ch, i| if (ch == '\n') { line += 1; bol = i + 1; };
  return .{ .line = line, .col = @intCast(o - bol + 1) };
}

comptime {
  // evalError's parse-failure list must stay in step with the parser's error
  // set (minus OutOfMemory, which is not a source-position failure).
  for (@typeInfo(ParseError).error_set.?) |fld| {
    if (std.mem.eql(u8, fld.name, "OutOfMemory")) continue;
    const known = std.mem.eql(u8, fld.name, "UnexpectedToken") or
      std.mem.eql(u8, fld.name, "AssignInParens") or
      std.mem.eql(u8, fld.name, "InvalidCharacter") or
      std.mem.eql(u8, fld.name, "Overflow");
    if (!known) @compileError("get.zig evalError: unhandled ParseError." ++ fld.name);
  }
}
