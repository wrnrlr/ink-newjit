const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const format = @import("../../noun/format.zig");
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;

fn writeFile(vm: *VM, id: u32, content: []const u8) !void {
  // Guard invalid ids (e.g. `2:` applied to a bogus handle) rather than
  // indexing the registry out of bounds.
  if (id >= vm.fs.texts.items.len) return error.BadFileId;
  if (vm.fs.getPath(id)) |path| {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, content, 0);
  }
  try vm.fs.updateFile(id, content);
}

// ---------------------------------------------------------------------------
// ReadLines  0: (monad)
// ---------------------------------------------------------------------------

fn readLinesBySymbol(vm: *VM, x: V) V {
  const id = vm.mapFile(vm.getSymbol(x.s)) catch return V{ .err = .io };
  return readLinesById(vm, V{ .i = @intCast(id) });
}
fn readLinesByChars(vm: *VM, x: V) V {
  const id = vm.mapFile(x.C.slice()) catch return V{ .err = .io };
  return readLinesById(vm, V{ .i = @intCast(id) });
}
fn readLinesById(vm: *VM, x: V) V {
  const text = vm.fs.getFileText(@as(u32, @intCast(x.i)));
  var list = std.ArrayList(V).initCapacity(vm.alloc, 0) catch return V{ .err = .memory };
  defer list.deinit(vm.alloc);
  var iter = std.mem.splitScalar(u8, text, '\n');
  while (iter.next()) |line| {
    const stripped = std.mem.trimEnd(u8, line, &[_]u8{'\r'});
    const s = V.Chars(vm.alloc, stripped) catch return V{ .err = .memory };
    list.append(vm.alloc, s) catch return V{ .err = .memory };
  }
  return V.Values(vm.alloc, list.items) catch return V{ .err = .memory };
}

pub const ReadLines = struct {
  pub const op = .@"0:";
  _s: VM.MonadFn = readLinesBySymbol,
  _C: VM.MonadFn = readLinesByChars,
  _i: VM.MonadFn = readLinesById,
};

// ---------------------------------------------------------------------------
// WriteLines  0: (dyad)
// ---------------------------------------------------------------------------

fn writeLinesConsole(vm: *VM, _: V, y: V) V {
  if (y.tag() == .C) {
    vm.print("{s}\n", .{y.C.slice()});
    return .blank;
  }
  if (y.tag() == .s) {
    vm.print("{s}\n", .{vm.getSymbol(y.s)});
    return .blank;
  }
  if (y.tag() == .L) {
    for (y.L.slice(), 0..) |item, i| {
      if (i > 0) vm.print("\n", .{});
      if (item.tag() == .C) vm.print("{s}", .{item.C.slice()})
      else if (item.tag() == .s) vm.print("{s}", .{vm.getSymbol(item.s)});
    }
    vm.print("\n", .{});
    return .blank;
  }
  return V{ .err = .@"type" };
}
fn writeLinesBySymbol(vm: *VM, x: V, y: V) V {
  const path = vm.getSymbol(x.s);
  if (path.len == 0 or std.mem.eql(u8, path, "0")) return writeLinesConsole(vm, x, y);
  const id = vm.mapFile(path) catch return V{ .err = .io };
  return writeLinesById(vm, V{ .i = @intCast(id) }, y);
}
fn writeLinesByChars(vm: *VM, x: V, y: V) V {
  const id = vm.mapFile(x.C.slice()) catch return V{ .err = .io };
  return writeLinesById(vm, V{ .i = @intCast(id) }, y);
}
fn writeLinesById_L(vm: *VM, x: V, y: V) V { return writeLinesById(vm, x, y); }
fn writeLinesById_C(vm: *VM, x: V, y: V) V { return writeLinesById(vm, x, y); }
fn writeLinesById_s(vm: *VM, x: V, y: V) V { return writeLinesById(vm, x, y); }
fn writeLinesById(vm: *VM, x: V, y: V) V {
  const id = @as(u32, @intCast(x.i));
  var out = std.ArrayList(u8).initCapacity(vm.alloc, 0) catch return V{ .err = .memory };
  defer out.deinit(vm.alloc);
  switch (y) {
    .L => for (y.L.slice(), 0..) |item, i| {
      if (i > 0) out.append(vm.alloc, '\n') catch return V{ .err = .memory };
      if (item.tag() == .C) out.appendSlice(vm.alloc, item.C.slice()) catch return V{ .err = .memory }
      else if (item.tag() == .s) out.appendSlice(vm.alloc, vm.getSymbol(item.s)) catch return V{ .err = .memory };
    },
    .C => out.appendSlice(vm.alloc, y.C.slice()) catch return V{ .err = .memory },
    .s => out.appendSlice(vm.alloc, vm.getSymbol(y.s)) catch return V{ .err = .memory },
    else => return V{ .err = .@"type" },
  }
  out.append(vm.alloc, '\n') catch return V{ .err = .memory };
  writeFile(vm, id, out.items) catch return V{ .err = .io };
  return .blank;
}

pub const WriteLines = struct {
  pub const op = .@"0:";
  _s_L: VM.DyadFn = writeLinesBySymbol,
  _s_C: VM.DyadFn = writeLinesBySymbol,
  _s_s: VM.DyadFn = writeLinesBySymbol,
  _C_L: VM.DyadFn = writeLinesByChars,
  _C_C: VM.DyadFn = writeLinesByChars,
  _C_s: VM.DyadFn = writeLinesByChars,
  _i_L: VM.DyadFn = writeLinesById_L,
  _i_C: VM.DyadFn = writeLinesById_C,
  _i_s: VM.DyadFn = writeLinesById_s,
};

// ---------------------------------------------------------------------------
// ReadBytes  1: (monad)
// ---------------------------------------------------------------------------

fn readBytesBySymbol(vm: *VM, x: V) V {
  const id = vm.mapFile(vm.getSymbol(x.s)) catch return V{ .err = .io };
  return readBytesById(vm, V{ .i = @intCast(id) });
}
fn readBytesByChars(vm: *VM, x: V) V {
  const id = vm.mapFile(x.C.slice()) catch return V{ .err = .io };
  return readBytesById(vm, V{ .i = @intCast(id) });
}
fn readBytesById(vm: *VM, x: V) V {
  return V.Chars(vm.alloc, vm.fs.getFileText(@as(u32, @intCast(x.i)))) catch return V{ .err = .memory };
}

pub const ReadBytes = struct {
  pub const op = .@"1:";
  _s: VM.MonadFn = readBytesBySymbol,
  _C: VM.MonadFn = readBytesByChars,
  _i: VM.MonadFn = readBytesById,
};

// ---------------------------------------------------------------------------
// WriteBytes  1: (dyad)
// ---------------------------------------------------------------------------

fn writeBytesBySymbol(vm: *VM, x: V, y: V) V {
  const id = vm.mapFile(vm.getSymbol(x.s)) catch return V{ .err = .io };
  return writeBytesByHandle(vm, V{ .i = @intCast(id) }, y);
}
fn writeBytesByChars(vm: *VM, x: V, y: V) V {
  const id = vm.mapFile(x.C.slice()) catch return V{ .err = .io };
  return writeBytesByHandle(vm, V{ .i = @intCast(id) }, y);
}
fn writeBytesByHandle(vm: *VM, x: V, y: V) V {
  writeFile(vm, @as(u32, @intCast(x.i)), y.C.slice()) catch return V{ .err = .io };
  return .blank;
}

pub const WriteBytes = struct {
  pub const op = .@"1:";
  _s_C: VM.DyadFn = writeBytesBySymbol,
  _C_C: VM.DyadFn = writeBytesByChars,
  _i_C: VM.DyadFn = writeBytesByHandle,
};

// ---------------------------------------------------------------------------
// ReadData  2: (monad)
// ---------------------------------------------------------------------------

fn readDataBySymbol(vm: *VM, x: V) V {
  const id = vm.mapFile(vm.getSymbol(x.s)) catch return V{ .err = .io };
  return readDataById(vm, V{ .i = @intCast(id) });
}
fn readDataByChars(vm: *VM, x: V) V {
  const id = vm.mapFile(x.C.slice()) catch return V{ .err = .io };
  return readDataById(vm, V{ .i = @intCast(id) });
}
fn readDataById(vm: *VM, x: V) V {
  return vm.eval(vm.fs.getFileText(@as(u32, @intCast(x.i)))) catch return V{ .err = .io };
}

pub const ReadData = struct {
  pub const op = .@"2:";
  _s: VM.MonadFn = readDataBySymbol,
  _C: VM.MonadFn = readDataByChars,
  _i: VM.MonadFn = readDataById,
};

// ---------------------------------------------------------------------------
// WriteData  2: (dyad)
// ---------------------------------------------------------------------------

fn writeDataOrFfi(vm: *VM, lib_path: []const u8, y: V) V {
  // Intercept: "lib.so" 2: (`sym; arity)  →  load FFI function
  if (y.tag() == .L) {
    const sl = y.L.slice();
    if (sl.len == 2 and sl[0].tag() == .s and sl[1].tag() == .i) {
      const sym_name = vm.getSymbol(sl[0].s);
      const arity: u8 = @intCast(@max(0, @min(8, sl[1].i)));
      return @import("../../ffi.zig").ffiLoad(vm, lib_path, sym_name, arity);
    }
  }
  const id = vm.mapFile(lib_path) catch return V{ .err = .io };
  return writeDataFallback(vm, V{ .i = @intCast(id) }, y);
}
fn writeDataBySymbol(vm: *VM, x: V, y: V) V {
  return writeDataOrFfi(vm, vm.getSymbol(x.s), y);
}
fn writeDataByChars(vm: *VM, x: V, y: V) V {
  return writeDataOrFfi(vm, x.C.slice(), y);
}

pub const WriteData = struct {
  pub const op = .@"2:";
  _s_I: VM.DyadFn = writeDataBySymbol,
  _s_F: VM.DyadFn = writeDataBySymbol,
  _s_S: VM.DyadFn = writeDataBySymbol,
  _s_C: VM.DyadFn = writeDataBySymbol,
  _s_B: VM.DyadFn = writeDataBySymbol,
  _s_L: VM.DyadFn = writeDataBySymbol,
  _s_m: VM.DyadFn = writeDataBySymbol,
  _s_M: VM.DyadFn = writeDataBySymbol,
  _s_a: VM.DyadFn = writeDataBySymbol,
  _C_I: VM.DyadFn = writeDataByChars,
  _C_F: VM.DyadFn = writeDataByChars,
  _C_S: VM.DyadFn = writeDataByChars,
  _C_C: VM.DyadFn = writeDataByChars,
  _C_B: VM.DyadFn = writeDataByChars,
  _C_L: VM.DyadFn = writeDataByChars,
  _C_m: VM.DyadFn = writeDataByChars,
  _C_M: VM.DyadFn = writeDataByChars,
  _C_a: VM.DyadFn = writeDataByChars,
  _i_I: VM.DyadFn = writeDataFallback,
  _i_F: VM.DyadFn = writeDataFallback,
  _i_S: VM.DyadFn = writeDataFallback,
  _i_C: VM.DyadFn = writeDataFallback,
  _i_B: VM.DyadFn = writeDataFallback,
  _i_L: VM.DyadFn = writeDataFallback,
  _i_m: VM.DyadFn = writeDataFallback,
  _i_M: VM.DyadFn = writeDataFallback,
  _i_a: VM.DyadFn = writeDataFallback,
};

pub fn writeDataFallback(vm: *VM, x: V, y: V) V {
  const id = @as(u32, @intCast(x.i));
  var mock = util.MockWriter.init(vm.alloc) catch return V{ .err = .memory };
  defer mock.deinit();
  var formatter = format.TerseFormatter.init(vm, vm.alloc, .Text);
  var w = mock.writer();
  formatter.formatter().fmt(y, &w.interface) catch return V{ .err = .io };
  writeFile(vm, id, mock.getText()) catch return V{ .err = .io };
  return .blank;
}
