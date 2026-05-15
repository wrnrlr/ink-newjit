const std = @import("std");
const builtin = @import("builtin");
const Alloc = std.mem.Allocator;
const Chunk = @import("tape.zig").Chunk;
const OpCode = @import("tape.zig").OpCode;
const Op = @import("tape.zig").Op;
const Compiler = @import("compiler.zig").Compiler;
const Registry = @import("registry.zig").Registry;
const GpuCtx = @import("gpu").GpuCtx;
const command = @import("command.zig");
const FnTables = @import("fntable.zig").FnTables;
const assert = std.debug.assert;
const call = @import("call.zig");
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const K = @import("../noun/class.zig").K;
const Fn = @import("../noun/operator.zig").Fn;
const Adverb = @import("../noun/operator.zig").Adverb;
const Dict = @import("../noun/dict.zig").Dict;
const Partial = @import("../noun/partial.zig").Partial;
const Pool = @import("../noun/symbol.zig").Pool;
const ExtRegistry = @import("../noun/plugin.zig").ExtRegistry;
const Parser = @import("../parser/ast.zig").Parser;
const enlist = @import("../primitive/verb/enlist.zig").enlist;
const dict = @import("../primitive/verb/pair.zig").dict;
const amend = @import("../primitive/amend.zig");
const promote = @import("../primitive/promote.zig").promote;
const dispatch = @import("../primitive/dispatch.zig");
const MockWriter = @import("../util.zig").MockWriter;
const build_options = @import("build_options");
// JIT is only available on arm64/macOS; the flag is silently ignored elsewhere.
const jit_enabled = build_options.enable_jit and builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;
const jit_mod = if (jit_enabled) @import("jit/jit.zig") else struct {};

const STACK_MAX = 2048;
const FRAMES_MAX = 64;

// Vtable for JIT worker functions called from Phase-1 stencils.
// Embedded directly in VM (not behind a pointer) so stencils reach each entry
// with a single LDR from the VM base register (x0), same cost as before.
const JitVtable = if (jit_enabled) struct {
  apply1:        *const fn(*VM, u8) callconv(.c) void = undefined,
  apply2:        *const fn(*VM, u8) callconv(.c) void = undefined,
  simd_array2:   *const fn(*VM, u8) callconv(.c) void = undefined,
  ref:           *const fn(*VM) callconv(.c) void    = undefined,
  drop:          *const fn(*VM) callconv(.c) void    = undefined,
  cond_pop:      *const fn(*VM) callconv(.c) u64     = undefined,
  return_:       *const fn(*VM) callconv(.c) void    = undefined,
  assign_local:  *const fn(*VM, u8) callconv(.c) void = undefined,
  assign_global: *const fn(*VM, u8) callconv(.c) void = undefined,
  make_list:     *const fn(*VM, u8) callconv(.c) void = undefined,
  derive:        *const fn(*VM, u8) callconv(.c) void = undefined,
  make_dict:     *const fn(*VM, u8) callconv(.c) void = undefined,
} else struct {};

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
  ext: ExtRegistry,
  out: ?*std.Io.Writer = null,
  prng: std.Random.DefaultPrng,
  argv: V = .blank,
  jit:        if (jit_enabled) ?jit_mod.JitCache else void = if (jit_enabled) null      else {},
  jit_err:    if (jit_enabled) ?anyerror         else void = if (jit_enabled) null      else {},
  jit_vtable: if (jit_enabled) JitVtable         else void = if (jit_enabled) .{}       else {},
  // Monomorphic inline cache: last successfully JIT-compiled lambda.
  // Avoids a hash-map lookup on every call in hot adverb loops.
  jit_ic_key: if (jit_enabled) u24               else void = if (jit_enabled) NO_LAMBDA else {},
  jit_ic_jf:  if (jit_enabled) ?jit_mod.JitFn   else void = if (jit_enabled) null      else {},

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
      .ext           = ExtRegistry.init(alloc),
      .prng          = std.Random.DefaultPrng.init(0),
    };

    vm.compiler.* = try Compiler.init(alloc, chunk, &vm.globals_names, &vm.symbols, &vm.registry, &vm.fn_tables);

    if (comptime jit_enabled) {
        vm.jit_vtable = JitImpl.buildVtable();
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
    vm.jit_ic_key = lambda_idx; // expose to apply2Worker for type observation
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
        const jf = blk: {
          // IC hit: use cached JitFn, but invalidate if apply2Worker recorded
          // a new type hint since the last compilation (triggers re-JIT next call).
          if (vm.jit_ic_key == lambda_idx) {
            if (vm.jit.?.needsRejit(lambda_idx)) {
              _ = vm.jit.?.entries.remove(lambda_idx);
              vm.jit_ic_jf = null;
            } else {
              break :blk vm.jit_ic_jf;
            }
          }
          // IC miss or just invalidated — full lookup / compile.
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
          // After running: if apply2Worker observed new types, invalidate IC.
          // getOrCompile will recompile with the type hint on the next call.
          if (vm.jit.?.needsRejit(lambda_idx)) vm.jit_ic_jf = null;
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
    vm.current_chunk = if (parent_idx == NO_LAMBDA) vm.chunk
                       else vm.fn_tables.lambdaAt(parent_idx).chunk;
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
    try vm.push(.{ .partial = p });
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
    try vm.push(.{ .func = derived });
  }
  
  fn doMakeList(vm: *VM) !void {
    const argc = vm.readByte();
    const start = vm.stack_len - argc;
    const values = vm.stack[start..vm.stack_len];
    const list_val = try V.Values(vm.alloc, values);
    for (values) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(list_val);
  }

  fn doMakeDict(vm: *VM) !void {
    const n = vm.readByte();
    const start = vm.stack_len - 2 * n;
    const keys = if (n == 1) vm.stack[start].ref()
                 else promote(vm.alloc, (try V.Values(vm.alloc, vm.stack[start .. start + n])).L);
    var keys_live = n > 1;
    errdefer { if (keys_live) keys.deinit(vm.alloc); }
    const vals = if (n == 1) vm.stack[start + 1].ref()
                 else promote(vm.alloc, (try V.Values(vm.alloc, vm.stack[start + n .. start + 2 * n])).L);
    var vals_live = n > 1;
    errdefer { if (vals_live) vals.deinit(vm.alloc); }
    const res = if (n == 1) V{ .m = try Dict.init(vm.alloc, keys, vals) }
                else dict(vm, keys, vals);
    errdefer res.deinit(vm.alloc);
    if (n > 1) {
      keys.deinit(vm.alloc);
      keys_live = false;
      vals.deinit(vm.alloc);
      vals_live = false;
    }
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(res);
  }

  fn doMakeTable(vm: *VM) !void {
    const n = vm.readByte();
    const start = vm.stack_len - 2 * n;
    const keys = if (n == 1) enlist(vm.alloc, vm.stack[start])
                 else promote(vm.alloc, (try V.Values(vm.alloc, vm.stack[start .. start + n])).L);
    const vals = if (n == 1) enlist(vm.alloc, vm.stack[start + 1])
                 else promote(vm.alloc, (try V.Values(vm.alloc, vm.stack[start + n .. start + 2 * n])).L);
    const res = V{ .M = try Dict.init(vm.alloc, keys, vals) };
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(res);
  }
  
  fn doCommand(vm: *VM) anyerror!void {
    var cmd_v = vm.pop();
    defer cmd_v.deinit(vm.alloc);
    const bytes = cmd_v.C.slice();
    // bytes is verb\0count_str\0args
    const sep1 = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    const verb = bytes[0..sep1];
    const rest = if (sep1 < bytes.len) bytes[sep1 + 1 ..] else "";
    const sep2 = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    const n = std.fmt.parseInt(u32, rest[0..sep2], 10) catch 1;
    const args = if (sep2 < rest.len) std.mem.trim(u8, rest[sep2 + 1 ..], " \t") else "";
    const result = try command.exec(vm, verb, n, args);
    try vm.push(result);
  }


  pub fn callLambda(vm: *VM, ref: Fn, argc: usize, slot: usize) !void {
    if (vm.frames_len >= FRAMES_MAX) return VMError.StackOverflow;
    const idx = @as(u24, @intCast(ref.idx));
    const entry = vm.fn_tables.lambdaAt(idx);

    const total_slots = @as(usize, entry.arity) + @as(usize, entry.locals);
    const locals_to_push = if (total_slots > argc) total_slots - argc else 0;
    for (0..locals_to_push) |_| try vm.push(.blank);

    const base = vm.stack_len - argc - locals_to_push;
    vm.pushFrame(.{ .lambda_idx = idx, .base = base, .result_slot = slot });

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
fn opDup(vm: *VM) anyerror!void { try vm.push(vm.peek(0).ref()); }
fn opJumpFalse(vm: *VM) anyerror!void { try vm.doJumpWhen(false); }
fn opJumpTrue(vm: *VM) anyerror!void  { try vm.doJumpWhen(true); }

const OpHandler = *const fn(*VM) anyerror!void;
const op_table: [OpCode.COUNT]OpHandler = build: {
  var t: [OpCode.COUNT]OpHandler = undefined;
  t[@intFromEnum(OpCode.Nop)]              = &opNop;
  t[@intFromEnum(OpCode.Gap)]              = &opGap;
  t[@intFromEnum(OpCode.Drop)]             = &opDrop;
  t[@intFromEnum(OpCode.Dup)]              = &opDup;
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
  fn jhDup(vm: *VM) callconv(.c) void { vm.push(vm.stack[vm.stack_len - 1].ref()) catch {}; }
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
  fn jhMakeList(vm: *VM, n: u8) callconv(.c) void { makeListWorker(vm, n); }
  fn jhDerive(vm: *VM, adv: u8) callconv(.c) void { deriveWorker(vm, adv); }
  fn jhMakeDict(vm: *VM, n: u8) callconv(.c) void { makeDictWorker(vm, n); }
  fn jhReturn(vm: *VM) callconv(.c) void { vm.doReturn() catch {}; }

  // Call/Apply/TailCall handlers for Phase 2.
  // argc is pre-read from bytecode by the emitter (avoids vm.readByte()).
  fn jhCall(vm: *VM, argc: u8) callconv(.c) void {
    var buf: [8]V = .{.blank} ** 8;
    const n = @min(argc, 8);
    const incoming = buf[0..n];
    for (0..n) |i| incoming[n - 1 - i] = vm.pop();
    const func_val = vm.pop();
    vm.executeCall(func_val, incoming, .sync) catch {};
    for (incoming) |*v| v.deinit(vm.alloc);
    func_val.deinit(vm.alloc);
  }
  fn jhApply(vm: *VM, argc: u8) callconv(.c) void {
    var buf: [8]V = .{.blank} ** 8;
    const n = @min(argc, 8);
    const incoming = buf[0..n];
    for (0..n) |i| incoming[n - 1 - i] = vm.pop();
    const func_val = vm.pop();
    vm.executeCall(func_val, incoming, .bracket) catch {};
    for (incoming) |*v| v.deinit(vm.alloc);
    func_val.deinit(vm.alloc);
  }
  fn jhTailCall(vm: *VM, argc: u8) callconv(.c) void {
    var buf: [8]V = .{.blank} ** 8;
    const n = @min(argc, 8);
    const incoming = buf[0..n];
    for (0..n) |i| incoming[n - 1 - i] = vm.pop();
    const func_val = vm.pop();
    defer func_val.deinit(vm.alloc);
    if (func_val == .func and func_val.func.getKind() == .lambda) {
      const lambda_idx = @as(u24, @intCast(func_val.func.idx));
      const entry = vm.fn_tables.lambdaAt(lambda_idx);
      const frame = vm.currentFrame();
      for (vm.stack[frame.result_slot..vm.stack_len]) |*v| v.deinit(vm.alloc);
      vm.stack_len = frame.result_slot;
      vm.push(.blank) catch return;
      for (incoming) |arg| vm.push(arg) catch {};
      const total_slots = @as(usize, entry.arity) + @as(usize, entry.locals);
      const locals_to_push = if (total_slots > n) total_slots - n else 0;
      for (0..locals_to_push) |_| vm.push(.blank) catch {};
      frame.lambda_idx = lambda_idx;
      frame.ip = 0;
      frame.base = vm.stack_len - n - locals_to_push;
      vm.current_chunk = entry.chunk;
    } else {
      vm.executeCall(func_val, incoming, .sync) catch {};
      for (incoming) |*v| v.deinit(vm.alloc);
    }
  }
  // MakePartial: argc and mask packed as u16 (argc<<8 | mask) by the emitter.
  fn jhMakePartial(vm: *VM, argc_mask: u16) callconv(.c) void {
    const argc: u8 = @truncate(argc_mask >> 8);
    const mask: u8 = @truncate(argc_mask);
    const args_start = vm.stack_len - argc;
    const stack_args = vm.stack[args_start..vm.stack_len];
    const func_val = vm.stack[args_start - 1];

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
      vm.push(V{ .err = .@"type" }) catch {};
      return;
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

    const p = vm.partial_pool.create(vm.alloc) catch {
      for (vm.stack[args_start - 1 .. vm.stack_len]) |*v| v.deinit(vm.alloc);
      vm.stack_len = args_start - 1;
      vm.push(V{ .err = .memory }) catch {};
      return;
    };
    p.* = .{ .pool = &vm.partial_pool, .rc = 1, .fill = fill, .arity = arity, ._pad = 0, .ref = base_ref, .args = merged };

    for (vm.stack[args_start - 1 .. vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = args_start - 1;
    vm.push(.{ .partial = p }) catch {};
  }

  // ── apply1Worker / apply2Worker ──────────────────────────────────────────
  // Called indirectly from stencilApply1/2 via vm.jit_apply1/2 (LDR+BLR).
  // Being regular functions they can BL freely; errors go to vm.jit_err.
  fn apply1Worker(vm: *VM, op: u8) callconv(.c) void {
    const a = vm.pop(); defer a.deinit(vm.alloc);
    vm.push(dispatch.dispatch1(vm, @enumFromInt(op), a)) catch {};
  }

  fn apply2Worker(vm: *VM, op_byte: u8) callconv(.c) void {
    // Record type observation for profile-guided re-JIT.
    // On the first call the JIT uses general stencils; on the second call
    // (after re-JIT) the type-matched stencil (add_II etc.) is used.
    if (vm.jit) |*jc| {
      const len = vm.stack_len;
      if (len >= 2) {
        const xt = vm.stack[len - 2].tag();
        const yt = vm.stack[len - 1].tag();
        const pair: u8 =
          if (xt == .i and yt == .i) 1
          else if (xt == .f and yt == .f) 2
          else if (xt == .I and yt == .I) 3
          else if (xt == .F and yt == .F) 4
          else 0xFF;
        if (pair != 0xFF) jc.recordTypePair(vm.jit_ic_key, pair);
      }
    }
    const b = vm.pop(); defer b.deinit(vm.alloc);
    const a = vm.pop(); defer a.deinit(vm.alloc);
    vm.push(dispatch.dispatch2(vm, @enumFromInt(op_byte), a, b)) catch {};
  }

  // ── SIMD array workers ───────────────────────────────────────────────────
  // simdArray2Worker is the target of vm.jit_simd_array2.  It is called from
  // the array stencils (stencilAdd_II, stencilSub_II, etc.) via LDR+BLR.
  // Fast path: I×I or F×F with NEON @Vector(4, T) loops.
  // Fallback: delegates to dispatch.dispatch2 for other types.

  fn simdArray2Worker(vm: *VM, op_byte: u8) callconv(.c) void {
    const op: Op = @enumFromInt(op_byte);
    const len = vm.stack_len;
    const y = vm.stack[len - 1];
    const x = vm.stack[len - 2];
    if (x == .I and y == .I) {
      if (simdBinopII(vm, op, x.I, y.I, len)) return;
    } else if (x == .F and y == .F) {
      if (simdBinopFF(vm, op, x.F, y.F, len)) return;
    }
    // General dispatch fallback (also handles type mismatches).
    const b = vm.pop(); defer b.deinit(vm.alloc);
    const a = vm.pop(); defer a.deinit(vm.alloc);
    vm.push(dispatch.dispatch2(vm, op, a, b)) catch {};
  }

  // Returns true on success (including on length-error).  Returns false to
  // signal that dispatch.dispatch2 should handle the op (unsupported op etc).
  fn simdBinopII(vm: *VM, op: Op, xn: N(i32), yn: N(i32), stack_len: usize) bool {
    const xs = xn.slice();
    const ys = yn.slice();
    if (xs.len != ys.len) {
      xn.deinit(vm.alloc); yn.deinit(vm.alloc);
      vm.stack[stack_len - 2] = .{ .err = .length };
      vm.stack_len = stack_len - 1;
      return true;
    }
    // Comparison ops produce N(bool); arithmetic ops produce N(i32).
    switch (op) {
      .@"+", .@"-", .@"*" => {
        const out = N(i32).init(vm.alloc, xs.len) catch return false;
        const os = out.slice();
        const Vec = @Vector(4, i32);
        var i: usize = 0;
        const vn = xs.len & ~@as(usize, 3);
        switch (op) {
          .@"+" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]i32, va +% vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] +% ys[i];
          },
          .@"-" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]i32, va -% vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] -% ys[i];
          },
          .@"*" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]i32, va *% vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] *% ys[i];
          },
          else => unreachable,
        }
        xn.deinit(vm.alloc); yn.deinit(vm.alloc);
        vm.stack[stack_len - 2] = .{ .I = out };
        vm.stack_len = stack_len - 1;
        return true;
      },
      .@"<", .@">", .@"=" => {
        const out = N(bool).init(vm.alloc, xs.len) catch return false;
        const os = out.slice();
        const Vec = @Vector(4, i32);

        var i: usize = 0;
        const vn = xs.len & ~@as(usize, 3);
        switch (op) {
          .@"<" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]bool, va < vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] < ys[i];
          },
          .@">" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]bool, va > vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] > ys[i];
          },
          .@"=" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]bool, va == vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] == ys[i];
          },
          else => unreachable,
        }
        xn.deinit(vm.alloc); yn.deinit(vm.alloc);
        vm.stack[stack_len - 2] = .{ .B = out };
        vm.stack_len = stack_len - 1;
        return true;
      },
      else => return false,
    }
  }

  fn simdBinopFF(vm: *VM, op: Op, xn: N(f32), yn: N(f32), stack_len: usize) bool {
    const xs = xn.slice();
    const ys = yn.slice();
    if (xs.len != ys.len) {
      xn.deinit(vm.alloc); yn.deinit(vm.alloc);
      vm.stack[stack_len - 2] = .{ .err = .length };
      vm.stack_len = stack_len - 1;
      return true;
    }
    switch (op) {
      .@"+", .@"-", .@"*" => {
        const out = N(f32).init(vm.alloc, xs.len) catch return false;
        const os = out.slice();
        const Vec = @Vector(4, f32);
        var i: usize = 0;
        const vn = xs.len & ~@as(usize, 3);
        switch (op) {
          .@"+" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]f32, va + vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] + ys[i];
          },
          .@"-" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]f32, va - vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] - ys[i];
          },
          .@"*" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]f32, va * vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] * ys[i];
          },
          else => unreachable,
        }
        xn.deinit(vm.alloc); yn.deinit(vm.alloc);
        vm.stack[stack_len - 2] = .{ .F = out };
        vm.stack_len = stack_len - 1;
        return true;
      },
      .@"<", .@">", .@"=" => {
        const out = N(bool).init(vm.alloc, xs.len) catch return false;
        const os = out.slice();
        const Vec = @Vector(4, f32);
        var i: usize = 0;
        const vn = xs.len & ~@as(usize, 3);
        switch (op) {
          .@"<" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]bool, va < vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] < ys[i];
          },
          .@">" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]bool, va > vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] > ys[i];
          },
          .@"=" => {
            while (i < vn) : (i += 4) { const va: Vec = xs[i..][0..4].*; const vb: Vec = ys[i..][0..4].*; os[i..][0..4].* = @as([4]bool, va == vb); }
            while (i < xs.len) : (i += 1) os[i] = xs[i] == ys[i];
          },
          else => unreachable,
        }
        xn.deinit(vm.alloc); yn.deinit(vm.alloc);
        vm.stack[stack_len - 2] = .{ .B = out };
        vm.stack_len = stack_len - 1;
        return true;
      },
      else => return false,
    }
  }

  fn assignLocalWorker(vm: *VM, slot: u8) callconv(.c) void {
    const val = vm.pop();
    const i = vm.currentFrame().base + slot;
    vm.stack[i].deinit(vm.alloc);
    vm.stack[i] = val;
    vm.push(.blank) catch {};
  }

  // Slow path for stencilGlobal: handles heap types (refcount increment) and
  // out-of-range indices.  Called via vm.jit_global (LDR+BLR — position-independent).
  fn globalWorker(vm: *VM, idx: u8) callconv(.c) void {
    while (vm.globals.items.len <= idx) vm.globals.append(vm.alloc, .blank) catch return;
    vm.push(vm.globals.items[idx].ref()) catch {};
  }

  // Refcount the top-of-stack value in-place.
  // Called by stencilLocal, stencilConst, stencilDup via vm.jit_ref (LDR+BLR).
  // Avoids inlining the switch inside stencil bodies where it causes escaping
  // branches in ReleaseFast (those stencils would otherwise fall back to Phase 2).
  fn refWorker(vm: *VM) callconv(.c) void {
    _ = vm.stack[vm.stack_len - 1].ref();
  }

  // Pop and deinit TOS.  Called by stencilDrop via vm.jit_drop (LDR+BLR).
  fn dropWorker(vm: *VM) callconv(.c) void {
    vm.pop().deinit(vm.alloc);
  }

  // Execute the Return bytecode op.  Called by stencilReturn via vm.jit_return.
  // After this returns, the stencil executes RET to exit the JIT function.
  fn returnWorker(vm: *VM) callconv(.c) void {
    vm.doReturn() catch {};
  }

  // Assign TOS to a global slot and push .blank.
  // Called by stencilAssignGlobal via vm.jit_assign_global (LDR+BLR).
  fn assignGlobalWorker(vm: *VM, idx: u8) callconv(.c) void {
    const val = vm.pop();
    while (vm.globals.items.len <= idx) vm.globals.append(vm.alloc, .blank) catch return;
    vm.globals.items[idx].deinit(vm.alloc);
    vm.globals.items[idx] = val;
    vm.push(.blank) catch {};
  }

  // Pop `n` values and push a list.  Called by stencilMakeList.
  fn makeListWorker(vm: *VM, n: u8) callconv(.c) void {
    const start = vm.stack_len - n;
    const list_val = V.Values(vm.alloc, vm.stack[start..vm.stack_len]) catch return;
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    vm.push(list_val) catch {};
  }

  // Pop a func value and push its derived form (with adverb `adv`).
  // Called by stencilDerive via vm.jit_derive (LDR+BLR).
  fn deriveWorker(vm: *VM, adv_byte: u8) callconv(.c) void {
    const adv: Adverb = @enumFromInt(adv_byte);
    const base_v = vm.pop();
    const derived: Fn = if (base_v == .func) blk: {
      const ref = base_v.func;
      base_v.deinit(vm.alloc);
      break :blk switch (ref.getKind()) {
        .builtin => Fn.makeDerivedBuiltin(ref.getOp(), adv),
        .lambda  => Fn.makeDerivedLambda(ref.idx, adv),
        else => blk2: {
          const idx = vm.fn_tables.addDerived(.{ .base = V{ .func = ref }, .adverb = adv }) catch return;
          break :blk2 Fn.makeDerivedTable(idx);
        },
      };
    } else blk: {
      const idx = vm.fn_tables.addDerived(.{ .base = base_v, .adverb = adv }) catch return;
      break :blk Fn.makeDerivedTable(idx);
    };
    vm.push(.{ .func = derived }) catch {};
  }

  // Pop 2*n values (n key-value pairs) and push a dict.
  // Called by stencilMakeDict via vm.jit_make_dict (LDR+BLR).
  fn makeDictWorker(vm: *VM, n: u8) callconv(.c) void {
    makeDictN(vm, n) catch {};
  }

  fn makeDictN(vm: *VM, n: u8) !void {
    const start = vm.stack_len - 2 * n;
    const keys = if (n == 1) vm.stack[start].ref()
                 else promote(vm.alloc, (try V.Values(vm.alloc, vm.stack[start .. start + n])).L);
    var keys_live = n > 1;
    errdefer { if (keys_live) keys.deinit(vm.alloc); }
    const vals = if (n == 1) vm.stack[start + 1].ref()
                 else promote(vm.alloc, (try V.Values(vm.alloc, vm.stack[start + n .. start + 2 * n])).L);
    var vals_live = n > 1;
    errdefer { if (vals_live) vals.deinit(vm.alloc); }
    const res = if (n == 1) V{ .m = try Dict.init(vm.alloc, keys, vals) }
                else dict(vm, keys, vals);
    errdefer res.deinit(vm.alloc);
    if (n > 1) {
      keys.deinit(vm.alloc); keys_live = false;
      vals.deinit(vm.alloc); vals_live = false;
    }
    for (vm.stack[start..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(res);
  }

  // Pops the top-of-stack condition, returns 0 (false) or 1 (true) in x0.
  // Called from stencilJumpFalse/True via vm.jit_cond_pop (LDR+BLR).
  fn condPopWorker(vm: *VM) callconv(.c) u64 {
    const v = vm.pop();
    defer v.deinit(vm.alloc);
    return if (v.isTrue()) 1 else 0;
  }

  // ── Type-specialised dyadic stencils ────────────────────────────────────
  // Fast path: if top-two stack values are both .i or both .f, perform inline.
  // Slow path: delegates to vm.jit_apply2 for all other type combinations.
  // Uses scanWithFrame because the slow path calls vm.jit_apply2 via BLR.
  inline fn specDyad(vm: *VM, comptime op: Op) void {
    const len = vm.stack_len;
    const y = vm.stack[len - 1];
    const x = vm.stack[len - 2];
    if (x.tag() == .i and y.tag() == .i) {
      vm.stack[len - 2] = switch (comptime op) {
        .@"+" => V{ .i = x.i +% y.i },
        .@"-" => V{ .i = x.i -% y.i },
        .@"*" => V{ .i = x.i *% y.i },
        .@"<" => V{ .b = x.i < y.i },
        .@">" => V{ .b = x.i > y.i },
        .@"=" => V{ .b = x.i == y.i },
        else  => unreachable,
      };
      vm.stack_len = len - 1;
    } else if (x.tag() == .f and y.tag() == .f) {
      vm.stack[len - 2] = switch (comptime op) {
        .@"+" => V{ .f = x.f + y.f },
        .@"-" => V{ .f = x.f - y.f },
        .@"*" => V{ .f = x.f * y.f },
        .@"<" => V{ .b = x.f < y.f },
        .@">" => V{ .b = x.f > y.f },
        .@"=" => V{ .b = x.f == y.f },
        else  => unreachable,
      };
      vm.stack_len = len - 1;
    } else {
      vm.jit_vtable.apply2(vm, @intFromEnum(op));
    }
    asm volatile (
      \\.inst 0xD29BD5A8
      \\.inst 0xF2B7DDE8
      \\.inst 0xF2D95FC8
      \\.inst 0xF2F757C8
      \\.inst 0xD61F0100
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  fn SpecDyadStencil(comptime op: Op) type {
    return struct {
      fn f(vm: *VM) callconv(.c) void { specDyad(vm, op); }
    };
  }
  const Stencil_add_ii = SpecDyadStencil(.@"+");
  const Stencil_sub_ii = SpecDyadStencil(.@"-");
  const Stencil_mul_ii = SpecDyadStencil(.@"*");
  const Stencil_lt_ii  = SpecDyadStencil(.@"<");
  const Stencil_gt_ii  = SpecDyadStencil(.@">");
  const Stencil_eq_ii  = SpecDyadStencil(.@"=");

  // ── Array SIMD stencils: comptime-generated, one per op ──────────────────
  // The simd_array2 worker inspects runtime stack types (I×I or F×F).
  // add_II and add_FF use the SAME stencil bytes (same op, same worker call).
  fn SimdStencil(comptime op: Op) type {
    return struct {
      fn f(vm: *VM) callconv(.c) void {
        vm.jit_vtable.simd_array2(vm, @intFromEnum(op));
        asm volatile (
          \\.inst 0xD29BD5A8
          \\.inst 0xF2B7DDE8
          \\.inst 0xF2D95FC8
          \\.inst 0xF2F757C8
          \\.inst 0xD61F0100
          ::: .{ .x8 = true }
        );
        unreachable;
      }
    };
  }
  const Stencil_add_simd = SimdStencil(.@"+");
  const Stencil_sub_simd = SimdStencil(.@"-");
  const Stencil_mul_simd = SimdStencil(.@"*");
  const Stencil_lt_simd  = SimdStencil(.@"<");
  const Stencil_gt_simd  = SimdStencil(.@">");
  const Stencil_eq_simd  = SimdStencil(.@"=");

  // Comptime generator for one-operand stencils that delegate to a vtable worker.
  fn OpStencil(comptime vtable_field: []const u8) type {
    return struct {
      fn f(vm: *VM) callconv(.c) void {
        var n: u32 = undefined;
        asm volatile (
          \\.inst 0xD2994221
          : [o] "={x1}" (n)
        );
        @field(vm.jit_vtable, vtable_field)(vm, @as(u8, @truncate(n)));
        asm volatile (
          \\.inst 0xD29BD5A8
          \\.inst 0xF2B7DDE8
          \\.inst 0xF2D95FC8
          \\.inst 0xF2F757C8
          \\.inst 0xD61F0100
          ::: .{ .x8 = true }
        );
        unreachable;
      }
    };
  }
  const Stencil_make_list = OpStencil("make_list");
  const Stencil_derive     = OpStencil("derive");
  const Stencil_make_dict  = OpStencil("make_dict");

  // ── CPS stencil functions ────────────────────────────────────────────────
  // Each stencil is a LEAF (no BLR) so the tail-call chain via BR X8 works.
  // NEXT hole  = MOVZ/MOVK×3/BR X8 at the end, patched to the next stencil.
  // OPERAND hole = MOVZ X1, #0xFFFF, patched with the actual operand.

  // Return stencil: terminal stencil — calls doReturn then exits the JIT function.
  // No NEXT hole; instead the function ends with a compiler-generated RET.
  // Registered via scanTerminal (which stops at RET instead of NEXT hole).
  // When used, Phase 1 handles the entire lambda body including Return, and
  // Phase 2 is skipped entirely, saving the STP/LDP/RET wrapper overhead.
  fn stencilReturn(vm: *VM) callconv(.c) void {
    vm.jit_vtable.return_(vm);
    // Compiler emits: LDP X29,X30,[SP],#16 (epilogue) then RET here.
    // scanTerminal includes these in the copied bytes.
  }

  // Drop stencil: pop TOS and deinit via jit_vtable.drop (handles heap types).
  // Uses scanWithFrame because the drop call is via LDR+BLR.
  fn stencilDrop(vm: *VM) callconv(.c) void {
    vm.jit_vtable.drop(vm);
    asm volatile (
      \\.inst 0xD29BD5A8
      \\.inst 0xF2B7DDE8
      \\.inst 0xF2D95FC8
      \\.inst 0xF2F757C8
      \\.inst 0xD61F0100
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  // AssignGlobal stencil: OPERAND hole = u8 global index.
  // Pops TOS, stores into globals[idx], pushes .blank.
  // Uses scanWithFrame because vm.jit_assign_global is called via LDR+BLR.
  fn stencilAssignGlobal(vm: *VM) callconv(.c) void {
    var idx: u32 = undefined;
    asm volatile (
      \\.inst 0xD2994221   // MOVZ X1, #0xCA11 — OPERAND hole
      : [o] "={x1}" (idx)
    );
    vm.jit_vtable.assign_global(vm, @as(u8, @truncate(idx)));
    asm volatile (
      \\.inst 0xD29BD5A8
      \\.inst 0xF2B7DDE8
      \\.inst 0xF2D95FC8
      \\.inst 0xF2F757C8
      \\.inst 0xD61F0100
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  fn stencilGap(vm: *VM) callconv(.c) void {
    vm.stack[vm.stack_len] = .blank;
    vm.stack_len += 1;
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  // Dup stencil: duplicate top-of-stack (increment refcount via jit_vtable.ref, push copy).
  // Uses scanWithFrame because the ref call is via LDR+BLR (needs a saved frame).
  fn stencilDup(vm: *VM) callconv(.c) void {
    vm.stack[vm.stack_len] = vm.stack[vm.stack_len - 1];
    vm.stack_len += 1;
    vm.jit_vtable.ref(vm);
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  fn stencilInt(vm: *VM) callconv(.c) void {
    var raw: u32 = undefined;
    asm volatile (
      \\.inst 0xD2994221   // MOVZ X1, #0xCA11 — OPERAND hole
      : [o] "={x1}" (raw)
    );
    vm.stack[vm.stack_len] = .{ .i = @as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw))))) };
    vm.stack_len += 1;
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  // Local stencil: push copy of a local slot value, refcount via jit_vtable.ref.
  // Uses scanWithFrame because the ref call is via LDR+BLR.
  fn stencilLocal(vm: *VM) callconv(.c) void {
    var slot: u32 = undefined;
    asm volatile (
      \\.inst 0xD2994221   // MOVZ X1, #0xCA11 — OPERAND hole
      : [o] "={x1}" (slot)
    );
    const frame = &vm.frames[vm.frames_len - 1];
    vm.stack[vm.stack_len] = vm.stack[frame.base + slot];
    vm.stack_len += 1;
    vm.jit_vtable.ref(vm);
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  fn stencilLocalLast(vm: *VM) callconv(.c) void {
    var slot: u32 = undefined;
    asm volatile (
      \\.inst 0xD2994221   // MOVZ X1, #0xCA11 — OPERAND hole
      : [o] "={x1}" (slot)
    );
    const frame = &vm.frames[vm.frames_len - 1];
    const src = &vm.stack[frame.base + slot];
    const val = src.*;
    src.* = .blank;
    vm.stack[vm.stack_len] = val;
    vm.stack_len += 1;
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  // Apply1 stencil: reads opcode from OPERAND hole, delegates to vm.jit_apply1.
  // Uses scanWithFrame so the STP/LDP frame is preserved across the BLR.
  // AssignLocal stencil: pops TOS, stores into local slot, pushes blank.
  // Delegates to vm.jit_assign_local via LDR+BLR (handles heap deinit).
  // Uses scanWithFrame so the STP/LDP frame is preserved across the BLR.
  fn stencilAssignLocal(vm: *VM) callconv(.c) void {
    var slot: u32 = undefined;
    asm volatile (
      \\.inst 0xD2994221   // MOVZ X1, #0xCA11 — OPERAND hole
      : [o] "={x1}" (slot)
    );
    vm.jit_vtable.assign_local(vm, @as(u8, @truncate(slot)));
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  // Const stencil: OPERAND hole = u8 index into vm.current_chunk.constants.
  // Pushes the constant then bumps its refcount via jit_vtable.ref (LDR+BLR).
  // Uses scanWithFrame because of the BLR call.
  fn stencilConst(vm: *VM) callconv(.c) void {
    var idx: u32 = undefined;
    asm volatile (
      \\.inst 0xD2994221   // MOVZ X1, #0xCA11 — OPERAND hole
      : [o] "={x1}" (idx)
    );
    vm.stack[vm.stack_len] = vm.current_chunk.constants.items[idx];
    vm.stack_len += 1;
    vm.jit_vtable.ref(vm);
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  // Global stencil: push the global value and bump its refcount via jit_ref.
  // Out-of-range indices push .blank (uninitialized globals are blank by definition).
  // jit_ref is always called — for scalars it is a no-op; for heap types it
  // increments the refcount.  A single BLR callsite keeps all globals in Phase 1;
  // no separate globalWorker path is needed for heap values.
  fn stencilGlobal(vm: *VM) callconv(.c) void {
    var idx: u32 = undefined;
    asm volatile (
      \\.inst 0xD2994221   // MOVZ X1, #0xCA11 — OPERAND hole
      : [o] "={x1}" (idx)
    );
    if (idx < vm.globals.items.len) {
      vm.stack[vm.stack_len] = vm.globals.items[idx];
    } else {
      vm.stack[vm.stack_len] = .blank;
    }
    vm.stack_len += 1;
    vm.jit_vtable.ref(vm);
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  fn stencilApply1(vm: *VM) callconv(.c) void {
    var op_raw: u32 = undefined;
    asm volatile (
      \\.inst 0xD2994221   // MOVZ X1, #0xCA11 — OPERAND hole
      : [o] "={x1}" (op_raw)
    );
    vm.jit_vtable.apply1(vm, @as(u8, @truncate(op_raw)));
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  // Apply2 stencil: reads opcode from OPERAND hole, delegates to jit_vtable.apply2
  // (LDR from VM struct — position-independent when copied to JIT memory).
  // Uses scanWithFrame so the STP/LDP frame is preserved across the BLR.
  fn stencilApply2(vm: *VM) callconv(.c) void {
    var op_raw: u32 = undefined;
    asm volatile (
      \\.inst 0xD2994221   // MOVZ X1, #0xCA11 — OPERAND hole
      : [o] "={x1}" (op_raw)
    );
    vm.jit_vtable.apply2(vm, @as(u8, @truncate(op_raw)));
    asm volatile (
      \\.inst 0xD29BD5A8   // MOVZ X8, #0xDEAD — NEXT hole word 0
      \\.inst 0xF2B7DDE8   // MOVK X8, #0xBEEF, LSL 16
      \\.inst 0xF2D95FC8   // MOVK X8, #0xCAFE, LSL 32
      \\.inst 0xF2F757C8   // MOVK X8, #0xBABE, LSL 48
      \\.inst 0xD61F0100   // BR X8
      ::: .{ .x8 = true }
    );
    unreachable;
  }

  // JumpFalse stencil: calls condPopWorker (→ x0 = 0 or 1), then:
  //   CBZ X0, #+24  — if false (x0==0): skip fall-through NEXT hole, jump to taken NEXT hole
  //   [fall-through NEXT hole: 5 words] — taken when condition is TRUE (don't jump)
  //   [taken NEXT hole: 5 words]        — taken when condition is FALSE (do jump)
  // Uses scan2WithFrame (two NEXT holes, frame preserved for BLR).
  fn stencilJumpFalse(vm: *VM) callconv(.c) void {
    const cond: u64 = vm.jit_vtable.cond_pop(vm);
    // CBZ X0, #+24: if false (x0==0): skip fall-through NEXT hole → taken NEXT hole.
    // Function ends with unreachable so no x8 clobber annotation needed.
    asm volatile (
      \\.inst 0xB40000C0   // CBZ X0, #+24
      \\.inst 0xD29BD5A8   // Fall-through NEXT hole word 0
      \\.inst 0xF2B7DDE8   // word 1
      \\.inst 0xF2D95FC8   // word 2
      \\.inst 0xF2F757C8   // word 3
      \\.inst 0xD61F0100   // word 4: BR X8
      \\.inst 0xD29BD5A8   // Taken NEXT hole word 0
      \\.inst 0xF2B7DDE8   // word 1
      \\.inst 0xF2D95FC8   // word 2
      \\.inst 0xF2F757C8   // word 3
      \\.inst 0xD61F0100   // word 4: BR X8
      : : [c] "{x0}" (cond)
    );
    unreachable;
  }

  // JumpTrue stencil: calls condPopWorker (→ x0 = 0 or 1), then:
  //   CBNZ X0, #+24 — if true (x0!=0): skip fall-through NEXT hole, jump to taken NEXT hole
  //   [fall-through NEXT hole: 5 words] — taken when condition is FALSE (don't jump)
  //   [taken NEXT hole: 5 words]        — taken when condition is TRUE (do jump)
  fn stencilJumpTrue(vm: *VM) callconv(.c) void {
    const cond: u64 = vm.jit_vtable.cond_pop(vm);
    asm volatile (
      \\.inst 0xB50000C0   // CBNZ X0, #+24
      \\.inst 0xD29BD5A8   // Fall-through NEXT hole word 0
      \\.inst 0xF2B7DDE8   // word 1
      \\.inst 0xF2D95FC8   // word 2
      \\.inst 0xF2F757C8   // word 3
      \\.inst 0xD61F0100   // word 4: BR X8
      \\.inst 0xD29BD5A8   // Taken NEXT hole word 0
      \\.inst 0xF2B7DDE8   // word 1
      \\.inst 0xF2D95FC8   // word 2
      \\.inst 0xF2F757C8   // word 3
      \\.inst 0xD61F0100   // word 4: BR X8
      : : [c] "{x0}" (cond)
    );
    unreachable;
  }

  // ── Builder helpers ──────────────────────────────────────────────────────

  fn buildVtable() JitVtable {
    return .{
      .apply1        = &apply1Worker,
      .apply2        = &apply2Worker,
      .simd_array2   = &simdArray2Worker,
      .ref           = &refWorker,
      .drop          = &dropWorker,
      .cond_pop      = &condPopWorker,
      .return_       = &returnWorker,
      .assign_local  = &assignLocalWorker,
      .assign_global = &assignGlobalWorker,
      .make_list     = &makeListWorker,
      .derive        = &deriveWorker,
      .make_dict     = &makeDictWorker,
    };
  }

  fn buildStencils() jit_mod.StencilTable {
    const s = stencils_mod;

    // Try all scan variants in order, most restrictive first.
    // scan3WithFrame as final fallback handles ReleaseFast tail-duplication
    // of the NEXT hole into multiple code paths (e.g. specDyad's 3 branches).
    const scanAll = struct {
      fn f(fn_addr: usize) ?stencils_mod.StencilInfo {
        return s.scanWithFrame(fn_addr)
          orelse s.scan(fn_addr)
          orelse s.scan2WithFrame(fn_addr)
          orelse s.scan3WithFrame(fn_addr);
      }
    }.f;

    const scan2 = struct {
      fn f(fn_addr: usize) ?stencils_mod.StencilInfo {
        return s.scan2WithFrame(fn_addr)
          orelse s.scan3WithFrame(fn_addr);
      }
    }.f;

    return .{
      .gap          = s.scan(@intFromPtr(&stencilGap)) orelse s.scanWithFrame(@intFromPtr(&stencilGap)),
      .dup          = scanAll(@intFromPtr(&stencilDup)),
      .int_         = s.scan(@intFromPtr(&stencilInt)) orelse s.scanWithFrame(@intFromPtr(&stencilInt)),
      .const_       = scanAll(@intFromPtr(&stencilConst)),
      .global       = scanAll(@intFromPtr(&stencilGlobal)),
      .local        = scanAll(@intFromPtr(&stencilLocal)),
      .local_last   = s.scan(@intFromPtr(&stencilLocalLast)) orelse s.scanWithFrame(@intFromPtr(&stencilLocalLast)),
      .assign_local = scanAll(@intFromPtr(&stencilAssignLocal)),
      .apply1       = scanAll(@intFromPtr(&stencilApply1)),
      .apply2       = scanAll(@intFromPtr(&stencilApply2)),
      .drop         = scanAll(@intFromPtr(&stencilDrop)),
      .assign_global = scanAll(@intFromPtr(&stencilAssignGlobal)),
      .make_list    = scanAll(@intFromPtr(&Stencil_make_list.f)),
      .derive       = scanAll(@intFromPtr(&Stencil_derive.f)),
      .make_dict    = scanAll(@intFromPtr(&Stencil_make_dict.f)),
      .return_      = s.scanTerminal(@intFromPtr(&stencilReturn)),
      .jump_false   = scan2(@intFromPtr(&stencilJumpFalse)),
      .jump_true    = scan2(@intFromPtr(&stencilJumpTrue)),
      // specDyad stencils: comptime-generated, up to 3 NEXT holes from LLVM tail-dup.
      .add_ii = scanAll(@intFromPtr(&Stencil_add_ii.f)),
      .sub_ii = scanAll(@intFromPtr(&Stencil_sub_ii.f)),
      .mul_ii = scanAll(@intFromPtr(&Stencil_mul_ii.f)),
      .lt_ii  = scanAll(@intFromPtr(&Stencil_lt_ii.f)),
      .gt_ii  = scanAll(@intFromPtr(&Stencil_gt_ii.f)),
      .eq_ii  = scanAll(@intFromPtr(&Stencil_eq_ii.f)),
      // SIMD array stencils: single-path, comptime-generated.
      // II and FF variants share the same stencil (worker distinguishes at runtime).
      .add_II = scanAll(@intFromPtr(&Stencil_add_simd.f)),
      .sub_II = scanAll(@intFromPtr(&Stencil_sub_simd.f)),
      .mul_II = scanAll(@intFromPtr(&Stencil_mul_simd.f)),
      .lt_II  = scanAll(@intFromPtr(&Stencil_lt_simd.f)),
      .gt_II  = scanAll(@intFromPtr(&Stencil_gt_simd.f)),
      .eq_II  = scanAll(@intFromPtr(&Stencil_eq_simd.f)),
      .add_FF = scanAll(@intFromPtr(&Stencil_add_simd.f)),
      .sub_FF = scanAll(@intFromPtr(&Stencil_sub_simd.f)),
      .mul_FF = scanAll(@intFromPtr(&Stencil_mul_simd.f)),
      .lt_FF  = scanAll(@intFromPtr(&Stencil_lt_simd.f)),
      .gt_FF  = scanAll(@intFromPtr(&Stencil_gt_simd.f)),
      .eq_FF  = scanAll(@intFromPtr(&Stencil_eq_simd.f)),
    };
  }

  fn buildHandlers() jit_mod.Handlers {
    return .{
      .gap           = @intFromPtr(&jhGap),
      .drop          = @intFromPtr(&jhDrop),
      .dup           = @intFromPtr(&jhDup),
      .int_          = @intFromPtr(&jhInt),
      .const_        = @intFromPtr(&jhConst),
      .global        = @intFromPtr(&jhGlobal),
      .local         = @intFromPtr(&jhLocal),
      .local_last    = @intFromPtr(&jhLocalLast),
      .assign_global = @intFromPtr(&jhAssignGlobal),
      .assign_local  = @intFromPtr(&jhAssignLocal),
      .apply1        = @intFromPtr(&jhApply1),
      .apply2        = @intFromPtr(&jhApply2),
      .call          = @intFromPtr(&jhCall),
      .tail_call     = @intFromPtr(&jhTailCall),
      .apply         = @intFromPtr(&jhApply),
      .make_partial  = @intFromPtr(&jhMakePartial),
      .make_list     = @intFromPtr(&jhMakeList),
      .derive        = @intFromPtr(&jhDerive),
      .make_dict     = @intFromPtr(&jhMakeDict),
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
