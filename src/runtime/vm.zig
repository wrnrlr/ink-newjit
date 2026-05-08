const std = @import("std");
const Alloc = std.mem.Allocator;
const Parser = @import("../parser/ast.zig").Parser;
const Chunk = @import("tape.zig").Chunk;
const OpCode = @import("tape.zig").OpCode;
const Op = @import("tape.zig").Op;
const Compiler = @import("compiler.zig").Compiler;
const Registry = @import("registry.zig").Registry;
const value = @import("../noun/value.zig");
const GpuCtx = @import("gpu").GpuCtx;
const command = @import("command.zig");
const V = value.V;
const N = value.N;
const K = @import("../noun/class.zig").K;
const Partial = @import("../noun/partial.zig").Partial;
const opmod = @import("../noun/operator.zig");
const Fn = opmod.Fn;
const Adverb = opmod.Adverb;
const FnKind = opmod.FnKind;
const FnTables = @import("fntable.zig").FnTables;
const Pool = @import("../noun/symbol.zig").Pool;
const assert = std.debug.assert;
const verb_enlist = @import("../primitive/verb/enlist.zig");
const call = @import("call.zig");
const amend = @import("../primitive/amend.zig");
const pair = @import("../primitive/verb/pair.zig");
const promote = @import("../primitive/promote.zig").promote;
const dispatch = @import("../primitive/dispatch.zig");
const TerseFormatter = @import("../noun/format.zig").TerseFormatter;
const MockWriter = @import("../util.zig").MockWriter;
const ext_mod = @import("plugin.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");
// JIT is only available on arm64/macOS; the flag is silently ignored elsewhere.
const jit_enabled = build_options.enable_jit and
    builtin.cpu.arch == .aarch64 and
    builtin.os.tag == .macos;
const jit_mod = if (jit_enabled) @import("jit/jit.zig") else struct {};

const STACK_MAX = 2048;
const FRAMES_MAX = 64;

pub const VMError = error{ StackOverflow, InvalidOpCode, RuntimeError };

// lambda_idx = maxInt(u24) for top-level (no lambda)
const NO_LAMBDA: u24 = std.math.maxInt(u24);

const Frame = struct {
  ip:          usize = 0,
  base:        usize,
  result_slot: usize,
  lambda_idx:  u24,
};

pub const VM = struct {
  alloc: Alloc,
  gpu: ?*GpuCtx = null,
  parser: ?*Parser,
  compiler: *Compiler,
  chunk: *Chunk,
  // Fixed-capacity value stack — avoids per-push allocation after VM creation.
  stack:     [STACK_MAX]V  = undefined,
  stack_len: usize         = 0,
  // Fixed-capacity call frame stack.
  frames:     [FRAMES_MAX]Frame = undefined,
  frames_len: usize             = 0,
  // Pool for Partial objects (partial function applications).
  partial_pool: std.heap.MemoryPool(Partial),

  symbols: Pool,
  globals: std.ArrayListUnmanaged(V) = .empty,
  globals_names: std.StringHashMap(u8),
  current_chunk: *Chunk,
  registry: Registry,
  fn_tables: FnTables,
  ext: ext_mod.ExtRegistry,
  out: ?*std.Io.Writer = null,
  prng: std.Random.DefaultPrng,
  argv: V = .blank,
  jit:        if (jit_enabled) ?jit_mod.JitCache                    else void = if (jit_enabled) null      else {},
  jit_err:    if (jit_enabled) ?anyerror                             else void = if (jit_enabled) null      else {},
  jit_apply2: if (jit_enabled) *const fn(*VM, u8) callconv(.c) void else void = if (jit_enabled) undefined else {},
  // Monomorphic inline cache: last successfully JIT-compiled lambda.
  // Avoids a hash-map lookup on every call in hot adverb loops.
  jit_ic_key: if (jit_enabled) u24                                       else void = if (jit_enabled) NO_LAMBDA else {},
  jit_ic_jf:  if (jit_enabled) ?jit_mod.JitFn                           else void = if (jit_enabled) null      else {},

  pub fn aList(vm:VM) !V { return .{.L = try N(V).init(vm.alloc, 0)}; }
  pub fn aVec(vm:VM,k:K,n:usize) !V { return V.wrap(k.container(), try N(k.backing()).init(vm.alloc, n)); }
  
  pub fn create(alloc: Alloc) !*VM {
    const vm = try alloc.create(VM);
    const chunk = try alloc.create(Chunk);
    chunk.* = try Chunk.init(alloc);

    const parser = try alloc.create(Parser);
    parser.* = Parser.init(alloc);

    const symbols = Pool.init(alloc);

    vm.* = .{
      .alloc        = alloc,
      .parser       = parser,
      .compiler     = try alloc.create(Compiler),
      .chunk        = chunk,
      .current_chunk = chunk,
      .partial_pool  = std.heap.MemoryPool(Partial).empty,
      .symbols       = symbols,
      .globals_names = std.StringHashMap(u8).init(alloc),
      .registry      = try Registry.init(alloc),
      .fn_tables     = FnTables.init(alloc),
      .ext           = ext_mod.ExtRegistry.init(alloc),
      .prng          = std.Random.DefaultPrng.init(0),
    };

    vm.compiler.* = try Compiler.init(alloc, chunk, &vm.globals_names, &vm.symbols, &vm.registry, &vm.fn_tables);

    if (comptime jit_enabled) {
        vm.jit_apply2 = &JitImpl.apply2Worker;
        vm.jit = jit_mod.JitCache.init(alloc, JitImpl.buildHandlers(), JitImpl.buildStencils(), @intFromPtr(&JitImpl.jhApply2)) catch null;
    }

    std.Io.Threaded.global_single_threaded.allocator = alloc;

    // Initial frame for top-level code
    vm.pushFrame(.{ .base = 0, .result_slot = 0, .lambda_idx = NO_LAMBDA });

    return vm;
  }

  pub fn deinit(vm: *VM) void {
    vm.argv.deinit(vm.alloc);
    for (vm.stack[0..vm.stack_len]) |*v| v.deinit(vm.alloc);

    vm.compiler.deinit();
    vm.alloc.destroy(vm.compiler);

    vm.symbols.deinit();

    for (vm.globals.items) |*v| v.deinit(vm.alloc);
    vm.globals.deinit(vm.alloc);

    var kit = vm.globals_names.keyIterator(); while (kit.next()) |k| vm.alloc.free(k.*);
    vm.globals_names.deinit();

    vm.partial_pool.deinit(vm.alloc);
    vm.ext.deinit();
    vm.chunk.deinit();
    vm.alloc.destroy(vm.chunk);
    vm.registry.deinit();
    vm.fn_tables.deinit();

    if (vm.parser) |p| {
      p.deinit();
      vm.alloc.destroy(p);
    }

    if (comptime jit_enabled) {
        if (vm.jit) |*j| j.deinit();
    }

    vm.alloc.destroy(vm);
  }

  pub fn print(vm: *VM, comptime fmt: []const u8, args: anytype) void {
    if (vm.out) |out| {
      out.print(fmt, args) catch {};
      out.flush() catch {};
    } else {
      std.debug.print(fmt, args);
    }
  }

  pub fn intern(vm: *VM, s: []const u8) !u32 { return vm.symbols.intern(s); }
  pub fn getSymbol(vm: *const VM, idx: u32) []const u8 { return vm.symbols.get(idx); }
  pub fn symbolCount(vm: *const VM) usize { return vm.symbols.count(); }

  pub fn eval(vm: *VM, txt: []const u8) !V {
    const text_id = try vm.registry.addText(txt);
    return vm.interpret(txt, text_id);
  }

  pub fn load(vm: *VM, path: []const u8) !V {
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, vm.alloc, std.Io.Limit.limited(10 * 1024 * 1024));
    const text_id = try vm.registry.addFile(path, text);
    return vm.interpret(text, text_id);
  }


  pub fn interpret(vm: *VM, txt: []const u8, text_id: u32) !V {
    vm.resetStack();
    const node = try vm.parser.?.parse(txt);
    defer vm.parser.?.free(node);

    // Reset chunk code for new expression
    for (vm.chunk.constants.items) |*v| v.deinit(vm.alloc);
    vm.chunk.constants.clearRetainingCapacity();
    vm.chunk.code.clearRetainingCapacity();
    
    // Reset frames for new expression
    vm.frames_len = 0;
    vm.pushFrame(.{ .base = 0, .result_slot = 0, .lambda_idx = NO_LAMBDA });
    vm.current_chunk = vm.chunk;

    vm.compiler.scope.reset();
    vm.compiler.text_id = text_id;
    try vm.compiler.compile(node, false);
    try vm.run();

    if (vm.stack_len == 0) return .blank;
    const res = vm.pop();

    // Clear any leftovers on stack from top-level execution
    while (vm.stack_len > 0) {
      var v = vm.pop();
      v.deinit(vm.alloc);
    }

    return res;
  }

  fn executeCall(vm: *VM, func: V, incoming: []const V, mode: call.CallMode) !void {
    var fc = call.Call{ .vm = vm };
    const res = try fc.apply(func, incoming, mode == .bracket);
    try vm.push(res);
  }

  // Attempt JIT execution of the current frame.  Returns true if the JIT ran
  // (caller should `continue` its dispatch loop), false if it should interpret.
  // Returns an error if a stencil stored one in vm.jit_err during execution.
  pub fn tryJit(vm: *VM) !bool {
    if (comptime !jit_enabled) return false;
    const frame = vm.currentFrame();
    if (vm.jit == null or frame.lambda_idx == NO_LAMBDA or frame.ip != 0) return false;
    const lambda_idx = frame.lambda_idx;
    const entry = vm.fn_tables.lambdaAt(lambda_idx);
    const jf = vm.jit.?.getOrCompile(lambda_idx, entry.chunk) catch return false;
    frame.ip = jf.stop_ip;
    jf.code(@ptrCast(vm));
    if (vm.jit_err) |e| {
      vm.jit_err = null;
      return e;
    }
    return true;
  }

  // Direct lambda call without wrapper→apply overhead. Used by hot adverb loops.
  // Uses a monomorphic inline cache to skip the JIT hash-map lookup on repeat calls.
  pub fn callLambdaAndRun(vm: *VM, ref: Fn, args: []const V) V {
    const prev_frames = vm.frames_len;
    const res_slot = vm.stack_len;
    vm.push(.blank) catch return V{ .err = .memory };
    for (args) |arg| vm.push(arg.ref()) catch {
      for (vm.stack[res_slot..vm.stack_len]) |*v| v.deinit(vm.alloc);
      vm.stack_len = res_slot;
      return V{ .err = .memory };
    };
    vm.callLambda(ref, args.len, res_slot) catch {
      for (vm.stack[res_slot..vm.stack_len]) |*v| v.deinit(vm.alloc);
      vm.stack_len = res_slot;
      return V{ .err = .memory };
    };
    if (comptime jit_enabled) {
      if (vm.jit != null) {
        const lambda_idx = @as(u24, @intCast(ref.idx));
        const jf = if (vm.jit_ic_key == lambda_idx) vm.jit_ic_jf else blk: {
          const entry = vm.fn_tables.lambdaAt(lambda_idx);
          const f = vm.jit.?.getOrCompile(lambda_idx, entry.chunk) catch null;
          vm.jit_ic_key = lambda_idx;
          vm.jit_ic_jf = f;
          break :blk f;
        };
        if (jf) |j| {
          vm.currentFrame().ip = j.stop_ip;
          j.code(@ptrCast(vm));
          if (vm.jit_err != null) vm.jit_err = null;
          if (j.complete) return vm.pop();
        }
      }
    }
    while (vm.frames_len > prev_frames) {
      if (vm.tryJit() catch false) continue;
      const b = vm.readByte();
      vm.runOp(@enumFromInt(b)) catch {};
    }
    return vm.pop();
  }

  fn run(vm: *VM) !void {
    while (vm.frames_len > 0 and vm.currentFrame().ip < vm.current_chunk.code.items.len) {
      if (try vm.tryJit()) continue;
      try op_table[vm.readByte()](vm);
    }
  }

  pub fn runOp(vm: *VM, opCode: OpCode) !void {
    try op_table[@intFromEnum(opCode)](vm);
  }
  
  fn doConst(vm: *VM) !void {
    const idx = vm.readByte();
    const v = vm.current_chunk.constants.items[idx];
    try vm.push(v.ref());
  }
  
  fn doGlobal(vm: *VM) !void {
    const idx = vm.readByte();
    while (vm.globals.items.len <= idx) try vm.globals.append(vm.alloc, .blank);
    const v = vm.globals.items[idx];
    try vm.push(v.ref());
  }
  
  fn doInt(vm: *VM) !void {
    const raw = vm.read16();
    const v: i32 = @as(i16, @bitCast(raw));
    try vm.push(.{ .i = v });
  }

  fn doLocal(vm: *VM) !void {
    const idx = vm.readByte();
    const v = vm.stack[vm.currentFrame().base + idx];
    try vm.push(v.ref());
  }

  // Last use of a local: steal the value from the slot (clear it, push without
  // incrementing RC).  The slot becomes .blank so Return's cleanup is a no-op.
  fn doLocalLast(vm: *VM) !void {
    const idx = vm.readByte();
    const slot = vm.currentFrame().base + idx;
    const v = vm.stack[slot];
    vm.stack[slot] = .blank;
    try vm.push(v);
  }
  
  fn doAssignGlobal(vm: *VM) !void {
    const index = vm.readByte();
    const val = vm.pop();
    while (vm.globals.items.len <= index) try vm.globals.append(vm.alloc, .blank);
    vm.globals.items[index].deinit(vm.alloc);
    vm.globals.items[index] = val;
    try vm.push(.blank);
  }
  
  fn doAssignLocal(vm: *VM) !void {
    const index = vm.readByte();
    const val = vm.pop();
    const stack_idx = vm.currentFrame().base + index;
    vm.stack[stack_idx].deinit(vm.alloc);
    vm.stack[stack_idx] = val;
    try vm.push(.blank);
  }
  
  fn doListAssignGlobal(vm: *VM) !void {
    const n = vm.readByte();
    const val = vm.pop();
    defer val.deinit(vm.alloc);
    const vlen = val.len();
    const is_atom = std.meta.activeTag(val).isAtom();
    if (vlen != n and !is_atom) {
      try vm.push(.{ .err = .length });
      for (0..n) |_| _ = vm.readByte();
    } else {
      for (0..n) |i| {
        const index = vm.readByte();
        while (vm.globals.items.len <= index) try vm.globals.append(vm.alloc, .blank);
        vm.globals.items[index].deinit(vm.alloc);
        vm.globals.items[index] = val.at(i);
      }
      try vm.push(.blank);
    }
  }

  fn doListAssignLocal(vm: *VM) !void {
    const n = vm.readByte();
    const val = vm.pop();
    defer val.deinit(vm.alloc);
    const vlen = val.len();
    const is_atom = std.meta.activeTag(val).isAtom();
    if (vlen != n and !is_atom) {
      try vm.push(.{ .err = .length });
      for (0..n) |_| _ = vm.readByte();
    } else {
      for (0..n) |i| {
        const index = vm.readByte();
        const stack_idx = vm.currentFrame().base + index;
        vm.stack[stack_idx].deinit(vm.alloc);
        vm.stack[stack_idx] = val.at(i);
      }
      try vm.push(.blank);
    }
  }
  
  fn doJump(vm: *VM) !void {
    const offset = vm.read16();
    vm.currentFrame().ip += offset;
  }
  
  fn doJumpWhen(vm: *VM, comptime cond: bool) !void {
    const offset = vm.read16();
    const v = vm.pop();
    defer v.deinit(vm.alloc);
    if (v.isTrue()==cond) vm.currentFrame().ip += offset;
  }

  fn doReturn(vm: *VM) !void {
    const result = vm.pop();
    const frame = vm.popFrame();
    assert(vm.stack_len >= frame.base);

    if (vm.frames_len == 0) {
      for (vm.stack[0..vm.stack_len]) |*v| v.deinit(vm.alloc);
      vm.stack_len = 0;
      try vm.push(result);
      return;
    }
    const parent_idx = vm.currentFrame().lambda_idx;
    vm.current_chunk = if (parent_idx != NO_LAMBDA)
      vm.fn_tables.lambdaAt(parent_idx).chunk
    else vm.chunk;

    for (vm.stack[frame.result_slot..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = frame.result_slot;
    try vm.push(result);
  }

  fn doTailCall(vm: *VM) !void {
    const argc = vm.readByte();
    var buf: [8]V = .{.blank} ** 8;
    const incoming = buf[0..argc];
    for (0..argc) |i| incoming[argc - 1 - i] = vm.pop();
    const func_val = vm.pop();
    defer func_val.deinit(vm.alloc);

    if (func_val == .func and func_val.func.getKind() == .lambda) {
      const lambda_idx = @as(u24, @intCast(func_val.func.idx));
      const entry = vm.fn_tables.lambdaAt(lambda_idx);
      const frame = vm.currentFrame();
      const res_slot = frame.result_slot;

      for (vm.stack[res_slot..vm.stack_len]) |*v| v.deinit(vm.alloc);
      vm.stack_len = res_slot;

      try vm.push(.blank);
      for (incoming) |arg| try vm.push(arg);
      const total_slots = @as(usize, entry.arity) + @as(usize, entry.locals);
      const locals_to_push = if (total_slots > argc) total_slots - argc else 0;
      for (0..locals_to_push) |_| try vm.push(.blank);

      frame.lambda_idx = lambda_idx;
      frame.ip = 0;
      frame.base = vm.stack_len - argc - locals_to_push;
      vm.current_chunk = entry.chunk;
    } else {
      try vm.executeCall(func_val, incoming, .sync);
      for (incoming) |*v| v.deinit(vm.alloc);
    }
  }

  fn doCall(vm: *VM) !void {
    try vm.doCallWithMode(.sync);
  }

  fn doApply(vm: *VM) !void {
    try vm.doCallWithMode(.bracket);
  }

  fn doCallWithMode(vm: *VM, mode: call.CallMode) !void {
    const argc = vm.readByte();
    const incoming = try vm.alloc.alloc(V, argc);
    defer vm.alloc.free(incoming);
    for (0..argc) |i| incoming[argc - 1 - i] = vm.pop();
    const func_val = vm.pop();
    try vm.executeCall(func_val, incoming, mode);
    for (incoming) |*v| v.deinit(vm.alloc);
    func_val.deinit(vm.alloc);
  }
  
  fn doApply1(vm: *VM) !void {
    const op: Op = @enumFromInt(vm.readByte());
    const a = vm.pop();
    defer a.deinit(vm.alloc);
    try vm.push(dispatch.dispatch1(vm, op, a));
  }

  fn doApply2(vm: *VM) !void {
    const op: Op = @enumFromInt(vm.readByte());
    const b = vm.pop();
    defer b.deinit(vm.alloc);
    const a = vm.pop();
    defer a.deinit(vm.alloc);
    try vm.push(dispatch.dispatch2(vm, op, a, b));
  }

  fn doAmend(vm: *VM) !void {
    const argc = vm.readByte();
    const start = vm.stack_len - argc;
    const res = try amend.amend(vm, vm.stack[start..vm.stack_len]);
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(res);
  }

  fn doDmend(vm: *VM) !void {
    const argc = vm.readByte();
    const start = vm.stack_len - argc;
    const res = try amend.dmend(vm, vm.stack[start..vm.stack_len]);
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(res);
  }
  
  fn doMakePartial(vm: *VM) !void {
    const argc = vm.readByte();
    const mask = vm.readByte();
    const args_start = vm.stack_len - argc;
    const stack_args = vm.stack[args_start..vm.stack_len];
    const func_val = vm.stack[args_start - 1];

    // Extract base func and existing args from func (possibly already a partial)
    var base_ref: Fn = undefined;
    var existing: [8]V = .{.blank} ** 8;
    var existing_fill: u8 = 0;
    if (func_val == .partial) {
      const p = func_val.asPartial();
      base_ref = p.ref;
      existing = p.args;
      existing_fill = p.fill;
    } else if (func_val == .func) {
      base_ref = func_val.func;
    } else {
      for (vm.stack[args_start - 1 .. vm.stack_len]) |*v| v.deinit(vm.alloc);
      vm.stack_len = args_start - 1;
      return vm.push(V{ .err = .@"type" });
    }

    const arity = base_ref.getRealArity();
    var merged: [8]V = .{.blank} ** 8;
    var fill: u8 = 0;
    for (0..arity) |i| {
      if (existing_fill & (@as(u8, 1) << @intCast(i)) != 0) {
        merged[i] = existing[i].ref();
        fill |= @as(u8, 1) << @intCast(i);
      }
    }
    var arg_idx: usize = 0;
    for (0..arity) |i| {
      if (fill & (@as(u8, 1) << @intCast(i)) == 0) {
        const should_fill = if (existing_fill != 0) true else ((mask >> @intCast(i)) & 1) != 0;
        if (should_fill and arg_idx < argc) {
          merged[i] = stack_args[arg_idx].ref();
          fill |= @as(u8, 1) << @intCast(i);
          arg_idx += 1;
        }
      }
    }

    const p = try vm.partial_pool.create(vm.alloc);
    p.* = .{ .pool = &vm.partial_pool, .rc = 1, .fill = fill, .arity = arity, ._pad = 0, .ref = base_ref, .args = merged };

    for (vm.stack[args_start - 1 .. vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = args_start - 1;
    try vm.push(V{ .partial = p });
  }

  fn doDerive(vm: *VM) !void {
    const adv: Adverb = @enumFromInt(vm.readByte());
    const base_v = vm.pop();
    const derived: Fn = if (base_v == .func) blk: {
      const ref = base_v.func;
      base_v.deinit(vm.alloc);
      break :blk switch (ref.getKind()) {
        .builtin => Fn.makeDerivedBuiltin(ref.getOp(), adv),
        .lambda  => Fn.makeDerivedLambda(ref.idx, adv),
        else => blk2: {
          const idx = try vm.fn_tables.addDerived(.{ .base = V{ .func = ref }, .adverb = adv });
          break :blk2 Fn.makeDerivedTable(idx);
        },
      };
    } else blk: {
      // Data base (e.g. I vector for radix encode/decode, C for join/split)
      const idx = try vm.fn_tables.addDerived(.{ .base = base_v, .adverb = adv });
      break :blk Fn.makeDerivedTable(idx);
    };
    try vm.push(V{ .func = derived });
  }
  
  fn doMakeList(vm: *VM) !void {
    const argc = vm.readByte();
    const start = vm.stack_len - argc;
    const values = vm.stack[start..vm.stack_len];
    const list_val = try V.valuesFromSlice(vm.alloc, values);
    for (values) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(list_val);
  }

  fn doMakeDict(vm: *VM) !void {
    const n = vm.readByte();
    const start = vm.stack_len - 2 * n;
    const keys = if (n == 1) vm.stack[start].ref()
                 else promote(vm.alloc, (try V.valuesFromSlice(vm.alloc, vm.stack[start .. start + n])).L);
    var keys_live = n > 1;
    errdefer { if (keys_live) keys.deinit(vm.alloc); }
    const vals = if (n == 1) vm.stack[start + 1].ref()
                 else promote(vm.alloc, (try V.valuesFromSlice(vm.alloc, vm.stack[start + n .. start + 2 * n])).L);
    var vals_live = n > 1;
    errdefer { if (vals_live) vals.deinit(vm.alloc); }
    const res = if (n == 1) V{ .m = try value.Dict.init(vm.alloc, keys, vals) }
                else pair.dict(vm, keys, vals);
    errdefer res.deinit(vm.alloc);
    if (n > 1) { keys.deinit(vm.alloc); keys_live = false; vals.deinit(vm.alloc); vals_live = false; }
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(res);
  }

  fn doMakeTable(vm: *VM) !void {
    const n = vm.readByte();
    const start = vm.stack_len - 2 * n;
    const keys = if (n == 1) verb_enlist.enlist(vm.alloc, vm.stack[start])
                 else promote(vm.alloc, (try V.valuesFromSlice(vm.alloc, vm.stack[start .. start + n])).L);
    const vals = if (n == 1) verb_enlist.enlist(vm.alloc, vm.stack[start + 1])
                 else promote(vm.alloc, (try V.valuesFromSlice(vm.alloc, vm.stack[start + n .. start + 2 * n])).L);
    const res = V{ .M = try value.Dict.init(vm.alloc, keys, vals) };
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(res);
  }
  
  fn doCommand(vm: *VM) anyerror!void {
    var cmd_v = vm.pop();
    defer cmd_v.deinit(vm.alloc);
    const bytes = cmd_v.C.slice();
    // bytes is verb\0args
    const sep = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    const verb = bytes[0..sep];
    const args = if (sep < bytes.len) std.mem.trim(u8, bytes[sep + 1 ..], " \t") else "";
    try command.exec(vm, verb, args);
    try vm.push(.blank);
  }


  pub fn callLambda(vm: *VM, ref: Fn, argc: usize, res_slot: usize) !void {
    if (vm.frames_len >= FRAMES_MAX) return VMError.StackOverflow;
    const lambda_idx = @as(u24, @intCast(ref.idx));
    const entry = vm.fn_tables.lambdaAt(lambda_idx);

    const total_slots = @as(usize, entry.arity) + @as(usize, entry.locals);
    const locals_to_push = if (total_slots > argc) total_slots - argc else 0;
    for (0..locals_to_push) |_| try vm.push(.blank);

    vm.pushFrame(.{
      .lambda_idx  = lambda_idx,
      .base        = vm.stack_len - argc - locals_to_push,
      .result_slot = res_slot,
    });

    vm.current_chunk = entry.chunk;
  }
  
  pub fn mapFile(vm: *VM, path: []const u8) !u32 {
    if (vm.registry.findFile(path)) |id| return id;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, vm.alloc, std.Io.Limit.limited(10 * 1024 * 1024));
    return try vm.registry.addFile(path, text);
  }

  pub inline fn pushFrame(vm: *VM, frame: Frame) void {
    vm.frames[vm.frames_len] = frame;
    vm.frames_len += 1;
  }

  pub inline fn popFrame(vm: *VM) Frame {
    vm.frames_len -= 1;
    return vm.frames[vm.frames_len];
  }

  pub inline fn currentFrame(vm: *VM) *Frame { return &vm.frames[vm.frames_len - 1]; }

  pub fn readByte(vm: *VM) u8 {
    const frame = vm.currentFrame();
    const byte = vm.current_chunk.code.items[frame.ip];
    frame.ip += 1;
    return byte;
  }

  pub fn read16(vm: *VM) u16 {
    const low = @as(u16, vm.readByte());
    const high = @as(u16, vm.readByte());
    return low | (high << 8);
  }

  pub fn push(vm: *VM, v: V) !void {
    if (vm.stack_len >= STACK_MAX) return VMError.StackOverflow;
    vm.stack[vm.stack_len] = v;
    vm.stack_len += 1;
  }

  pub fn pop(vm: *VM) V {
    vm.stack_len -= 1;
    return vm.stack[vm.stack_len];
  }

  fn resetStack(vm: *VM) void {
    for (vm.stack[0..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = 0;
  }

  fn peek(vm: *VM, distance: usize) V { return vm.stack[vm.stack_len - 1 - distance]; }
};

fn opNop(_: *VM) anyerror!void {}
fn opGap(vm: *VM) anyerror!void { try vm.push(.blank); }
fn opDrop(vm: *VM) anyerror!void { vm.pop().deinit(vm.alloc); }
fn opJumpFalse(vm: *VM) anyerror!void { try vm.doJumpWhen(false); }
fn opJumpTrue(vm: *VM) anyerror!void  { try vm.doJumpWhen(true); }

const OpHandler = *const fn(*VM) anyerror!void;
const op_table: [OpCode.COUNT]OpHandler = build: {
  var t: [OpCode.COUNT]OpHandler = undefined;
  t[@intFromEnum(OpCode.Nop)]              = &opNop;
  t[@intFromEnum(OpCode.Gap)]              = &opGap;
  t[@intFromEnum(OpCode.Drop)]             = &opDrop;
  t[@intFromEnum(OpCode.Const)]            = &VM.doConst;
  t[@intFromEnum(OpCode.Int)]              = &VM.doInt;
  t[@intFromEnum(OpCode.Global)]           = &VM.doGlobal;
  t[@intFromEnum(OpCode.Local)]            = &VM.doLocal;
  t[@intFromEnum(OpCode.LocalLast)]        = &VM.doLocalLast;
  t[@intFromEnum(OpCode.AssignGlobal)]     = &VM.doAssignGlobal;
  t[@intFromEnum(OpCode.AssignLocal)]      = &VM.doAssignLocal;
  t[@intFromEnum(OpCode.ListAssignGlobal)] = &VM.doListAssignGlobal;
  t[@intFromEnum(OpCode.ListAssignLocal)]  = &VM.doListAssignLocal;
  t[@intFromEnum(OpCode.Jump)]             = &VM.doJump;
  t[@intFromEnum(OpCode.JumpFalse)]        = &opJumpFalse;
  t[@intFromEnum(OpCode.JumpTrue)]         = &opJumpTrue;
  t[@intFromEnum(OpCode.Apply1)]           = &VM.doApply1;
  t[@intFromEnum(OpCode.Apply2)]           = &VM.doApply2;
  t[@intFromEnum(OpCode.Return)]           = &VM.doReturn;
  t[@intFromEnum(OpCode.Call)]             = &VM.doCall;
  t[@intFromEnum(OpCode.TailCall)]         = &VM.doTailCall;
  t[@intFromEnum(OpCode.Apply)]            = &VM.doApply;
  t[@intFromEnum(OpCode.MakeList)]         = &VM.doMakeList;
  t[@intFromEnum(OpCode.MakePartial)]      = &VM.doMakePartial;
  t[@intFromEnum(OpCode.Derive)]           = &VM.doDerive;
  t[@intFromEnum(OpCode.Amend)]            = &VM.doAmend;
  t[@intFromEnum(OpCode.Dmend)]            = &VM.doDmend;
  t[@intFromEnum(OpCode.MakeDict)]         = &VM.doMakeDict;
  t[@intFromEnum(OpCode.MakeTable)]        = &VM.doMakeTable;
  t[@intFromEnum(OpCode.Command)]          = &VM.doCommand;
  break :build t;
};

// ── JIT implementation (arm64/macOS, -Djit only) ──────────────────────────
// Compiles out entirely when jit_enabled = false, keeping the non-JIT binary
// free of arm64 inline assembly and the JIT allocation overhead.

const JitImpl = if (jit_enabled) struct {
    const stencils_mod = @import("jit/stencils.zig");

    // ── Handler stubs ────────────────────────────────────────────────────────
    // Mirror the interpreter do* methods but accept operands directly so the
    // JIT can call them without a bytecode stream.

    fn jhGap(vm: *VM) callconv(.c) void { vm.push(.blank) catch {}; }
    fn jhDrop(vm: *VM) callconv(.c) void { vm.pop().deinit(vm.alloc); }
    fn jhInt(vm: *VM, raw: u16) callconv(.c) void {
        vm.push(.{ .i = @as(i32, @as(i16, @bitCast(raw))) }) catch {};
    }
    fn jhConst(vm: *VM, idx: u8) callconv(.c) void {
        vm.push(vm.current_chunk.constants.items[idx].ref()) catch {};
    }
    fn jhGlobal(vm: *VM, idx: u8) callconv(.c) void {
        while (vm.globals.items.len <= idx) vm.globals.append(vm.alloc, .blank) catch return;
        vm.push(vm.globals.items[idx].ref()) catch {};
    }
    fn jhLocal(vm: *VM, slot: u8) callconv(.c) void {
        vm.push(vm.stack[vm.currentFrame().base + slot].ref()) catch {};
    }
    fn jhLocalLast(vm: *VM, slot: u8) callconv(.c) void {
        const i = vm.currentFrame().base + slot;
        const v = vm.stack[i];
        vm.stack[i] = .blank;
        vm.push(v) catch {};
    }
    fn jhAssignGlobal(vm: *VM, idx: u8) callconv(.c) void {
        const val = vm.pop();
        while (vm.globals.items.len <= idx) vm.globals.append(vm.alloc, .blank) catch return;
        vm.globals.items[idx].deinit(vm.alloc);
        vm.globals.items[idx] = val;
        vm.push(.blank) catch {};
    }
    fn jhAssignLocal(vm: *VM, slot: u8) callconv(.c) void {
        const val = vm.pop();
        const i = vm.currentFrame().base + slot;
        vm.stack[i].deinit(vm.alloc);
        vm.stack[i] = val;
        vm.push(.blank) catch {};
    }
    fn jhApply1(vm: *VM, op: u8) callconv(.c) void {
        const a = vm.pop(); defer a.deinit(vm.alloc);
        vm.push(dispatch.dispatch1(vm, @enumFromInt(op), a)) catch {};
    }
    fn jhApply2(vm: *VM, op: u8) callconv(.c) void {
        const b = vm.pop(); defer b.deinit(vm.alloc);
        const a = vm.pop(); defer a.deinit(vm.alloc);
        vm.push(dispatch.dispatch2(vm, @enumFromInt(op), a, b)) catch {};
    }
    fn jhJump(vm: *VM, offset: u16) callconv(.c) void { vm.currentFrame().ip += offset; }
    fn jhJumpFalse(vm: *VM, offset: u16) callconv(.c) void {
        const v = vm.pop(); defer v.deinit(vm.alloc);
        if (!v.isTrue()) vm.currentFrame().ip += offset;
    }
    fn jhJumpTrue(vm: *VM, offset: u16) callconv(.c) void {
        const v = vm.pop(); defer v.deinit(vm.alloc);
        if (v.isTrue()) vm.currentFrame().ip += offset;
    }
    fn jhReturn(vm: *VM) callconv(.c) void { vm.doReturn() catch {}; }

    // ── apply2Worker ─────────────────────────────────────────────────────────
    // Called indirectly from stencilApply2 via vm.jit_apply2 (LDR+BLR).
    // Being a regular function it can BL freely; errors go to vm.jit_err.
    fn apply2Worker(vm: *VM, op: u8) callconv(.c) void {
        const b = vm.pop(); defer b.deinit(vm.alloc);
        const a = vm.pop(); defer a.deinit(vm.alloc);
        vm.push(dispatch.dispatch2(vm, @enumFromInt(op), a, b)) catch {};
    }

    // ── CPS stencil functions ────────────────────────────────────────────────
    // Each stencil is a LEAF (no BLR) so the tail-call chain via BR X8 works.
    // NEXT hole  = MOVZ/MOVK×3/BR X8 at the end, patched to the next stencil.
    // OPERAND hole = MOVZ X1, #0xFFFF, patched with the actual operand.

    // Inline ref for stencil leaves — avoids BL to the normal ref() helper.
    // Skips ExtObj (.x) so the function stays a leaf.
    inline fn stencilRef(v: V) V {
        switch (v) {
            .I  => |n| { if (n.ptr.rc != std.math.maxInt(u32)) n.ptr.rc += 1; },
            inline .B, .F, .S, .C, .L => |n| n.ptr.rc += 1,
            inline .m, .M => |n| n.ptr.rc += 1,
            .partial => |p| p.rc += 1,
            else => {},
        }
        return v;
    }

    fn stencilGap(vm: *VM) callconv(.c) void {
        vm.stack[vm.stack_len] = .blank;
        vm.stack_len += 1;
        asm volatile (
            \\.inst 0xD2800008   // MOVZ X8, #0      — NEXT hole word 0
            \\.inst 0xF2A00008   // MOVK X8, #0, LSL 16
            \\.inst 0xF2C00008   // MOVK X8, #0, LSL 32
            \\.inst 0xF2E00008   // MOVK X8, #0, LSL 48
            \\.inst 0xD61F0100   // BR X8
            ::: .{ .x8 = true }
        );
        unreachable;
    }

    fn stencilInt(vm: *VM) callconv(.c) void {
        var raw: u32 = undefined;
        asm volatile (
            \\.inst 0xD29FFFE1   // MOVZ X1, #0xFFFF — OPERAND hole
            : [o] "={x1}" (raw)
        );
        vm.stack[vm.stack_len] = .{ .i = @as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw))))) };
        vm.stack_len += 1;
        asm volatile (
            \\.inst 0xD2800008
            \\.inst 0xF2A00008
            \\.inst 0xF2C00008
            \\.inst 0xF2E00008
            \\.inst 0xD61F0100
            ::: .{ .x8 = true }
        );
        unreachable;
    }

    fn stencilLocal(vm: *VM) callconv(.c) void {
        var slot: u32 = undefined;
        asm volatile (
            \\.inst 0xD29FFFE1   // MOVZ X1, #0xFFFF — OPERAND hole
            : [o] "={x1}" (slot)
        );
        const frame = &vm.frames[vm.frames_len - 1];
        const val = stencilRef(vm.stack[frame.base + slot]);
        vm.stack[vm.stack_len] = val;
        vm.stack_len += 1;
        asm volatile (
            \\.inst 0xD2800008
            \\.inst 0xF2A00008
            \\.inst 0xF2C00008
            \\.inst 0xF2E00008
            \\.inst 0xD61F0100
            ::: .{ .x8 = true }
        );
        unreachable;
    }

    fn stencilLocalLast(vm: *VM) callconv(.c) void {
        var slot: u32 = undefined;
        asm volatile (
            \\.inst 0xD29FFFE1   // MOVZ X1, #0xFFFF — OPERAND hole
            : [o] "={x1}" (slot)
        );
        const frame = &vm.frames[vm.frames_len - 1];
        const src = &vm.stack[frame.base + slot];
        const val = src.*;
        src.* = .blank;
        vm.stack[vm.stack_len] = val;
        vm.stack_len += 1;
        asm volatile (
            \\.inst 0xD2800008
            \\.inst 0xF2A00008
            \\.inst 0xF2C00008
            \\.inst 0xF2E00008
            \\.inst 0xD61F0100
            ::: .{ .x8 = true }
        );
        unreachable;
    }

    // Apply2 stencil: reads opcode from OPERAND hole, delegates to vm.jit_apply2
    // (LDR from VM struct — position-independent when copied to JIT memory).
    // Uses scanWithFrame so the STP/LDP frame is preserved across the BLR.
    fn stencilApply2(vm: *VM) callconv(.c) void {
        var op_raw: u32 = undefined;
        asm volatile (
            \\.inst 0xD29FFFE1   // MOVZ X1, #0xFFFF — OPERAND hole
            : [o] "={x1}" (op_raw)
        );
        vm.jit_apply2(vm, @as(u8, @truncate(op_raw)));
        asm volatile (
            \\.inst 0xD2800008   // MOVZ X8, #0      — NEXT hole word 0
            \\.inst 0xF2A00008   // MOVK X8, #0, LSL 16
            \\.inst 0xF2C00008   // MOVK X8, #0, LSL 32
            \\.inst 0xF2E00008   // MOVK X8, #0, LSL 48
            \\.inst 0xD61F0100   // BR X8
            ::: .{ .x8 = true }
        );
        unreachable;
    }

    // ── Builder helpers ──────────────────────────────────────────────────────

    fn buildStencils() jit_mod.StencilTable {
        const s = stencils_mod;
        return .{
            .gap        = s.scan(@intFromPtr(&stencilGap)),
            .int_       = s.scan(@intFromPtr(&stencilInt)),
            .local      = s.scan(@intFromPtr(&stencilLocal)),
            .local_last = s.scan(@intFromPtr(&stencilLocalLast)),
            .apply2     = s.scanWithFrame(@intFromPtr(&stencilApply2)),
        };
    }

    fn buildHandlers() jit_mod.Handlers {
        return .{
            .gap           = @intFromPtr(&jhGap),
            .drop          = @intFromPtr(&jhDrop),
            .int_          = @intFromPtr(&jhInt),
            .const_        = @intFromPtr(&jhConst),
            .global        = @intFromPtr(&jhGlobal),
            .local         = @intFromPtr(&jhLocal),
            .local_last    = @intFromPtr(&jhLocalLast),
            .assign_global = @intFromPtr(&jhAssignGlobal),
            .assign_local  = @intFromPtr(&jhAssignLocal),
            .apply1        = @intFromPtr(&jhApply1),
            .apply2        = @intFromPtr(&jhApply2),
            .jump          = @intFromPtr(&jhJump),
            .jump_false    = @intFromPtr(&jhJumpFalse),
            .jump_true     = @intFromPtr(&jhJumpTrue),
            .return_       = @intFromPtr(&jhReturn),
        };
    }
} else struct {};

test "VM simple addition" {
  const alloc = std.testing.allocator;
  const vm = try VM.create(alloc);
  defer vm.deinit();

  const c1 = try vm.chunk.addConstant(.{ .i = 10 });
  const c2 = try vm.chunk.addConstant(.{ .i = 20 });

  try vm.chunk.writeOp(.Const);
  try vm.chunk.write(c1);
  try vm.chunk.writeOp(.Const);
  try vm.chunk.write(c2);
  try vm.chunk.writeOp(.Apply2);
  try vm.chunk.write(@intFromEnum(Op.@"+"));
  try vm.chunk.writeOp(.Return);

  try vm.run();

  const res = vm.pop();
  defer res.deinit(alloc);

  try std.testing.expectEqual(@as(i32, 30), res.i);
}

test "large list IR" {
  var vm = try VM.create(std.testing.allocator);
  defer vm.deinit();

  // Create a list with 20 elements to trigger MakeList with IR
  const code = "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20";
  const result = try vm.eval(code);
  defer result.deinit(vm.alloc);
  
  try std.testing.expectEqual(@as(usize, 20), result.len());
  const v0 = result.at(0);
  const v19 = result.at(19);
  if (v0 == .i) {
    try std.testing.expectEqual(@as(i32, 1), v0.i);
    try std.testing.expectEqual(@as(i32, 20), v19.i);
  } else {
    try std.testing.expectEqual(@as(f32, 1.0), v0.f);
    try std.testing.expectEqual(@as(f32, 20.0), v19.f);
  }
}
