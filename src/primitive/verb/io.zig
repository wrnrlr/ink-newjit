const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const format = @import("../../noun/format.zig");
const util = @import("../../util.zig");
const V = value.V;

fn writeFile(vm: *VM, id: u32, content: []const u8) !void {
  if (vm.registry.getPath(id)) |path| {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, content, 0);
  }
  try vm.registry.updateFile(id, content);
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
  const text = vm.registry.getFileText(@as(u32, @intCast(x.i)));
  var list = std.ArrayList(V).initCapacity(vm.alloc, 0) catch return V{ .err = .memory };
  defer list.deinit(vm.alloc);
  var iter = std.mem.splitScalar(u8, text, '\n');
  while (iter.next()) |line| {
    const s = V.charsFromSlice(vm.alloc, line) catch return V{ .err = .memory };
    list.append(vm.alloc, s) catch return V{ .err = .memory };
  }
  return V.valuesFromSlice(vm.alloc, list.items) catch return V{ .err = .memory };
}

pub const ReadLines = struct {
  pub const op = .@"0:";
  _s: util.MonadFn = readLinesBySymbol,
  _C: util.MonadFn = readLinesByChars,
  _i: util.MonadFn = readLinesById,
};

// ---------------------------------------------------------------------------
// WriteLines  0: (dyad)
// ---------------------------------------------------------------------------

fn writeLinesConsole(vm: *VM, _: V, y: V) V {
  if (y.tag() == .C) {
    vm.print("{s}\n", .{y.C.slice()});
    return y.ref();
  }
  if (y.tag() == .s) {
    vm.print("{s}\n", .{vm.getSymbol(y.s)});
    return y.ref();
  }
  if (y.tag() == .L) {
    for (y.L.slice(), 0..) |item, i| {
      if (i > 0) vm.print("\n", .{});
      if (item.tag() == .C) vm.print("{s}", .{item.C.slice()})
      else if (item.tag() == .s) vm.print("{s}", .{vm.getSymbol(item.s)});
    }
    vm.print("\n", .{});
    return y.ref();
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
  return y.ref();
}

pub const WriteLines = struct {
  pub const op = .@"0:";
  _blank_x: util.DyadFn = writeLinesConsole,
  _s_L: util.DyadFn = writeLinesBySymbol,
  _s_C: util.DyadFn = writeLinesBySymbol,
  _s_s: util.DyadFn = writeLinesBySymbol,
  _C_L: util.DyadFn = writeLinesByChars,
  _C_C: util.DyadFn = writeLinesByChars,
  _C_s: util.DyadFn = writeLinesByChars,
  _i_L: util.DyadFn = writeLinesById_L,
  _i_C: util.DyadFn = writeLinesById_C,
  _i_s: util.DyadFn = writeLinesById_s,
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
  return V.charsFromSlice(vm.alloc, vm.registry.getFileText(@as(u32, @intCast(x.i)))) catch return V{ .err = .memory };
}

pub const ReadBytes = struct {
  pub const op = .@"1:";
  _s: util.MonadFn = readBytesBySymbol,
  _C: util.MonadFn = readBytesByChars,
  _i: util.MonadFn = readBytesById,
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
  return y.ref();
}

pub const WriteBytes = struct {
  pub const op = .@"1:";
  _s_C: util.DyadFn = writeBytesBySymbol,
  _C_C: util.DyadFn = writeBytesByChars,
  _i_C: util.DyadFn = writeBytesByHandle,
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
  return vm.eval(vm.registry.getFileText(@as(u32, @intCast(x.i)))) catch return V{ .err = .io };
}

pub const ReadData = struct {
  pub const op = .@"2:";
  _s: util.MonadFn = readDataBySymbol,
  _C: util.MonadFn = readDataByChars,
  _i: util.MonadFn = readDataById,
};

// ---------------------------------------------------------------------------
// WriteData  2: (dyad)
// ---------------------------------------------------------------------------

fn writeDataBySymbol(vm: *VM, x: V, y: V) V {
  const id = vm.mapFile(vm.getSymbol(x.s)) catch return V{ .err = .io };
  return writeDataFallback(vm, V{ .i = @intCast(id) }, y);
}
fn writeDataByChars(vm: *VM, x: V, y: V) V {
  const id = vm.mapFile(x.C.slice()) catch return V{ .err = .io };
  return writeDataFallback(vm, V{ .i = @intCast(id) }, y);
}

pub const WriteData = struct {
  pub const op = .@"2:";
  _s_I: util.DyadFn = writeDataBySymbol,
  _s_F: util.DyadFn = writeDataBySymbol,
  _s_S: util.DyadFn = writeDataBySymbol,
  _s_C: util.DyadFn = writeDataBySymbol,
  _s_B: util.DyadFn = writeDataBySymbol,
  _s_L: util.DyadFn = writeDataBySymbol,
  _s_m: util.DyadFn = writeDataBySymbol,
  _s_M: util.DyadFn = writeDataBySymbol,
  _s_a: util.DyadFn = writeDataBySymbol,
  _C_I: util.DyadFn = writeDataByChars,
  _C_F: util.DyadFn = writeDataByChars,
  _C_S: util.DyadFn = writeDataByChars,
  _C_C: util.DyadFn = writeDataByChars,
  _C_B: util.DyadFn = writeDataByChars,
  _C_L: util.DyadFn = writeDataByChars,
  _C_m: util.DyadFn = writeDataByChars,
  _C_M: util.DyadFn = writeDataByChars,
  _C_a: util.DyadFn = writeDataByChars,
  _i_I: util.DyadFn = writeDataFallback,
  _i_F: util.DyadFn = writeDataFallback,
  _i_S: util.DyadFn = writeDataFallback,
  _i_C: util.DyadFn = writeDataFallback,
  _i_B: util.DyadFn = writeDataFallback,
  _i_L: util.DyadFn = writeDataFallback,
  _i_m: util.DyadFn = writeDataFallback,
  _i_M: util.DyadFn = writeDataFallback,
  _i_a: util.DyadFn = writeDataFallback,
};

pub fn writeDataFallback(vm: *VM, x: V, y: V) V {
  const id = @as(u32, @intCast(x.i));
  var mock = util.MockWriter.init(vm.alloc) catch return V{ .err = .memory };
  defer mock.deinit();
  var formatter = format.TerseFormatter.init(vm, vm.alloc, .Text);
  var w = mock.writer();
  formatter.formatter().format(y, &w.interface) catch return V{ .err = .io };
  writeFile(vm, id, mock.getText()) catch return V{ .err = .io };
  return y.ref();
}
