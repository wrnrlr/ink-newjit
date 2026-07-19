const std = @import("std");
const builtin = @import("builtin");
const Alloc = std.mem.Allocator;
const Chunk = @import("tape.zig").Chunk;
const OpCode = @import("tape.zig").OpCode;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Fs    = @import("registry.zig").Fs;
const Conns = @import("registry.zig").Conns;
const command = @import("command.zig");
const home = @import("../home.zig");
const FnTables = @import("fntable.zig").FnTables;
const call = @import("call.zig");
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;
const K = @import("../noun/class.zig").K;
const opmod = @import("../noun/operator.zig");
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
const Partials = std.heap.MemoryPool(Partial);

const STACK_MAX = 2048;
const FRAMES_MAX = 64;
// Global slots. Indexed by a u16 in the bytecode (.Global/.AssignGlobal/list-assign),
// so a program may define up to this many distinct global names (was 256).
pub const MAX_GLOBALS = 4096;
const NO_LAMBDA: u24 = std.math.maxInt(u24); // lambda_idx = maxInt(u24) for top-level (no lambda)

pub const VMError = error{ StackOverflow, InvalidOpCode, RuntimeError };

const Frame = struct {
  ip:          usize = 0,
  base:        usize,
  result_slot: usize,
  lambda_idx:  u24,
};

pub const VM = struct {
  alloc: Alloc, slab:  SlabAlloc,
  parser: ?*Parser, compiler: *Compiler,
  chunk: *Chunk,
  stack: [STACK_MAX]V = undefined, stack_len: usize = 0,
  frames: [FRAMES_MAX]Frame = undefined, frames_len: usize = 0,
  partials: Partials, symbols: Pool,
  globals: [MAX_GLOBALS]V = undefined, names: std.StringHashMap(u16),
  current_chunk: *Chunk,
  fs: Fs, conns: Conns,
  listen_handle: ?u32 = null,
  fn_tables: FnTables,
  ext: ExtRegistry,
  out: ?*std.Io.Writer = null,
  prng: std.Random.DefaultPrng,
  argv: V = .blank,
  // Optional in-memory file overlay (path → content), consulted before disk by
  // load()/mapFile().  Set by `ink bundle` executables to read their embedded
  // k modules; null for normal runs.
  vfs: ?*const std.StringHashMap([]const u8) = null,

  pub const Monad = *const fn (*VM, V) V;
  pub const Dyad = *const fn (*VM, V, V) V;

  pub fn aList(vm:VM) !V { return .{.L = try N(V).init(vm.alloc, 0)}; }

  pub fn create(alloc: Alloc) !*VM {
    const vm = try alloc.create(VM);
    const parser = try alloc.create(Parser);
    parser.* = Parser.init(alloc);
    const symbols = Pool.init(alloc);
    vm.* = .{
      .alloc        = alloc,           // replaced below once slab is in place
      .slab         = SlabAlloc.init(alloc),
      .parser       = parser,
      .compiler     = undefined,       // created below, via the slab
      .chunk        = undefined,
      .current_chunk = undefined,
      .partials  = .empty,
      .symbols       = symbols,
      .names = std.StringHashMap(u16).init(alloc),
      .fs      = try Fs.init(alloc),
      .conns   = Conns.init(alloc),
      .fn_tables     = FnTables.init(alloc),
      .ext           = ExtRegistry.init(alloc),
      .prng          = std.Random.DefaultPrng.init(0),
    };
    vm.alloc = vm.slab.allocator();
    // Derived bases are slab-allocated runtime values; free them via the slab.
    vm.fn_tables.value_alloc = vm.alloc;
    // The main chunk, lambda chunks, and every literal constant the compiler emits
    // hold values that can escape into runtime values freed via the slab. Create
    // the chunk and the compiler with the slab (now that it's in place) so each
    // value is allocated AND freed by the same allocator — otherwise a const
    // alloc'd raw but freed via the slab (or vice versa) trips a DebugAllocator
    // alignment mismatch (the allocator-ordering trap; see fn_tables above).
    const chunk = try vm.alloc.create(Chunk);
    chunk.* = try Chunk.init(vm.alloc);
    vm.chunk = chunk;
    vm.current_chunk = chunk;
    vm.compiler = try vm.alloc.create(Compiler);
    try vm.symbols.prefill();
    vm.compiler.* = try Compiler.init(vm.alloc, chunk, &vm.names, &vm.symbols, &vm.fs, &vm.fn_tables);
    @memset(&vm.globals, .blank);
    std.Io.Threaded.global_single_threaded.allocator = alloc;
    vm.pushFrame(.{ .base = 0, .result_slot = 0, .lambda_idx = NO_LAMBDA });
    vm.loadPrelude();
    return vm;
  }

  // Load the CPU builtins (lib/prelude.k: the math names removed from the grammar
  // in Phase 1, etc.) into every fresh VM. Best-effort — a missing prelude just
  // leaves those names unbound. Runs at the top level (not a nested `2:`), so it's
  // safe; globals persist in vm.globals. See doc/design/dye.md.
  fn loadPrelude(vm: *VM) void {
    const r = vm.load("prelude") catch return;
    r.deinit(vm.alloc);
  }

  pub fn deinit(vm: *VM) void {
    vm.argv.deinit(vm.alloc);
    for (vm.stack[0..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.compiler.deinit();
    vm.alloc.destroy(vm.compiler);
    vm.symbols.deinit();
    for (&vm.globals) |*v| v.deinit(vm.alloc);
    var kit = vm.names.keyIterator();
    while (kit.next()) |k| vm.alloc.free(k.*);
    vm.names.deinit();
    vm.fn_tables.deinit();
    vm.partials.deinit(vm.alloc);
    vm.ext.deinit();
    vm.chunk.deinit();
    vm.alloc.destroy(vm.chunk);
    vm.fs.deinit();
    vm.conns.deinit();
    if (vm.parser) |p| { p.deinit(); vm.alloc.destroy(p); }
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
    const tid = try vm.fs.addText(txt);
    return vm.interpret(txt, tid);
  }

  // Std-lib shorthand: a bare name with no path separator and no extension
  // (`math`) resolves to the k file `lib/math.k`, searching the working-dir lib
  // (dev tree), $INK_HOME/lib (installed), and the embedded bundle overlay.
  // Returns an allocated path when a candidate exists, else `path` unchanged.
  // Callers free the result only when `result.ptr != path.ptr`.
  fn resolveLibPath(vm: *VM, path: []const u8) []const u8 {
    if (path.len == 0) return path;
    if (std.mem.indexOfScalar(u8, path, '/') != null) return path;
    if (std.mem.indexOfScalar(u8, path, '.') != null) return path;
    // ./lib/<name>.k — also the key form used by the bundle overlay.
    const rel = std.fmt.allocPrint(vm.alloc, "lib/{s}.k", .{path}) catch return path;
    if (vm.vfs) |vfs| if (vfs.contains(rel)) return rel;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.Io.Dir.cwd().access(io, rel, .{})) |_| return rel else |_| {}
    // $INK_HOME/lib/<name>.k (installed layout).
    var hbuf: [512]u8 = undefined;
    if (home.dir(&hbuf)) |hdir| {
      const abs = std.fmt.allocPrint(vm.alloc, "{s}/lib/{s}.k", .{ hdir, path }) catch { vm.alloc.free(rel); return path; };
      if (std.Io.Dir.cwd().access(io, abs, .{})) |_| { vm.alloc.free(rel); return abs; } else |_| vm.alloc.free(abs);
    }
    vm.alloc.free(rel);
    return path;
  }

  // Read a file's text by path, consulting the in-memory overlay (vfs) before
  // disk.  Applies the std-lib shorthand (`math` → `lib/math.k`).  Caller owns
  // the returned buffer.
  pub fn readFileText(vm: *VM, path: []const u8) ![]u8 {
    const p = vm.resolveLibPath(path);
    defer if (p.ptr != path.ptr) vm.alloc.free(p);
    if (vm.vfs) |vfs| if (vfs.get(p)) |content| return vm.alloc.dupe(u8, content);
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, p, vm.alloc, std.Io.Limit.limited(10 * 1024 * 1024));
  }

  pub fn load(vm: *VM, path: []const u8) !V {
    const text = try vm.readFileText(path);
    const text_id = try vm.fs.addFile(path, text);
    // A loaded module's `\d` namespace must not leak into the caller's scope.
    const saved_ns = vm.compiler.namespace;
    defer vm.compiler.namespace = saved_ns;
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

  pub fn compileOnce(vm: *VM, txt: []const u8) !usize {
    const text_id = try vm.fs.addText(txt);
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

  // Re-entrant module eval for a NESTED `2:` load (a `2:` executed while another
  // file is running). Unlike interpret(), it does NOT resetStack/reset the caller's
  // frame — it compiles the module, runs it on its OWN top-level frame above the
  // caller's stack (runUntil the caller's frame level), then restores the caller's
  // stack/frame/chunk and returns the module's result. This is what lets a
  // `2:`-loaded file itself `2:`-load another (e.g. dye.k → spirv.k).
  pub fn evalNested(vm: *VM, txt: []const u8) anyerror!V {
    const prev_frames = vm.frames_len;
    const res_slot = vm.stack_len;
    const saved_chunk = vm.current_chunk;
    const start_ip = try vm.compileOnce(txt);   // appends to vm.chunk, returns its start ip
    vm.current_chunk = vm.chunk;
    vm.pushFrame(.{ .ip = start_ip, .base = res_slot, .result_slot = res_slot, .lambda_idx = NO_LAMBDA });
    vm.runUntil(prev_frames) catch |e| {
      vm.frames_len = prev_frames;
      vm.current_chunk = saved_chunk;
      vm.chunk.code.shrinkRetainingCapacity(start_ip);
      for (vm.stack[res_slot..vm.stack_len]) |*v| v.deinit(vm.alloc);
      vm.stack_len = res_slot;
      return e;
    };
    // The module's top-level code has no Return, so it ran to code end and broke out
    // of runUntil with its frame still on. Take its last value, then restore. Truncate
    // the module's appended top-level code off the shared chunk so the caller's
    // code.len (and its own code-end detection) is restored — else the caller runs
    // past its end into the appended module code. (Lambda chunks the module created
    // are separate and survive; the globals it defined persist.)
    const result = if (vm.stack_len > res_slot) vm.pop() else V.blank;
    for (vm.stack[res_slot..vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = res_slot;
    vm.frames_len = prev_frames;
    vm.current_chunk = saved_chunk;
    vm.chunk.code.shrinkRetainingCapacity(start_ip);
    return result;
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
  pub fn callLambdaAndRun(vm: *VM, ref: opmod.Fn, args: []const V) V {
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
  pub fn callLambdaAndRunMove(vm: *VM, ref: opmod.Fn, args: []const V) V {
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
          const idx: u16 = @as(u16, code[frame.ip]) | (@as(u16, code[frame.ip + 1]) << 8);
          frame.ip += 2;
          try vm.push(vm.current_chunk.constants.items[idx].ref());
        },
        .Int => {
          const raw: u16 = @as(u16, code[frame.ip]) | (@as(u16, code[frame.ip + 1]) << 8);
          frame.ip += 2;
          try vm.push(.{ .i = @as(i32, @as(i16, @bitCast(raw))) });
        },
        .Global => {
          const idx: u16 = @as(u16, code[frame.ip]) | (@as(u16, code[frame.ip + 1]) << 8);
          frame.ip += 2;
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
          const index: u16 = @as(u16, code[frame.ip]) | (@as(u16, code[frame.ip + 1]) << 8);
          frame.ip += 2;
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
        .Apply1    => try vm.doApply(1, call1),
        .Apply2    => try vm.doApply(2, call2),
        .ReduceZip => try vm.doApply(2, reduceZip),
        .FusedMap  => try vm.doFusedMap(),
        .Apply3    => try vm.doApply(3, call3),
        .Apply4    => try vm.doApply(4, call4),
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
    const n = vm.readByte(); // target count (small) — the per-target indices are u16
    const val = vm.pop();
    defer val.deinit(vm.alloc);
    const is_atom = std.meta.activeTag(val).isAtom();
    if (val.len() != n and !is_atom) {
      try vm.push(.{ .err = .length });
      for (0..n) |_| _ = vm.read16();
    } else {
      for (0..n) |i| {
        const index = vm.read16();
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
    std.debug.assert(vm.stack_len >= frame.base);

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

    if (func_val == .o) {
      const ref = func_val.o;
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
  
  pub inline fn size(vm: *VM) usize { return vm.stack_len; }
  pub inline fn cut(vm: *VM, c: usize) []V { const s = vm.size(); return vm.stack[s-c..s]; }
  pub inline fn slice(vm: *VM, n: usize, m: usize) []V { return vm.stack[n..m]; }

  pub fn call1(vm: *VM, op: u8, a: []V) V {
    return dispatch.dispatch1(vm, @enumFromInt(op), a[0]);
  }
  pub fn call2(vm: *VM, op: u8, a: []V) V {
    return dispatch.dispatch2(vm, @enumFromInt(op), a[0], a[1]);
  }
  pub fn call3(vm: *VM, op: u8, a: []V) V {
    const o: opmod.Op3 = @enumFromInt(op);
    return if (hasBlank(a)) call.makePartialFromArgs(vm, opmod.Fn.triad(o), a)
           else dispatch.dispatch3(vm, o, a[0], a[1], a[2]);
  }
  pub fn call4(vm: *VM, op: u8, a: []V) V {
    const o: opmod.Op4 = @enumFromInt(op);
    return if (hasBlank(a)) call.makePartialFromArgs(vm, opmod.Fn.tetrad(o), a)
           else dispatch.dispatch4(vm, o, a[0], a[1], a[2], a[3]);
  }
  // Fused reduce-of-zip: reads a second op byte (bin) after the primary (red).
  fn reduceZip(vm: *VM, op: u8, a: []V) V {
    const bin: opmod.Op2 = @enumFromInt(vm.readByte());
    return fuse.reduceZip(vm, @enumFromInt(op), bin, a[0], a[1]);
  }

  // Fused elementwise map: reads a u16 kernel index, consumes the kernel's
  // `ncol` leaf operands off the stack, evaluates the postfix program in one
  // chunked pass, and pushes the result.
  fn doFusedMap(vm: *VM) !void {
    const idx = vm.read16();
    const k = &vm.current_chunk.kernels.items[idx];
    const ncol: usize = k.ncol;
    const s = vm.size();
    const args = vm.stack[s - ncol .. s];
    const r = fuse.fusedMap(vm, k, args);
    for (args) |*v| v.deinit(vm.alloc);
    vm.stack_len = s - ncol;
    try vm.push(r);
  }

  // Generic apply: reads opcode, takes top N args, calls F, cleans up, pushes result.
  fn doApply(vm: *VM, comptime arity: usize, comptime F: anytype) !void {
    const op = vm.readByte();
    const s  = vm.size();
    const a  = vm.cut(arity);
    const r  = F(vm, op, a);
    for (a) |*v| v.deinit(vm.alloc);
    vm.stack_len = s - arity;
    try vm.push(r);
  }
  
  fn doMakePartial(vm: *VM) !void {
    const argc = vm.readByte();
    const mask = vm.readByte();
    const args_start = vm.stack_len - argc;
    const stack_args = vm.stack[args_start..vm.stack_len];
    const func_val = vm.stack[args_start - 1];

    // Extract base func and existing args from func (possibly already a partial)
    var base_ref: opmod.Fn = undefined;
    var existing: [8]V = .{.blank} ** 8;
    var existing_fill: u8 = 0;
    if (func_val == .p) {
      const p = func_val.asPartial();
      base_ref = p.ref;
      existing = p.args;
      existing_fill = p.fill;
    } else if (func_val == .o) {
      base_ref = func_val.o;
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

    const p = try vm.partials.create(vm.alloc);
    p.* = .{ .pool = &vm.partials, .rc = 1, .fill = fill, .arity = arity, ._pad = 0, .ref = base_ref, .args = merged };

    for (vm.stack[args_start - 1 .. vm.stack_len]) |*v| v.deinit(vm.alloc);
    vm.stack_len = args_start - 1;
    try vm.push(.{ .p = p });
  }

  fn doDerive(vm: *VM) !void {
    const adv: Adverb = @enumFromInt(vm.readByte());
    const base_v = vm.pop();
    const derived: opmod.Fn = if (base_v == .o) blk: {
      const ref = base_v.o;
      base_v.deinit(vm.alloc);
      break :blk switch (ref.kind) {
        // Any callable (builtin verb/adverb or lambda) uses its global idx.
        .callable => opmod.Fn.makeDerived(ref.idx, ref.arity, adv),
        // Trains as base aren't directly representable as a single global idx;
        // stash the base V in the derived table.
        else => blk2: {
          const idx = try vm.fn_tables.addDerived(.{ .base = V{ .o = ref }, .adverb = adv });
          break :blk2 opmod.Fn.makeDerivedTable(idx, adv);
        },
      };
    } else blk: {
      // Data base (e.g. I vector for radix encode/decode, C for join/split)
      const idx = try vm.fn_tables.addDerived(.{ .base = base_v, .adverb = adv });
      break :blk opmod.Fn.makeDerivedTable(idx, adv);
    };
    try vm.push(.{ .o = derived });
  }
  
  fn doMakeList(vm: *VM) !void {
    const argc = vm.read16();
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

  pub fn callLambda(vm: *VM, ref: opmod.Fn, argc: usize, slot: usize) !void {
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
    if (vm.fs.findFile(path)) |id| return id;
    const text = try vm.readFileText(path);
    return try vm.fs.addFile(path, text);
  }

  // Map a path for WRITING: a missing file is fine (it will be created on the
  // first write), so register it with empty content instead of erroring. This
  // is what lets `"new.txt" 1: bytes` create a file that doesn't exist yet.
  pub fn mapFileW(vm: *VM, path: []const u8) !u32 {
    if (vm.fs.findFile(path)) |id| return id;
    const text = vm.readFileText(path) catch try vm.alloc.dupe(u8, "");
    return try vm.fs.addFile(path, text);
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
  const vm = try VM.create(std.testing.allocator);
  defer vm.deinit();
  const c1 = try vm.chunk.addConstant(.{ .i = 10 });
  const c2 = try vm.chunk.addConstant(.{ .i = 20 });
  try vm.chunk.writeOp(.Const);
  try vm.chunk.write16(c1);
  try vm.chunk.writeOp(.Const);
  try vm.chunk.write16(c2);
  try vm.chunk.writeOp(.Apply2);
  try vm.chunk.write(@intFromEnum(opmod.Op2.@"+"));
  try vm.chunk.writeOp(.Return);
  try vm.run();
  const res = vm.pop();
  defer res.deinit(std.testing.allocator);
  try std.testing.expectEqual(@as(i32, 30), res.i);
}
