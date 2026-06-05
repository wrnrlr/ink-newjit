const std = @import("std");
const builtin = @import("builtin");
const Alloc = std.mem.Allocator;
const Chunk = @import("tape.zig").Chunk;
const OpCode = @import("tape.zig").OpCode;
const Compiler = @import("compiler.zig").Compiler;
const Registry = @import("registry.zig").Registry;
const command = @import("command.zig");
const FnTables = @import("fntable.zig").FnTables;
const assert = std.debug.assert;
const call = @import("call.zig");
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const K = @import("../noun/class.zig").K;
const opmod = @import("../noun/operator.zig");
const Fn = opmod.Fn;
const Op1 = opmod.Op1;
const Op2 = opmod.Op2;
const Op3 = opmod.Op3;
const Op4 = opmod.Op4;
const Adverb = opmod.Adverb;
const Partial = @import("../noun/partial.zig").Partial;
const Pool = @import("../noun/symbol.zig").Pool;
const ExtRegistry = @import("../noun/plugin.zig").ExtRegistry;
const Parser = @import("../parser/ast.zig").Parser;
const promote = @import("../primitive/promote.zig").promote;
const dispatch = @import("../primitive/dispatch.zig");
const fuse = @import("../primitive/derived/fuse.zig");
const MockWriter = @import("../util.zig").MockWriter;
const SlabAlloc = @import("../noun/slab.zig").SlabAlloc;

const STACK_MAX = 2048;
const FRAMES_MAX = 64;
const NO_LAMBDA: u24 = std.math.maxInt(u24); // lambda_idx = maxInt(u24) for top-level (no lambda)

pub const VMError = error{ StackOverflow, InvalidOpCode, RuntimeError };

const Frame = struct {
  ip:          usize = 0,
  base:        usize,
  result_slot: usize,
  lambda_idx:  u24,
};

pub const VM = struct {
  alloc: Alloc,
  slab:  SlabAlloc,
  parser: ?*Parser,
  compiler: *Compiler,
  chunk: *Chunk,
  stack:     [STACK_MAX]V  = undefined,
  stack_len: usize         = 0,
  frames:     [FRAMES_MAX]Frame = undefined,
  frames_len: usize             = 0,
  // Pool for Partial objects (partial function applications).
  partial_pool: std.heap.MemoryPool(Partial),

  symbols: Pool,
  globals: [256]V = undefined,
  globals_names: std.StringHashMap(u8),
  current_chunk: *Chunk,
  registry: Registry,
  fn_tables: FnTables,
  ext: ExtRegistry,
  out: ?*std.Io.Writer = null,
  prng: std.Random.DefaultPrng,
  argv: V = .blank,

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
      .alloc        = alloc,           // replaced below once slab is in place
      .slab         = SlabAlloc.init(alloc),
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
    vm.alloc = vm.slab.allocator();
    try vm.symbols.prefill();
    vm.compiler.* = try Compiler.init(alloc, chunk, &vm.globals_names, &vm.symbols, &vm.registry, &vm.fn_tables);
    @memset(&vm.globals, .blank);
    std.Io.Threaded.global_single_threaded.allocator = alloc;
    vm.pushFrame(.{ .base = 0, .result_slot = 0, .lambda_idx = NO_LAMBDA });
    return vm;
  }

  pub fn deinit(vm: *VM) void {
    vm.argv.deinit(vm.alloc);
    for (vm.stack[0..vm.stack_len]) |*v| v.deinit(vm.alloc);

    vm.compiler.deinit();
    vm.alloc.destroy(vm.compiler);

    vm.symbols.deinit();

    for (&vm.globals) |*v| v.deinit(vm.alloc);

    var kit = vm.globals_names.keyIterator();
    while (kit.next()) |k| vm.alloc.free(k.*);
    vm.globals_names.deinit();

    vm.fn_tables.deinit();
    vm.partial_pool.deinit(vm.alloc);
    vm.ext.deinit();
    vm.chunk.deinit();
    vm.alloc.destroy(vm.chunk);
    vm.registry.deinit();

    if (vm.parser) |p| {
      p.deinit();
      vm.alloc.destroy(p);
    }

    vm.slab.deinit();
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

    vm.compiler.scope.reset();
    vm.compiler.text_id = text_id;
    try vm.compiler.compile(node, false);
    try vm.run();

    return vm.pop();
  }

  // Compile `txt` once, appending its bytecode to the top-level chunk, and
  // return the ip where that bytecode begins. Paired with runFrom so callers
  // (e.g. the `\t:n` timing command) can execute it repeatedly without paying
  // the parse+compile+optimize cost on every iteration. Assumes the compiled
  // text is the final code in the chunk (true for the trailing `\t` statement).
  pub fn compileOnce(vm: *VM, txt: []const u8) !usize {
    const text_id = try vm.registry.addText(txt);
    const node = try vm.parser.?.parse(txt);
    defer vm.parser.?.free(node);
    vm.compiler.scope.reset();
    vm.compiler.text_id = text_id;
    const start_ip = vm.chunk.code.items.len;
    try vm.compiler.compile(node, false);
    return start_ip;
  }

  // Execute bytecode previously compiled at `start_ip` to completion on the
  // persistent top-level frame, returning the result value.
  pub fn runFrom(vm: *VM, start_ip: usize) !V {
    vm.resetStack();
    vm.current_chunk = vm.chunk;
    vm.currentFrame().ip = start_ip;
    try vm.run();
    return vm.pop();
  }

  fn executeCall(vm: *VM, func: V, incoming: []const V, mode: call.CallMode) !void {
    var fc = call.Call{ .vm = vm };
    try vm.push(fc.apply(func, incoming, mode == .bracket));
  }

  fn cleanStack(vm: *VM, res_slot:usize) V {
    for (vm.stack[res_slot..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = res_slot;
    return V{ .err = .memory };
  }

  // Direct lambda call without wrapper→apply overhead. Used by hot adverb loops.
  pub fn callLambdaAndRun(vm: *VM, ref: Fn, args: []const V) V {
    const prev_frames = vm.frames_len;
    const res_slot = vm.stack_len;
    vm.push(.blank) catch return V{ .err = .memory };
    for (args) |arg| vm.push(arg.ref()) catch return vm.cleanStack(res_slot);
    vm.callLambda(ref, args.len, res_slot) catch return vm.cleanStack(res_slot);
    vm.runUntil(prev_frames) catch {};
    return vm.pop();
  }

  // Move-semantics variant: transfers ownership of `args` into the lambda's
  // locals without bumping refcounts. Caller MUST NOT deinit args afterwards —
  // the Return frame cleanup handles them. This is what lets accumulator-
  // shaped adverb loops (ndo/fold/scan) reach rc==1 inside the lambda body so
  // in-place mutation (e.g. concat append) can fire.
  pub fn callLambdaAndRunMove(vm: *VM, ref: Fn, args: []const V) V {
    const prev_frames = vm.frames_len;
    const res_slot = vm.stack_len;
    vm.push(.blank) catch return V{ .err = .memory };
    for (args) |arg| vm.push(arg) catch return vm.cleanStack(res_slot);
    vm.callLambda(ref, args.len, res_slot) catch return vm.cleanStack(res_slot);
    vm.runUntil(prev_frames) catch {};
    return vm.pop();
  }

  fn run(vm: *VM) !void {
    try vm.runUntil(0);
  }

  pub fn runUntil(vm: *VM, min_frames: usize) !void {
    while (vm.frames_len > min_frames) {
      const frame = vm.currentFrame();
      const code = vm.current_chunk.code.items;
      if (frame.ip >= code.len) break;
      const b = code[frame.ip];
      frame.ip += 1;
      switch (@as(OpCode, @enumFromInt(b))) {
        .Nop => {},
        .Gap => try vm.push(.blank),
        .Drop => vm.pop().deinit(vm.alloc),
        .Dup => try vm.push(vm.peek(0).ref()),
        .Const => {
          const idx = code[frame.ip];
          frame.ip += 1;
          try vm.push(vm.current_chunk.constants.items[idx].ref());
        },
        .Int => {
          const raw: u16 = @as(u16, code[frame.ip]) | (@as(u16, code[frame.ip + 1]) << 8);
          frame.ip += 2;
          try vm.push(.{ .i = @as(i32, @as(i16, @bitCast(raw))) });
        },
        .Global => {
          const idx = code[frame.ip];
          frame.ip += 1;
          try vm.push(vm.globals[idx].ref());
        },
        .Local => {
          const idx = code[frame.ip];
          frame.ip += 1;
          try vm.push(vm.stack[frame.base + idx].ref());
        },
        .LocalLast => {
          const idx = code[frame.ip];
          frame.ip += 1;
          const slot = frame.base + idx;
          const v = vm.stack[slot];
          vm.stack[slot] = .blank;
          try vm.push(v);
        },
        .AssignGlobal => {
          const index = code[frame.ip];
          frame.ip += 1;
          const val = vm.pop();
          vm.globals[index].deinit(vm.alloc);
          vm.globals[index] = val;
          try vm.push(.blank);
        },
        .AssignLocal => {
          const index = code[frame.ip];
          frame.ip += 1;
          const val = vm.pop();
          const stack_idx = frame.base + index;
          vm.stack[stack_idx].deinit(vm.alloc);
          vm.stack[stack_idx] = val;
          try vm.push(.blank);
        },
        .ListAssignGlobal => try vm.doListAssignGlobal(),
        .ListAssignLocal => try vm.doListAssignLocal(),
        .Jump => {
          const offset: usize = @as(u16, code[frame.ip]) | (@as(u16, code[frame.ip + 1]) << 8);
          frame.ip += 2 + offset;
        },
        .JumpFalse => {
          const offset: usize = @as(u16, code[frame.ip]) | (@as(u16, code[frame.ip + 1]) << 8);
          frame.ip += 2;
          const v = vm.pop();
          defer v.deinit(vm.alloc);
          if (!v.isTrue()) frame.ip += offset;
        },
        .JumpTrue => {
          const offset: usize = @as(u16, code[frame.ip]) | (@as(u16, code[frame.ip + 1]) << 8);
          frame.ip += 2;
          const v = vm.pop();
          defer v.deinit(vm.alloc);
          if (v.isTrue()) frame.ip += offset;
        },
        .Apply1 => try VM.doApply1(vm),
        .Apply2 => try VM.doApply2(vm),
        .ReduceZip => try VM.doReduceZip(vm),
        .Apply3 => try VM.doApply3(vm),
        .Apply4 => try VM.doApply4(vm),
        .Return => try vm.doReturn(),
        .Call => try vm.doCallWithMode(.sync),
        .TailCall => try vm.doTailCall(),
        .Apply => try vm.doCallWithMode(.bracket),
        .MakeList => try vm.doMakeList(),
        .MakePartial => try vm.doMakePartial(),
        .Derive => try vm.doDerive(),
        .Command => try vm.doCommand(),
      }
    }
  }
  
  // NOTE: the simple opcodes (Const/Global/Int/Local/LocalLast/Assign*/Jump*)
  // are handled inline in the runUntil switch above; ListAssign and the
  // structural opcodes below keep dedicated helpers because the switch calls
  // them directly.
  fn doListAssignGlobal(vm: *VM) !void {
    const n = vm.readByte();
    const val = vm.pop();
    defer val.deinit(vm.alloc);
    const is_atom = std.meta.activeTag(val).isAtom();
    if (val.len() != n and !is_atom) {
      try vm.push(.{ .err = .length });
      for (0..n) |_| _ = vm.readByte();
    } else {
      for (0..n) |i| {
        const index = vm.readByte();
        vm.globals[index].deinit(vm.alloc);
        vm.globals[index] = val.at(i);
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

    if (func_val == .func) {
      const ref = func_val.func;
      const kind = ref.kind;
      // Tail-call lambda: reuse current frame instead of pushing a new one.
      if (kind == .callable and opmod.isLambdaIdx(ref.idx)) {
        const lambda_idx = opmod.lambdaIdxOf(ref.idx);
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
        return;
      }
      // Builtin call: dispatch directly without allocating a Call frame.
      if (kind == .callable and opmod.isBuiltinIdx(ref.idx)) {
        const idx = ref.idx;
        const result = if (opmod.isOp1Idx(idx)) blk: {
          if (argc == 1) break :blk dispatch.dispatch1(vm, opmod.op1OfIdx(idx), incoming[0]);
          break :blk V{ .err = .rank };
        } else if (opmod.isOp2Idx(idx)) blk: {
          const op2 = opmod.op2OfIdx(idx);
          if (argc == 2) break :blk dispatch.dispatch2(vm, op2, incoming[0], incoming[1]);
          if (argc == 1) {
            if (opmod.op2ToOp1[@intFromEnum(op2)]) |op1|
              break :blk dispatch.dispatch1(vm, op1, incoming[0]);
            break :blk V{ .err = .rank };
          }
          break :blk V{ .err = .rank };
        } else V{ .err = .nyi }; // adverbs/Op3/Op4 via tail-call path: defer to executeCall below
        if (result.tag() != .err or result.err != .nyi) {
          for (incoming) |*v| v.deinit(vm.alloc);
          try vm.push(result);
          return;
        }
      }
      // Derived (builtin or lambda base): hand to applyDerivedBuiltin.
      if (kind == .derived) {
        const result = call.applyDerivedBuiltin(vm, ref, incoming);
        for (incoming) |*v| v.deinit(vm.alloc);
        try vm.push(result);
        return;
      }
      // Fallback (adverb/Op3/Op4 standalone, train, derived_data).
      try vm.executeCall(func_val, incoming, .sync);
      for (incoming) |*v| v.deinit(vm.alloc);
    } else {
      try vm.executeCall(func_val, incoming, .sync);
      for (incoming) |*v| v.deinit(vm.alloc);
    }
  }

  fn doCallWithMode(vm: *VM, mode: call.CallMode) !void {
    const argc = vm.readByte();
    var buf: [8]V = .{.blank} ** 8;
    const incoming = buf[0..argc];
    for (0..argc) |i| incoming[argc - 1 - i] = vm.pop();
    const func_val = vm.pop();
    try vm.executeCall(func_val, incoming, mode);
    for (incoming) |*v| v.deinit(vm.alloc);
    func_val.deinit(vm.alloc);
  }
  
  fn doApply1(vm: *VM) !void {
    const op: Op1 = @enumFromInt(vm.readByte());
    const a = vm.pop();
    defer a.deinit(vm.alloc);
    try vm.push(dispatch.dispatch1(vm, op, a));
  }

  fn doApply2(vm: *VM) !void {
    const op: Op2 = @enumFromInt(vm.readByte());
    const b = vm.pop();
    defer b.deinit(vm.alloc);
    const a = vm.pop();
    defer a.deinit(vm.alloc);
    try vm.push(dispatch.dispatch2(vm, op, a, b));
  }

  // Fused reduce-of-zip: 2 op bytes (Op1 reduce, Op2 bin), pops 2 args.
  fn doReduceZip(vm: *VM) !void {
    const red: Op1 = @enumFromInt(vm.readByte());
    const bin: Op2 = @enumFromInt(vm.readByte());
    const b = vm.pop();
    defer b.deinit(vm.alloc);
    const a = vm.pop();
    defer a.deinit(vm.alloc);
    try vm.push(fuse.reduceZip(vm, red, bin, a, b));
  }

  fn doApply3(vm: *VM) !void {
    const op: Op3 = @enumFromInt(vm.readByte());
    const start = vm.stack_len - 3;
    const args = vm.stack[start..vm.stack_len];
    const res = if (hasBlank(args)) call.makePartialFromArgs(vm, Fn.triad(op), args)
      else dispatch.dispatch3(vm, op, args[0], args[1], args[2]);
    for (args) |*v| v.deinit(vm.alloc);
    vm.stack_len = start;
    try vm.push(res);
  }

  fn doApply4(vm: *VM) !void {
    const op: Op4 = @enumFromInt(vm.readByte());
    const start = vm.stack_len - 4;
    const args = vm.stack[start..vm.stack_len];
    const res = if (hasBlank(args)) call.makePartialFromArgs(vm, Fn.tetrad(op), args)
      else dispatch.dispatch4(vm, op, args[0], args[1], args[2], args[3]);
    for (args) |*v| v.deinit(vm.alloc);
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
      break :blk switch (ref.kind) {
        // Any callable (builtin verb/adverb or lambda) uses its global idx.
        .callable => Fn.makeDerived(ref.idx, ref.arity, adv),
        // Trains as base aren't directly representable as a single global idx;
        // stash the base V in the derived table.
        else => blk2: {
          const idx = try vm.fn_tables.addDerived(.{ .base = V{ .func = ref }, .adverb = adv });
          break :blk2 Fn.makeDerivedTable(idx, adv);
        },
      };
    } else blk: {
      // Data base (e.g. I vector for radix encode/decode, C for join/split)
      const idx = try vm.fn_tables.addDerived(.{ .base = base_v, .adverb = adv });
      break :blk Fn.makeDerivedTable(idx, adv);
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
    // try vm.push(list_val);
    try vm.push(promote(vm.alloc, list_val.L));
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
    const idx = opmod.lambdaIdxOf(ref.idx);
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

fn hasBlank(vals:[]V) bool {
   for (vals) |a| if (a == .blank) return true;
   return false;
}

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
  try vm.chunk.write(@intFromEnum(Op2.@"+"));
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
