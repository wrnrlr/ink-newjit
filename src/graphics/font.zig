const std = @import("std");
const shape = @import("shape.zig");
const data = @import("data.zig");
const tatfi = @import("tatfi");

// ─── Internal arena block ────────────────────────────────────────────────────

const ArenaBlock = struct {
  header: shape.ArenaBlockHeader,
  base_allocation: ?*anyopaque,
  size: usize,
  used: usize,
  // memory follows in-place
};

// ─── Internal arena lifetime ─────────────────────────────────────────────────

const ArenaLifetime = struct {
  arena: ?*shape.Arena,
  block_header: ?*shape.ArenaBlockHeader,
  used: usize,
};

// ─── Context font ────────────────────────────────────────────────────────────

const ContextFont = struct {
  font: ?*shape.Font,
  lifetime: ArenaLifetime,
};

// ─── Existing shape/glyph config bookkeeping ─────────────────────────────────

const ExistingShapeConfig = struct {
  config: ?*shape.ShapeConfig,
  font: ?*shape.Font,
  script: shape.Script,
};

const ExistingShapeConfigBlockHeader = struct {
  prev: ?*ExistingShapeConfigBlockHeader,
  next: ?*ExistingShapeConfigBlockHeader,
};

const ExistingShapeConfigBlock = struct {
  header: ExistingShapeConfigBlockHeader,
  count: u32,
  items: [32]ExistingShapeConfig,
};

const ExistingGlyphConfig = struct {
  feature_overrides: ?[*]shape.FeatureOverride,
  feature_override_count: i32,
  glyph_config: ?*shape.GlyphConfig,
};

const ExistingGlyphConfigBlockHeader = struct {
  prev: ?*ExistingGlyphConfigBlockHeader,
  next: ?*ExistingGlyphConfigBlockHeader,
};

const ExistingGlyphConfigBlock = struct {
  header: ExistingGlyphConfigBlockHeader,
  count: u32,
  items: [32]ExistingGlyphConfig,
};

// ─── Internal context (behind shape.ShapeContext opaque) ─────────────────────

const context_flag_manual_segmentation: u32 = 1;
const context_flag_start_of_manual_run: u32 = 2;
const context_flag_use_manual_break_info: u32 = 4;

const InternalContext = struct {
  permanent_arena: shape.Arena,
  font_arena: shape.Arena,
  config_arena: shape.Arena,
  scratch_arena: shape.Arena,

  self_allocator: ?shape.AllocatorFn,
  self_allocator_data: ?*anyopaque,

  last_grapheme_break: ?*shape.ShapeCodepoint,
  last_grapheme_break_index: u32,
  last_line_break_index: u32,
  break_start_index: u32,

  font_count: u32,
  fonts: [32]ContextFont,

  input_codepoint_count: usize,
  next_user_id: i32,
  input_blocks: [21]?[*]shape.ShapeCodepoint,

  glyph_storage: shape.GlyphStorage,

  flags: u32,
  manual_run_direction: shape.Direction,
  manual_run_script: shape.Script,

  current_feature_overrides: ?[*]shape.FeatureOverride,
  current_feature_override_count: u32,
  need_new_glyph_config: i32,

  paragraph_direction: shape.Direction,
  language: shape.Language,

  run_font: ?*shape.Font,
  run_script: shape.Script,
  run_paragraph_direction: shape.Direction,
  run_direction: shape.Direction,
  run_codepoint_iterator: shape.ShapeCodepointIterator,
  done_shaping_runs: i32,

  existing_shape_config_sentinel: ExistingShapeConfigBlockHeader,
  existing_glyph_config_sentinel: ExistingGlyphConfigBlockHeader,

  scratch_feature_override_count: u32,
  scratch_feature_overrides: [32]shape.FeatureOverride,

  break_state: shape.BreakState,
  err: shape.ShapeError,
};

// ─── Script extensions data (from kb_text_shape.h line 5211) ─────────────────

const script_extensions = [447]u8{
  6,18,24,25,35,37,41,42,43,45,47,72,79,80,112,132,11,28,32,72,77,155,160,13,72,72,155,22,25,28,45,72,
  112,141,146,22,28,45,72,119,141,146,159,22,28,72,157,42,72,141,143,155,19,22,25,28,43,45,72,119,143,157,159,25,
  37,42,43,62,72,25,35,54,72,112,143,146,157,159,5,28,35,43,45,54,72,112,143,146,35,72,143,22,28,72,119,22,
  72,146,39,72,28,72,159,45,72,112,159,22,35,62,72,143,22,35,72,143,22,72,143,19,22,43,72,141,155,19,72,159,
  25,45,28,112,28,42,5,41,42,4,40,51,103,143,154,167,4,143,154,1,4,40,51,103,143,154,167,1,4,51,83,84,
  117,126,135,143,4,154,167,11,32,44,46,48,61,72,82,118,131,150,153,158,11,32,44,46,48,61,72,82,118,150,153,158,
  11,32,34,44,46,47,48,61,69,80,82,86,100,108,118,136,142,149,150,153,158,11,32,34,44,46,47,48,49,61,69,74,
  80,82,86,100,108,118,136,142,149,150,153,158,32,34,60,80,11,20,142,48,96,46,68,44,150,61,100,161,20,97,146,41,
  42,72,16,52,144,145,94,124,11,32,44,61,32,131,32,61,82,118,150,153,32,100,11,32,44,61,82,100,118,136,153,158,
  161,32,44,61,161,28,72,143,72,94,124,18,41,42,78,110,116,18,45,91,110,32,44,72,25,72,6,116,6,18,41,60,
  79,110,129,1,4,110,24,152,13,24,50,55,62,94,168,13,24,50,55,62,94,124,168,13,24,50,55,62,94,156,168,13,
  24,50,55,62,77,94,156,168,13,24,50,55,62,168,24,55,62,24,72,32,34,46,48,60,61,68,69,80,82,93,100,131,
  149,158,161,32,34,46,48,60,61,68,69,80,93,100,131,149,158,161,32,34,46,48,60,68,69,80,93,149,158,32,34,46,
  48,60,68,69,80,93,131,149,158,11,32,161,32,150,64,72,97,15,59,4,103,26,27,76,26,76,26,75,76,4,25,
};

// ─── Grapheme break transition table ─────────────────────────────────────────
// [18 classes][13 states]

const grapheme_break_transition = [18][13]u8{
  .{ 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 0 },
  .{ 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17 },
  .{ 15, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15 },
  .{ 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15 },
  .{ 0, 16, 0, 0, 0, 0, 0, 0, 9, 9, 0, 0, 0 },
  .{ 0, 16, 0, 0, 0, 6, 6, 7, 10, 10, 0, 0, 0 },
  .{ 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
  .{ 18, 18, 2, 18, 18, 18, 18, 16, 18, 18, 18, 18, 2 },
  .{ 19, 19, 3, 3, 19, 19, 19, 16, 19, 19, 19, 19, 3 },
  .{ 19, 19, 3, 19, 19, 19, 19, 16, 19, 19, 19, 19, 3 },
  .{ 20, 20, 4, 20, 20, 20, 20, 16, 20, 20, 20, 20, 4 },
  .{ 20, 20, 20, 4, 4, 20, 20, 16, 20, 20, 20, 20, 4 },
  .{ 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 12 },
  .{ 21, 21, 21, 21, 21, 21, 21, 5, 21, 21, 21, 21, 5 },
  .{ 0, 16, 0, 0, 0, 6, 6, 7, 9, 9, 0, 0, 0 },
  .{ 5, 21, 5, 5, 5, 7, 7, 7, 5, 5, 5, 5, 5 },
  .{ 24, 24, 24, 24, 24, 24, 24, 16, 24, 24, 0, 24, 8 },
  .{ 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 0, 11 },
};

// ─── Line break constants ─────────────────────────────────────────────────────

const lb_allowed0: u64 = 1;
const lb_allowed1: u64 = 3;
const lb_allowed2: u64 = 7;
const lb_allowed3: u64 = 0xF;
const lb_allowed4: u64 = 0x1F;
const lb_allowed5: u64 = 0x3F;
const lb_required0: u64 = (1 << 6) | lb_allowed0;
const lb_required1: u64 = (3 << 6) | lb_allowed1;
const lb_required2: u64 = (7 << 6) | lb_allowed2;
const lb_required3: u64 = (0xF << 6) | lb_allowed3;
const lb_required4: u64 = (0x1F << 6) | lb_allowed4;
const lb_required5: u64 = (0x3F << 6) | lb_allowed5;
const lb_required_mask: u64 = 0x3F << 6;
const lb_allowed_mask: u64 = 0x3F;
const lb_mask: u64 = lb_required_mask | lb_allowed_mask;

// ─── Break state flags ────────────────────────────────────────────────────────

const bsf_started: u32 = 1;
const bsf_end: u32 = 2;
const bsf_saw_r_after_l: u32 = 8;
const bsf_saw_al_after_lr: u32 = 0x10;
const bsf_last_was_bracket: u32 = 0x20;

// ─── Flush flags ──────────────────────────────────────────────────────────────

const ff_script: u32 = 1 << 0;
const ff_direction_2: u32 = 1 << 1;
const ff_direction_1: u32 = 1 << 2;
const ff_direction_paragraph: u32 = 1 << 3;

// ─── Break flags ─────────────────────────────────────────────────────────────

const BF = shape.BreakFlags;
const DIRECTION: u32 = BF.direction;
const SCRIPT: u32 = BF.script;
const GRAPHEME: u32 = BF.grapheme;
const WORD: u32 = BF.word;
const LINE_SOFT: u32 = BF.line_soft;
const LINE_HARD: u32 = BF.line_hard;
const PARAGRAPH_DIRECTION: u32 = BF.paragraph_direction;
const LINE: u32 = BF.line;
const MANUAL: u32 = BF.manual;

// ─── Bidi class aliases ───────────────────────────────────────────────────────
const BC = shape.UnicodeBidirectionalClass;
const bc_ni: u8 = @intFromEnum(BC.ni);
const bc_bn: u8 = @intFromEnum(BC.bn);
const bc_l: u8 = @intFromEnum(BC.l);
const bc_r: u8 = @intFromEnum(BC.r);
const bc_nsm: u8 = @intFromEnum(BC.nsm);
const bc_al: u8 = @intFromEnum(BC.al);
const bc_an: u8 = @intFromEnum(BC.an);
const bc_en: u8 = @intFromEnum(BC.en);
const bc_es: u8 = @intFromEnum(BC.es);
const bc_et: u8 = @intFromEnum(BC.et);
const bc_cs: u8 = @intFromEnum(BC.cs);

// ─── Word break class aliases ─────────────────────────────────────────────────
const WBC = shape.WordBreakClass;
const wbc_onep: u8 = @intFromEnum(WBC.onep);
const wbc_oep: u8 = @intFromEnum(WBC.oep);
const wbc_cr: u8 = @intFromEnum(WBC.cr);
const wbc_lf: u8 = @intFromEnum(WBC.lf);
const wbc_nl: u8 = @intFromEnum(WBC.nl);
const wbc_ex: u8 = @intFromEnum(WBC.ex);
const wbc_zwj: u8 = @intFromEnum(WBC.zwj);
const wbc_ri: u8 = @intFromEnum(WBC.ri);
const wbc_fo: u8 = @intFromEnum(WBC.fo);
const wbc_ka: u8 = @intFromEnum(WBC.ka);
const wbc_hl: u8 = @intFromEnum(WBC.hl);
const wbc_alnep: u8 = @intFromEnum(WBC.alnep);
const wbc_alep: u8 = @intFromEnum(WBC.alep);
const wbc_sq: u8 = @intFromEnum(WBC.sq);
const wbc_dq: u8 = @intFromEnum(WBC.dq);
const wbc_mnl: u8 = @intFromEnum(WBC.mnl);
const wbc_ml: u8 = @intFromEnum(WBC.ml);
const wbc_mn: u8 = @intFromEnum(WBC.mn);
const wbc_nm: u8 = @intFromEnum(WBC.nm);
const wbc_enl: u8 = @intFromEnum(WBC.enl);
const wbc_wss: u8 = @intFromEnum(WBC.wss);
const wbc_sot: u8 = @intFromEnum(WBC.sot);

// ─── Line break class aliases ─────────────────────────────────────────────────
const LBC = shape.LineBreakClass;
fn lbcI(c: LBC) u8 { return @intFromEnum(c); }
fn lbc2(a: LBC, b: LBC) u16 { return (@as(u16, @intFromEnum(a)) << 8) | @intFromEnum(b); }
fn lbc3(a: LBC, b: LBC, c: LBC) u32 { return (@as(u32, @intFromEnum(a)) << 16) | (@as(u32, @intFromEnum(b)) << 8) | @intFromEnum(c); }
fn lbc4(a: LBC, b: LBC, c: LBC, d: LBC) u32 {
  return (@as(u32, @intFromEnum(a)) << 24) | (@as(u32, @intFromEnum(b)) << 16) | (@as(u32, @intFromEnum(c)) << 8) | @intFromEnum(d);
}

const lbc_count: u8 = 62; // ri=61, then COUNT=62, then cm=63

// ─── Unicode lookups ──────────────────────────────────────────────────────────

fn getWordBreakClass(cp: u32) u8 {
  if (cp >= 1114110) return wbc_onep;
  const page_offset: usize = if (cp < 918016) @as(usize, data.UnicodeWordBreakClass_PageIndices[cp / 128]) * 128 else 7296;
  return data.UnicodeWordBreakClass_Data[page_offset | (cp & 127)];
}

fn getLineBreakClass(cp: u32) u8 {
  if (cp >= 1114110) return lbcI(.sot);
  const page_offset: usize = if (cp < 918016) @as(usize, data.UnicodeLineBreakClass_PageIndices[cp / 128]) * 128 else 256;
  return data.UnicodeLineBreakClass_Data[page_offset | (cp & 127)];
}

fn getGraphemeBreakClass(cp: u32) u8 {
  if (cp >= 1114110) return 0;
  const page_offset: usize = if (cp < 921600) @as(usize, data.UnicodeGraphemeBreakClass_PageIndices[cp / 128]) * 128 else 256;
  return data.UnicodeGraphemeBreakClass_Data[page_offset | (cp & 127)];
}

fn getUnicodeFlags(cp: u32) u8 {
  if (cp >= 1114110) return 0;
  const page_offset: usize = if (cp < 1048704) @as(usize, data.UnicodeFlags_PageIndices[cp / 128]) * 128 else 256;
  return data.UnicodeFlags_Data[page_offset | (cp & 127)];
}

fn getBidiClass(cp: u32) u8 {
  if (cp >= 1114110) return bc_ni;
  const page_offset: usize = if (cp < 1048704) @as(usize, data.UnicodeBidirectionalClass_PageIndices[cp / 128]) * 128 else 7296;
  return data.UnicodeBidirectionalClass_Data[page_offset | (cp & 127)];
}

fn getScriptExtension(cp: u32) u16 {
  if (cp >= 1114110) return 0;
  const page_offset: usize = if (cp < 918016) @as(usize, data.UnicodeScriptExtension_PageIndices[cp / 128]) * 128 else 7808;
  return data.UnicodeScriptExtension_Data[page_offset | (cp & 127)];
}

fn getMirrorCodepoint(cp: u32) u32 {
  if (cp >= 1114110) return 0;
  const page_offset: usize = if (cp < 65408) @as(usize, data.UnicodeMirrorCodepoint_PageIndices[cp / 32]) * 32 else 0;
  return data.UnicodeMirrorCodepoint_Data[page_offset | (cp & 31)];
}

fn scriptExtCount(ext: u16) u32 { return @as(u32, ext & 0x1F); }
fn scriptExtOffset(ext: u16) u32 { return @as(u32, ext >> 5); }

fn msbPositionOrZero(x: u32) u32 {
  if (x == 0) return 0;
  return 31 - @clz(x);
}

// ─── Allocator helpers ────────────────────────────────────────────────────────

fn defaultAllocator(data_ptr: ?*anyopaque, op: *shape.AllocatorOp) void {
  _ = data_ptr;
  switch (op.*) {
    .allocate => |*alloc| {
      const ptr = std.c.malloc(alloc.size);
      alloc.pointer = ptr;
    },
    .free => |fr| {
      if (fr.pointer) |p| std.c.free(p);
    },
    else => {},
  }
}

fn arenaAllocator(data_ptr: ?*anyopaque, op: *shape.AllocatorOp) void {
  const arena: *shape.Arena = @ptrCast(@alignCast(data_ptr));
  switch (op.*) {
    .allocate => |*alloc| {
      alloc.pointer = pushSize(arena, alloc.size, @alignOf(*anyopaque));
    },
    .free => {
      // arena free is a no-op
    },
    else => {},
  }
}

fn allocatorAllocate(allocator: ?shape.AllocatorFn, allocator_data: ?*anyopaque, size: usize) ?*anyopaque {
  var op = shape.AllocatorOp{ .allocate = .{ .pointer = null, .size = @intCast(size) } };
  const fn_ptr = allocator orelse &defaultAllocator;
  fn_ptr(allocator_data, &op);
  return op.allocate.pointer;
}

fn allocatorFree(allocator: ?shape.AllocatorFn, allocator_data: ?*anyopaque, ptr: ?*anyopaque) void {
  if (ptr == null) return;
  var op = shape.AllocatorOp{ .free = .{ .pointer = ptr } };
  const fn_ptr = allocator orelse &defaultAllocator;
  fn_ptr(allocator_data, &op);
}

// ─── Arena allocator ─────────────────────────────────────────────────────────

fn arenaBlockAfter(block: *ArenaBlock) [*]u8 {
  return @as([*]u8, @ptrFromInt(@intFromPtr(block) + @sizeOf(ArenaBlock)));
}

fn arenaBlockIsValid(arena: *shape.Arena, block: *ArenaBlock) bool {
  return @intFromPtr(&block.header) != @intFromPtr(&arena.block_sentinel);
}

fn ensureArenaInitialized(arena: *shape.Arena) void {
  if (arena.block_sentinel.next == null) {
    arena.block_sentinel.prev = &arena.block_sentinel;
    arena.block_sentinel.next = &arena.block_sentinel;
    arena.free_block_sentinel.prev = &arena.free_block_sentinel;
    arena.free_block_sentinel.next = &arena.free_block_sentinel;
    if (arena.allocator == null) {
      arena.allocator = &defaultAllocator;
    }
  }
}

fn arenaPushBlock(arena: *shape.Arena, size: usize, alignment: usize) *ArenaBlock {
  var result: *ArenaBlock = @ptrCast(arena.block_sentinel.prev orelse &arena.block_sentinel);

  if (arena.err != 0) return result;

  const block_size = @max(size + @sizeOf(ArenaBlock) + @alignOf(ArenaBlock) + alignment - 1, 4096);

  // Check free list
  const free_prev = arena.free_block_sentinel.prev orelse &arena.free_block_sentinel;
  const free_block: *ArenaBlock = @ptrCast(@alignCast(free_prev));
  if (@intFromPtr(free_prev) == @intFromPtr(&arena.free_block_sentinel) or
      (free_block.size + @sizeOf(ArenaBlock)) < block_size)
  {
    // Allocate new block
    const base = allocatorAllocate(arena.allocator, arena.allocator_data, block_size);
    if (base) |b| {
      const result_addr = std.mem.alignForward(usize, @intFromPtr(b), @alignOf(ArenaBlock));
      result = @ptrFromInt(result_addr);
      result.header.prev = null;
      result.header.next = null;
      result.base_allocation = b;
      result.size = (@intFromPtr(b) + block_size) - (result_addr + @sizeOf(ArenaBlock));
      result.used = 0;
    } else {
      result = @ptrCast(@alignCast(&arena.block_sentinel));
      arena.err = 1;
    }
  } else {
    // Reuse from free list
    result = free_block;
    dllistRemove(&result.header);
  }

  dllistInsertBefore(&result.header, &arena.block_sentinel);
  result.used = 0;
  return result;
}

fn pushSize(arena: *shape.Arena, size: usize, alignment: usize) ?*anyopaque {
  ensureArenaInitialized(arena);
  if (arena.err != 0) return null;

  const sentinel_prev = arena.block_sentinel.prev orelse &arena.block_sentinel;
  var block: *ArenaBlock = @ptrCast(@alignCast(sentinel_prev));
  const block_mem = arenaBlockAfter(block);

  if (arenaBlockIsValid(arena, block)) {
    const top = @intFromPtr(block_mem) + block.used;
    const top_aligned = std.mem.alignForward(usize, top, alignment);
    if (top_aligned + size - @intFromPtr(block_mem) <= block.size) {
      block.used = top_aligned + size - @intFromPtr(block_mem);
      return @ptrFromInt(top_aligned);
    }
  }

  // Need a new block
  block = arenaPushBlock(arena, size, alignment);
  if (!arenaBlockIsValid(arena, block)) return null;

  const new_mem = arenaBlockAfter(block);
  const top = @intFromPtr(new_mem) + block.used;
  const top_aligned = std.mem.alignForward(usize, top, alignment);
  block.used = top_aligned + size - @intFromPtr(new_mem);
  return @ptrFromInt(top_aligned);
}

fn pushType(arena: *shape.Arena, comptime T: type) ?*T {
  const ptr = pushSize(arena, @sizeOf(T), @alignOf(T)) orelse return null;
  const result: *T = @ptrCast(@alignCast(ptr));
  result.* = std.mem.zeroes(T);
  return result;
}

fn pushArray(arena: *shape.Arena, comptime T: type, count: usize) ?[*]T {
  const ptr = pushSize(arena, @sizeOf(T) * count, @alignOf(T)) orelse return null;
  const result: [*]T = @ptrCast(@alignCast(ptr));
  @memset(result[0..count], std.mem.zeroes(T));
  return result;
}

fn clearArena(arena: *shape.Arena) void {
  ensureArenaInitialized(arena);
  const first = arena.block_sentinel.next orelse &arena.block_sentinel;
  const last = arena.block_sentinel.prev orelse &arena.block_sentinel;
  const first_block: *ArenaBlock = @ptrCast(@alignCast(first));
  if (arenaBlockIsValid(arena, first_block)) {
    const free_last = arena.free_block_sentinel.prev orelse &arena.free_block_sentinel;
    first.prev = free_last;
    last.next = &arena.free_block_sentinel;
    first.prev.?.next = first;
    last.next.?.prev = last;
    arena.block_sentinel.prev = &arena.block_sentinel;
    arena.block_sentinel.next = &arena.block_sentinel;
  }
}

fn freeArena(arena: *shape.Arena) void {
  ensureArenaInitialized(arena);
  inline for (.{ &arena.block_sentinel, &arena.free_block_sentinel }) |sentinel| {
    var header = sentinel.next;
    while (header != null and @intFromPtr(header.?) != @intFromPtr(sentinel)) {
      const next = header.?.next;
      const block: *ArenaBlock = @ptrCast(@alignCast(header));
      allocatorFree(arena.allocator, arena.allocator_data, block.base_allocation);
      header = next;
    }
  }
}

fn beginLifetime(arena: *shape.Arena) ArenaLifetime {
    const sentinel_prev = arena.block_sentinel.prev orelse &arena.block_sentinel;
    const block: *ArenaBlock = @ptrCast(@alignCast(sentinel_prev));
    const used: usize = if (arenaBlockIsValid(arena, block)) block.used else 0;
    const hdr: *shape.ArenaBlockHeader = if (arenaBlockIsValid(arena, block))
        &block.header
    else
        @ptrCast(@alignCast(&arena.block_sentinel));
    return .{ .arena = arena, .block_header = hdr, .used = used };
}

fn endLifetime(lifetime: *ArenaLifetime) void {
    const arena = lifetime.arena orelse return;
    if (arena.err != 0) return;
    if (lifetime.block_header) |hdr| {
        const block: *ArenaBlock = @ptrCast(@alignCast(hdr));
        if (arenaBlockIsValid(arena, block)) {
            block.used = lifetime.used;
        }
    }
}

// ─── Doubly-linked list helpers ───────────────────────────────────────────────

fn dllistRemove(h: anytype) void {
  const prev = h.prev orelse return;
  const next = h.next orelse return;
  prev.next = h.next;
  next.prev = h.prev;
}

fn dllistInsertBefore(h: anytype, before: anytype) void {
  h.next = before;
  h.prev = before.prev;
  if (h.prev) |p| p.next = h;
  before.prev = h;
}

// ─── Glyph storage ────────────────────────────────────────────────────────────

fn ensureGlyphStorageInitialized(storage: *shape.GlyphStorage) void {
  if (storage.glyph_sentinel.next == null) {
    storage.glyph_sentinel.prev = &storage.glyph_sentinel;
    storage.glyph_sentinel.next = &storage.glyph_sentinel;
    storage.free_glyph_sentinel.prev = &storage.free_glyph_sentinel;
    storage.free_glyph_sentinel.next = &storage.free_glyph_sentinel;
  }
}

fn glyphIsValid(storage: *shape.GlyphStorage, glyph: *shape.Glyph) bool {
  return glyph != &storage.glyph_sentinel;
}

fn insertGlyph(storage: *shape.GlyphStorage, anchor: *shape.Glyph, before: bool, base: ?*shape.Glyph) ?*shape.Glyph {
    var result: ?*shape.Glyph = storage.free_glyph_sentinel.next;

    if (result != null and result.? != &storage.free_glyph_sentinel) {
        // Reuse from free list
        result.?.prev.?.next = result.?.next;
        result.?.next.?.prev = result.?.prev;
    } else {
        // Allocate new
        result = pushType(&storage.arena, shape.Glyph);
    }

    const g = result orelse {
        storage.err = 1;
        return null;
    };

    if (base) |b| {
        g.* = b.*;
        g.bucketed = null;
    }

    if (before) {
        g.next = anchor;
        g.prev = anchor.prev;
    } else {
        g.prev = anchor;
        g.next = anchor.next;
    }

    if (g.prev) |p| p.next = g;
    if (g.next) |n| n.prev = g;

    return g;
}

pub fn clearActiveGlyphs(storage: *shape.GlyphStorage) void {
    if (storage.err != 0) return;
    ensureGlyphStorageInitialized(storage);

    const first = storage.glyph_sentinel.next orelse &storage.glyph_sentinel;
    const last = storage.glyph_sentinel.prev orelse &storage.glyph_sentinel;

    if (glyphIsValid(storage, first)) {
        const free_last = storage.free_glyph_sentinel.prev orelse &storage.free_glyph_sentinel;
        first.prev = free_last;
        last.next = &storage.free_glyph_sentinel;
        first.prev.?.next = first;
        last.next.?.prev = last;
    }

    storage.glyph_sentinel.prev = &storage.glyph_sentinel;
    storage.glyph_sentinel.next = &storage.glyph_sentinel;
}

pub fn activeGlyphIterator(storage: *shape.GlyphStorage) shape.GlyphIterator {
    var result: shape.GlyphIterator = std.mem.zeroes(shape.GlyphIterator);
    if (storage.err != 0) return result;
    ensureGlyphStorageInitialized(storage);
    result.glyph_storage = storage;
    result.current_glyph = storage.glyph_sentinel.next;
    return result;
}

pub fn pushGlyph(storage: *shape.GlyphStorage, font: ?*shape.Font, codepoint: i32, config: ?*shape.GlyphConfig, user_id: i32) ?*shape.Glyph {
    if (storage.err != 0) return null;
    ensureGlyphStorageInitialized(storage);

    var template = std.mem.zeroes(shape.Glyph);
    template.codepoint = @intCast(codepoint);
    template.config = config;
    template.user_id_or_codepoint_index = user_id;

    if (font) |f| {
        if (f.user_data) |ud| {
            const tf: *TatfiFont = @ptrCast(@alignCast(ud));
            if (codepoint > 0) {
                if (tf.face.glyph_index(@intCast(codepoint))) |gid| {
                    template.id = gid[0];
                    template.advance_x = tf.face.glyph_hor_advance(std.heap.c_allocator, gid) orelse 0;
                }
            }
        }
    }

    return insertGlyph(storage, &storage.glyph_sentinel, true, &template);
}

pub fn glyphIteratorNext(it: *shape.GlyphIterator, glyph: *?*shape.Glyph) i32 {
    const current = it.current_glyph orelse return 0;
    const storage = it.glyph_storage orelse return 0;

    if (!glyphIsValid(storage, current)) return 0;

    glyph.* = current;
    it.current_glyph = current.next;
    return 1;
}

// ─── Break state helpers ──────────────────────────────────────────────────────

fn doBreak(state: *shape.BreakState, position: i32, flags: u8, direction: shape.Direction, paragraph_direction: shape.Direction, script: shape.Script) void {
    if (flags == 0) return;
    // C uses unsigned wrapping: BreakPosition = CurrentPosition + (u32)Position
    // Only valid if BreakPosition <= CurrentPosition (unsigned comparison)
    const break_pos_u32 = state.current_position +% @as(u32, @bitCast(position));
    if (break_pos_u32 > state.current_position) return;

    var brk = std.mem.zeroes(shape.Break);
    brk.position = @bitCast(break_pos_u32);
    brk.flags = flags;
    brk.direction = direction;
    brk.paragraph_direction = paragraph_direction;
    brk.script = script;

    // Resolve bracket scripts/directions
    if ((flags & SCRIPT != 0) and state.last_script_break_script != 0) {
        const last_pos = state.last_script_break_position;
        const last_script = state.last_script_break_script;
        var bi: usize = state.bracket_count;
        while (bi > 0) {
            bi -= 1;
            const bracket = &state.brackets[bi];
            if (bracket.position >= break_pos_u32) {
                bracket.script = @intCast(@intFromEnum(script));
            } else if (bracket.position >= last_pos) {
                bracket.script = last_script;
            } else break;
        }
        state.last_script_break_position = break_pos_u32;
        state.last_script_break_script = @intCast(@intFromEnum(script));
    }

    if ((flags & DIRECTION != 0) and state.last_direction_break_direction != 0) {
        const last_pos = state.last_direction_break_position;
        const last_dir = state.last_direction_break_direction;
        var bi: usize = state.bracket_count;
        while (bi > 0) {
            bi -= 1;
            const bracket = &state.brackets[bi];
            if (bracket.position >= break_pos_u32) {
                bracket.direction = @intCast(@intFromEnum(direction));
            } else if (bracket.position >= last_pos) {
                bracket.direction = last_dir;
            } else break;
        }
        state.last_direction_break_position = break_pos_u32;
        state.last_direction_break_direction = @intCast(@intFromEnum(direction));
    }

    // Insert break sorted in reverse order (pop from end = lowest position)
    var matched = false;
    var i: usize = 0;
    while (i < state.break_count) {
        const existing = &state.breaks[i];
        if (existing.position == brk.position) {
            existing.flags |= brk.flags;
            if (flags & DIRECTION != 0) existing.direction = brk.direction;
            if (flags & PARAGRAPH_DIRECTION != 0) existing.paragraph_direction = brk.paragraph_direction;
            if (flags & SCRIPT != 0) existing.script = brk.script;
            matched = true;
            break;
        } else if (existing.position < brk.position) {
            const swap = existing.*;
            existing.* = brk;
            brk = swap;
        } else if ((flags & PARAGRAPH_DIRECTION != 0) and
            (existing.flags & DIRECTION != 0) and
            @intFromEnum(existing.direction) == 0)
        {
            existing.direction = brk.paragraph_direction;
        }
        i += 1;
    }

    if (!matched) {
        state.breaks[@min(state.break_count, 7)] = brk;
        if (state.break_count < 8) state.break_count += 1;
    }
}

fn doLineBreak(state: *shape.BreakState, position: i32, effective_line_breaks: u64) void {
    if (effective_line_breaks & lb_mask == 0) return;
    var flags: u8 = 0;
    if (effective_line_breaks & lb_allowed_mask != 0) flags |= @intCast(LINE_SOFT);
    if (effective_line_breaks & lb_required_mask != 0) flags |= @intCast(LINE_HARD);
    doBreak(state, position, flags, .dont_know, .dont_know, .dont_know);
}

fn breakStateStartParagraph(state: *shape.BreakState) void {
    const para_dir = state.user_paragraph_direction;
    var sot_bidi: u8 = bc_ni;
    var flags: u32 = 0;
    switch (para_dir) {
        .ltr => { sot_bidi = bc_l; },
        .rtl => { flags = bsf_saw_r_after_l; sot_bidi = bc_r; },
        else => {},
    }
    state.paragraph_direction = para_dir;
    state.bidirectional_class1 = sot_bidi;
    state.flags = flags;
}

fn flushDirection(state: *shape.BreakState, last_dir: *u8, bidi_class: u8, position_offset: i16) void {
    var break_flags: u8 = 0;
    var direction = shape.Direction.dont_know;

    switch (bidi_class) {
        bc_l => { break_flags = @intCast(DIRECTION | PARAGRAPH_DIRECTION); direction = .ltr; },
        bc_r => { break_flags = @intCast(DIRECTION | PARAGRAPH_DIRECTION); direction = .rtl; },
        bc_an, bc_en => { break_flags = @intCast(DIRECTION); direction = .ltr; },
        bc_ni => { break_flags = @intCast(DIRECTION); },
        else => {},
    }

    if ((break_flags & DIRECTION != 0) and @intFromEnum(direction) != last_dir.*) {
        last_dir.* = @intCast(@intFromEnum(direction));
        doBreak(state, position_offset, @intCast(DIRECTION), direction, .dont_know, .dont_know);
    }

    if ((break_flags & PARAGRAPH_DIRECTION != 0) and state.paragraph_direction == .dont_know) {
        const para_start_offset: i32 = @as(i16, @bitCast(@as(u16, @truncate(state.paragraph_start_position -% state.current_position))));
        doBreak(state, @intCast(para_start_offset), @intCast(PARAGRAPH_DIRECTION), .dont_know, direction, .dont_know);
        state.paragraph_direction = direction;
    }
}

// ─── BreakAddCodepoint – main codepoint analysis ─────────────────────────────

pub fn breakAddCodepoint(state: *shape.BreakState, codepoint: u32, position_increment: u32, maybe_end_of_text: bool) void {
    const BREAK_BITS = struct {
        fn apply(flag_state: *u32, flags: u32, pos: u3) void {
            flag_state.* |= flags << (8 * @as(u5, pos));
        }
        fn apply2(flag_state: *u32, flags: u32, pos0: u3, pos1: u3) void {
            flag_state.* |= (flags << (8 * @as(u5, pos0))) | (flags << (8 * @as(u5, pos1)));
        }
    };

    var bidi_class = getBidiClass(codepoint);
    const unicode_flags = getUnicodeFlags(codepoint);
    const matching_bracket = getMirrorCodepoint(codepoint);
    const grapheme_break_class = getGraphemeBreakClass(codepoint);
    const line_break_class_raw = getLineBreakClass(codepoint);
    const word_break_class = getWordBreakClass(codepoint);
    const script_ext = getScriptExtension(codepoint);
    var cp_script_count = scriptExtCount(script_ext);
    var cp_script_offset = scriptExtOffset(script_ext);
    var cp_scripts_ptr: [*]const u8 = script_extensions[cp_script_offset..].ptr;

    var flag_state = @as(u32, state.flag_state) << 8;
    const last_line_break_class = state.last_line_break_class;
    const end_of_text = (codepoint == 3) and maybe_end_of_text;
    const start_of_text = (state.flags & bsf_started) == 0;
    var line_break_history = state.line_break_history;
    var word_break_history = state.word_break_history;
    var last_word_break_class = state.last_word_break_class;
    var word_break2_position_offset = state.word_break2_position_offset;
    const last_wbc_including_ignored = state.last_word_break_class_including_ignored;
    const position_offset2 = state.position_offset2;
    const position_offset3 = state.position_offset3;
    var flags = state.flags;
    var last_direction = state.last_direction;
    const script_set: [*]u8 = &state.script_set;
    var script_position_offset = state.script_position_offset;
    var script_count = state.script_count;
    const script_count_at_begin = script_count;
    const break_script: u8 = if (script_count > 0) script_set[0] else 0;
    var flush_flags: u32 = 0;
    const bidi2_pos_offset = state.bidirectional2_position_offset;
    const bidi1_pos_offset = state.bidirectional1_position_offset;
    const bidi2 = state.bidirectional_class2;
    var bidi1 = state.bidirectional_class1;
    const pi = position_increment;

    if (start_of_text) {
        line_break_history = lbcI(.sot);
        last_word_break_class = wbc_sot;
    }

    // ── Bracket pairing ────────────────────────────────────────────────────────
    const uf_open = shape.UnicodeFlags.open_bracket;
    const uf_close = shape.UnicodeFlags.close_bracket;
    const uf_mirrored = shape.UnicodeFlags.mirrored;

    if ((unicode_flags & uf_mirrored) == uf_open) {
        if (state.bracket_count < 64) {
            const bracket = &state.brackets[state.bracket_count];
            state.bracket_count += 1;
            bracket.codepoint = codepoint;
            bracket.position = state.current_position;
            bracket.direction = @intFromEnum(shape.Direction.dont_know);
            bracket.script = @intFromEnum(shape.Script.dont_know);
            if (script_count > 0) bracket.script = script_set[0];
            state.flags |= bsf_last_was_bracket;
        }
    } else if ((unicode_flags & uf_mirrored) == uf_close) {
        if (state.bracket_count > 0) {
            var found_idx: usize = 0;
            var found: ?*shape.Bracket = null;
            var bi: usize = 0;
            while (bi < state.bracket_count) : (bi += 1) {
                const br = &state.brackets[state.bracket_count - 1 - bi];
                if (br.codepoint == matching_bracket) {
                    found = br;
                    found_idx = state.bracket_count - 1 - bi;
                    break;
                }
            }
            if (found) |fb| {
                var bracket_script = fb.script;
                var bracket_direction = fb.direction;
                if (bracket_script == 0 and script_count > 0) bracket_script = script_set[0];
                if (bracket_direction == 0) bracket_direction = last_direction;
                if (bracket_direction == @intFromEnum(shape.Direction.ltr)) {
                    bidi_class = bc_l;
                } else if (bracket_direction == @intFromEnum(shape.Direction.rtl)) {
                    bidi_class = bc_r;
                }
                bidi_class = fb.direction;
                cp_script_count = 1;
                cp_script_offset = bracket_script;
                cp_scripts_ptr = script_extensions[cp_script_offset .. cp_script_offset + 1].ptr;
                state.bracket_count = @intCast(found_idx);
            }
        }
    }

    // ── Script breaking ────────────────────────────────────────────────────────
    if (end_of_text) flush_flags |= ff_script;

    const script_dont_know: u8 = @intFromEnum(shape.Script.dont_know);
    const script_default: u8 = @intFromEnum(shape.Script.default);
    const script_default2: u8 = @intFromEnum(shape.Script.default2);

    if (cp_script_count < 2) {
        const cp_script = @as(u8, @intCast(cp_script_offset));
        if (cp_script != script_dont_know and cp_script != script_default and cp_script != script_default2) {
            var match = false;
            var si: usize = 0;
            while (si < script_count) : (si += 1) {
                if (script_set[si] == cp_script) { match = true; break; }
            }
            if (!match) flush_flags |= ff_script;
            script_count = 1;
            script_set[0] = cp_script;
        }
    } else {
        var new_count: usize = 0;
        var csi: usize = 0;
        var ssi: usize = 0;
        while (ssi < script_count and csi < cp_script_count) {
            const cps = cp_scripts_ptr[csi];
            const ss = script_set[ssi];
            if (cps < ss) {
                csi += 1;
            } else if (ss < cps) {
                ssi += 1;
            } else {
                script_set[new_count] = ss;
                new_count += 1;
                csi += 1;
                ssi += 1;
            }
        }
        if (new_count == 0) {
            flush_flags |= ff_script;
            var ci: usize = 0;
            while (ci < cp_script_count) : (ci += 1) {
                script_set[ci] = cp_scripts_ptr[ci];
            }
            script_count = @intCast(cp_script_count);
        } else {
            script_count = @intCast(new_count);
        }
    }

    // ── Direction breaking ─────────────────────────────────────────────────────
    if (end_of_text) bidi_class = bc_ni;

    var skip_dir_break = false;

    if (bidi_class != bc_bn) {
        switch (bidi_class) {
            bc_nsm => { bidi_class = bidi1; },
            bc_l => { flags &= ~(bsf_saw_r_after_l | bsf_saw_al_after_lr); },
            bc_r => { flags |= bsf_saw_r_after_l; flags &= ~bsf_saw_al_after_lr; },
            bc_al => {
                flags |= (bsf_saw_al_after_lr | bsf_saw_r_after_l);
                bidi_class = bc_r;
            },
            bc_en => blk: {
                if (flags & bsf_saw_al_after_lr != 0) {
                    bidi_class = bc_an;
                    // fall through to AN handling
                    if (bidi2 == bc_an and bidi1 == bc_cs) bidi1 = bc_an;
                    break :blk;
                }
                if (bidi2 == bc_en and (bidi1 == bc_es or bidi1 == bc_cs)) {
                    bidi1 = bc_en;
                }
                if (state.paragraph_direction != .dont_know and (flags & bsf_saw_r_after_l) == 0) {
                    bidi_class = bc_l;
                }
            },
            bc_an => {
                if (bidi2 == bc_an and bidi1 == bc_cs) bidi1 = bc_an;
            },
            bc_et => {
                if (bidi1 == bc_en) bidi_class = bc_en;
            },
            else => {},
        }

        // Neutralize ET/ES/CS in slot 1
        const in_set_etc = inSet(bidi1, .{ bc_et, bc_es, bc_cs });
        if (in_set_etc) bidi1 = bc_ni;

        if (bidi1 == bc_ni) {
            if (inSet(bidi_class, .{ bc_ni, bc_et, bc_es, bc_cs })) {
                // Merge with preceding NI chain
                skip_dir_break = true;
            } else if ((bidi2 == bc_r or bidi_class == bc_r) and
                inSet(bidi2, .{ bc_r, bc_an, bc_en }) and
                inSet(bidi_class, .{ bc_r, bc_an, bc_en }))
            {
                bidi1 = bc_r;
            } else if (bidi2 == bc_l and bidi_class == bc_l) {
                bidi1 = bc_l;
            } else {
                const para = state.paragraph_direction;
                if (para == .ltr) bidi1 = bc_l
                else if (para == .rtl) bidi1 = bc_r;
            }
        }

        if (!skip_dir_break) {
            flush_flags |= ff_direction_2;
            if (end_of_text) flush_flags |= ff_direction_1;
        }
    }

    if (skip_dir_break) {
        state.bidirectional2_position_offset -= @as(i16, @intCast(pi));
        state.bidirectional1_position_offset -= @as(i16, @intCast(pi));
    }

    // ── Grapheme breaking ──────────────────────────────────────────────────────
    if (end_of_text and !start_of_text) {
        BREAK_BITS.apply(&flag_state, GRAPHEME, 1);
        state.grapheme_break_state = 0; // START
    } else {
        var gbs = grapheme_break_transition[grapheme_break_class][state.grapheme_break_state];
        switch (gbs) {
            15 => { BREAK_BITS.apply2(&flag_state, GRAPHEME, 1, 0); gbs = 0; }, // b01
            14 => { BREAK_BITS.apply(&flag_state, GRAPHEME, 0); gbs = 0; },     // b0
            16...28 => { // b1 series
                BREAK_BITS.apply(&flag_state, GRAPHEME, 1);
                gbs -= 16; // map back to regular state
            },
            else => {},
        }
        state.grapheme_break_state = gbs;
    }

    // ── Word breaking ──────────────────────────────────────────────────────────
    const in_ex_fo_zwj = inSet(word_break_class, .{ wbc_ex, wbc_fo, wbc_zwj });
    const last_in_special = inSet(last_word_break_class, .{ wbc_sot, wbc_cr, wbc_lf, wbc_nl });

    if (in_ex_fo_zwj and !last_in_special) {
        word_break2_position_offset -= @as(i16, @intCast(pi));
        state.word_break2_position_offset = word_break2_position_offset;
    } else {
        var word_breaks = (@as(u32, state.word_breaks) << 4);
        var word_unbreaks = (@as(u32, state.word_unbreaks) << 4);
        word_break_history = (word_break_history << 8) | word_break_class;

        // WB3a, WB3b
        const wb_bits = struct {
            fn b(comptime priority: u3, comptime pos: u2) u32 {
                return (((@as(u32, 1) << (priority + 1)) - 1)) << (@as(u5, pos) * 4);
            }
        };
        word_breaks |= wb_bits.b(0, 1) | wb_bits.b(0, 0);
        if (start_of_text) word_breaks |= wb_bits.b(2, 1);

        if (inSet(word_break_class, .{ wbc_cr, wbc_lf, wbc_nl })) {
            word_breaks |= wb_bits.b(1, 1) | wb_bits.b(1, 0);
        } else if (inSet(word_break_class, .{ wbc_oep, wbc_alep })) {
            if (last_wbc_including_ignored == wbc_zwj) {
                word_unbreaks |= wb_bits.b(0, 1);
            }
        }

        // 2-character word break rules
        switch (word_break_history & 0xFFFF) {
            wbc2(.cr, .lf) => { word_unbreaks |= wb_bits.b(1, 1); },
            wbc2(.wss, .wss) => { if (word_break2_position_offset >= 0) word_unbreaks |= wb_bits.b(0, 1); },
            wbc2(.ri, .ri) => { word_break_history = 0; word_unbreaks |= wb_bits.b(0, 1); },
            wbc2(.hl, .sq),
            wbc2(.alnep, .alnep), wbc2(.alnep, .alep), wbc2(.alnep, .hl), wbc2(.alnep, .nm), wbc2(.alnep, .enl),
            wbc2(.alep, .alnep), wbc2(.alep, .alep), wbc2(.alep, .hl), wbc2(.alep, .nm), wbc2(.alep, .enl),
            wbc2(.hl, .alnep), wbc2(.hl, .alep), wbc2(.hl, .hl), wbc2(.hl, .nm), wbc2(.hl, .enl),
            wbc2(.nm, .alnep), wbc2(.nm, .alep), wbc2(.nm, .hl), wbc2(.nm, .nm), wbc2(.nm, .enl),
            wbc2(.ka, .ka), wbc2(.ka, .enl),
            wbc2(.enl, .alnep), wbc2(.enl, .alep), wbc2(.enl, .hl), wbc2(.enl, .nm), wbc2(.enl, .ka), wbc2(.enl, .enl),
            => { word_unbreaks |= wb_bits.b(0, 1); },
            else => {},
        }

        // 3-character word break rules
        switch (word_break_history & 0xFFFFFF) {
            wbc3(.alnep, .ml, .alnep), wbc3(.alnep, .ml, .alep), wbc3(.alnep, .ml, .hl),
            wbc3(.alnep, .mnl, .alnep), wbc3(.alnep, .mnl, .alep), wbc3(.alnep, .mnl, .hl),
            wbc3(.alnep, .sq, .alnep), wbc3(.alnep, .sq, .alep), wbc3(.alnep, .sq, .hl),
            wbc3(.alep, .ml, .alnep), wbc3(.alep, .ml, .alep), wbc3(.alep, .ml, .hl),
            wbc3(.alep, .mnl, .alnep), wbc3(.alep, .mnl, .alep), wbc3(.alep, .mnl, .hl),
            wbc3(.alep, .sq, .alnep), wbc3(.alep, .sq, .alep), wbc3(.alep, .sq, .hl),
            wbc3(.hl, .ml, .alnep), wbc3(.hl, .ml, .alep), wbc3(.hl, .ml, .hl),
            wbc3(.hl, .mnl, .alnep), wbc3(.hl, .mnl, .alep), wbc3(.hl, .mnl, .hl),
            wbc3(.hl, .sq, .alnep), wbc3(.hl, .sq, .alep), wbc3(.hl, .sq, .hl),
            wbc3(.hl, .dq, .hl),
            wbc3(.nm, .mn, .nm), wbc3(.nm, .mnl, .nm), wbc3(.nm, .sq, .nm),
            => { word_unbreaks |= wb_bits.b(0, 1) | wb_bits.b(0, 2); },
            else => {},
        }

        const eff_word_breaks = word_breaks & ~word_unbreaks;
        if (eff_word_breaks & wb_bits.b(2, 2) != 0) {
            doBreak(state, position_offset2 + word_break2_position_offset, @intCast(WORD), .dont_know, .dont_know, .dont_know);
        }
        if (end_of_text) {
            BREAK_BITS.apply(&flag_state, WORD, 1);
        }

        state.word_breaks = @intCast(word_breaks & 0xFFFF);
        state.word_unbreaks = @intCast(word_unbreaks & 0xFFFF);
        last_word_break_class = word_break_class;
        state.word_break2_position_offset = 0;
        state.word_break_history = word_break_history;
    }
    state.last_word_break_class_including_ignored = word_break_class;
    state.last_word_break_class = last_word_break_class;

    // ── Line breaking ──────────────────────────────────────────────────────────
    const lb3_off = state.line_break3_position_offset;
    const lb2_off = state.line_break2_position_offset;
    var hard_line_break = false;

    var line_breaks: u64 = @as(u64, state.line_breaks) << 16;
    var line_unbreaks: u64 = @as(u64, state.line_unbreaks) << 16;
    var line_unbreaks_async: u64 = @as(u64, state.line_unbreaks_async) << 16;

    var lbc = line_break_class_raw;
    var line_break_absorb = false;

    if (end_of_text) {
        lbc = lbcI(.onea);
    } else if (lbc > lbc_count) {
        if (lbc == lbcI(.cm) or lbc == lbcI(.zwj)) {
            if (lbc == lbcI(.zwj)) {
                line_unbreaks_async |= lb_required3 << (0 * 16);
            }
            switch (last_line_break_class) {
                lbcI(.sot), lbcI(.bk), lbcI(.cr), lbcI(.lf), lbcI(.nl), lbcI(.sp), lbcI(.zw) => {
                    lbc = lbcI(.alnea);
                },
                else => { line_break_absorb = true; },
            }
        } else if (lbc == lbcI(.cj)) {
            lbc = if (state.japanese_line_break_style == .strict)
                lbcI(.nsea) else lbcI(.idea);
        }
    }

    if (!line_break_absorb and last_line_break_class == lbc and lbc == lbcI(.sp)) {
        line_break_absorb = true;
    }

    if (!line_break_absorb) {
        line_break_history = (line_break_history << 8) | lbc;

        if (end_of_text and (state.config_flags & shape.BreakConfigFlags.end_of_text_generates_hard_line_break != 0)) {
            line_breaks |= lb_required5 << (1 * 16);
            if ((line_break_history & 0xFF00) == (@as(u32, lbcI(.qupf)) << 8)) {
                line_unbreaks |= lb_required3 << (2 * 16);
            }
        }

        line_breaks |= lb_allowed0 << (0 * 16);
        line_breaks |= lb_allowed0 << (1 * 16);

        // 1-char rules
        switch (lbc) {
            lbcI(.bk), lbcI(.cr), lbcI(.lf), lbcI(.nl) => {
                line_unbreaks |= lb_required4 << (1 * 16);
                flush_flags |= ff_script | ff_direction_2 | ff_direction_1 | ff_direction_paragraph;
                script_count = 0;
                hard_line_break = true;
                line_breaks |= lb_required5 << (0 * 16);
            },
            lbcI(.zw) => { line_breaks |= lb_allowed4 << (0 * 16); line_unbreaks |= lb_required4 << (1 * 16); },
            lbcI(.bb) => { line_unbreaks |= lb_allowed0 << (0 * 16); },
            lbcI(.glea), lbcI(.glnea), lbcI(.opea), lbcI(.opnea) => { line_unbreaks |= lb_required3 << (0 * 16); },
            lbcI(.wj) => { line_unbreaks |= lb_required3 << (0 * 16); line_unbreaks |= lb_required3 << (1 * 16); },
            lbcI(.clea), lbcI(.clnea), lbcI(.cpea), lbcI(.cpnea),
            lbcI(.exea), lbcI(.exnea), lbcI(.sy) => { line_unbreaks |= lb_required3 << (1 * 16); },
            lbcI(.is) => { line_unbreaks |= lb_required2 << (1 * 16); },
            lbcI(.sp) => { line_unbreaks |= lb_required4 << (1 * 16); line_breaks |= lb_allowed2 << (0 * 16); },
            lbcI(.qu) => { line_unbreaks |= lb_required1 << (1 * 16); line_unbreaks |= lb_required1 << (0 * 16); },
            lbcI(.qupi) => { line_unbreaks |= lb_required1 << (0 * 16); },
            lbcI(.qupf) => { line_unbreaks |= lb_required1 << (1 * 16); },
            lbcI(.cb) => { line_breaks |= lb_allowed1 << (0 * 16); line_breaks |= lb_allowed1 << (1 * 16); },
            lbcI(.banea), lbcI(.baea), lbcI(.hyphen), lbcI(.hy),
            lbcI(.nsnea), lbcI(.nsea), lbcI(.innea), lbcI(.inea) => { line_unbreaks |= lb_allowed0 << (1 * 16); },
            else => {},
        }

        // 2-char rules (abbreviated - key ones)
        const lbh2 = line_break_history & 0xFFFF;
        switch (lbh2) {
            lbc2(.cr, .lf) => { line_unbreaks |= lb_required5 << (1 * 16); },
            lbc2(.zw, .sp) => { line_breaks |= lb_allowed4 << (0 * 16); },
            lbc2(.hl, .nu), lbc2(.alnea, .nu), lbc2(.alea, .nu), lbc2(.dotted_circle, .nu),
            lbc2(.nu, .alnea), lbc2(.nu, .alea), lbc2(.nu, .dotted_circle), lbc2(.nu, .hl),
            lbc2(.prnea, .idnea), lbc2(.prnea, .idea), lbc2(.prnea, .idpe), lbc2(.prnea, .ebnea), lbc2(.prnea, .ebea), lbc2(.prnea, .em),
            lbc2(.prea, .idnea), lbc2(.prea, .idea), lbc2(.prea, .idpe), lbc2(.prea, .ebnea), lbc2(.prea, .ebea), lbc2(.prea, .em),
            lbc2(.idnea, .poea), lbc2(.idnea, .ponea), lbc2(.idea, .poea), lbc2(.idea, .ponea), lbc2(.idpe, .poea), lbc2(.idpe, .ponea),
            lbc2(.ebnea, .poea), lbc2(.ebnea, .ponea), lbc2(.ebea, .poea), lbc2(.ebea, .ponea), lbc2(.em, .poea), lbc2(.em, .ponea),
            lbc2(.prea, .alea), lbc2(.prea, .alnea), lbc2(.prea, .dotted_circle), lbc2(.prea, .hl),
            lbc2(.prnea, .alea), lbc2(.prnea, .alnea), lbc2(.prnea, .dotted_circle), lbc2(.prnea, .hl),
            lbc2(.poea, .alea), lbc2(.poea, .alnea), lbc2(.poea, .dotted_circle), lbc2(.poea, .hl),
            lbc2(.ponea, .alea), lbc2(.ponea, .alnea), lbc2(.ponea, .dotted_circle), lbc2(.ponea, .hl),
            lbc2(.alea, .prea), lbc2(.alea, .prnea), lbc2(.alea, .poea), lbc2(.alea, .ponea),
            lbc2(.alnea, .prea), lbc2(.alnea, .prnea), lbc2(.alnea, .poea), lbc2(.alnea, .ponea),
            lbc2(.dotted_circle, .prea), lbc2(.dotted_circle, .prnea), lbc2(.dotted_circle, .poea), lbc2(.dotted_circle, .ponea),
            lbc2(.hl, .prea), lbc2(.hl, .prnea), lbc2(.hl, .poea), lbc2(.hl, .ponea),
            lbc2(.nu, .poea), lbc2(.nu, .ponea), lbc2(.nu, .prea), lbc2(.nu, .prnea), lbc2(.nu, .nu),
            lbc2(.poea, .nu), lbc2(.ponea, .nu), lbc2(.prea, .nu), lbc2(.prnea, .nu),
            lbc2(.sy, .hl),
            lbc2(.jl, .jl), lbc2(.jl, .jv), lbc2(.jl, .h2), lbc2(.jl, .h3),
            lbc2(.jv, .jv), lbc2(.jv, .jt), lbc2(.h2, .jv), lbc2(.h2, .jt),
            lbc2(.jt, .jt), lbc2(.h3, .jt),
            lbc2(.alea, .alea), lbc2(.alea, .alnea), lbc2(.alea, .dotted_circle), lbc2(.alea, .hl),
            lbc2(.alnea, .alea), lbc2(.alnea, .alnea), lbc2(.alnea, .dotted_circle), lbc2(.alnea, .hl),
            lbc2(.dotted_circle, .alea), lbc2(.dotted_circle, .alnea), lbc2(.dotted_circle, .dotted_circle), lbc2(.dotted_circle, .hl),
            lbc2(.hl, .alea), lbc2(.hl, .alnea), lbc2(.hl, .dotted_circle), lbc2(.hl, .hl),
            lbc2(.ap, .ak), lbc2(.ap, .dotted_circle), lbc2(.ap, .as),
            lbc2(.ak, .vf), lbc2(.ak, .vi), lbc2(.dotted_circle, .vf), lbc2(.dotted_circle, .vi), lbc2(.as, .vf), lbc2(.as, .vi),
            lbc2(.is, .alea), lbc2(.is, .alnea), lbc2(.is, .dotted_circle), lbc2(.is, .hl),
            lbc2(.alnea, .opnea), lbc2(.alea, .opnea), lbc2(.dotted_circle, .opnea), lbc2(.hl, .opnea), lbc2(.nu, .opnea),
            lbc2(.cpnea, .alea), lbc2(.cpnea, .alnea), lbc2(.cpnea, .dotted_circle), lbc2(.cpnea, .hl), lbc2(.cpnea, .nu),
            lbc2(.ebea, .em), lbc2(.ebnea, .em),
            lbc2(.hy, .nu), lbc2(.is, .nu),
            => { line_unbreaks |= lb_required0 << (1 * 16); },

            lbc2(.ri, .ri) => {
                line_unbreaks |= lb_allowed0 << (1 * 16);
                line_break_history = 0;
            },
            lbc2(.clea, .nsnea), lbc2(.clea, .nsea), lbc2(.clnea, .nsnea), lbc2(.clnea, .nsea),
            lbc2(.cpea, .nsnea), lbc2(.cpea, .nsea), lbc2(.cpnea, .nsnea), lbc2(.cpnea, .nsea),
            lbc2(.b2, .b2) => { line_unbreaks |= lb_required2 << (1 * 16); },

            // GL rules - long list, abbreviated:
            else => {
                // GL rules: X GL* -> UNBREAK(3,1) for many preceding classes
                // We handle the main GL cases
                if ((lbh2 & 0xFF) == lbcI(.glea) or (lbh2 & 0xFF) == lbcI(.glnea)) {
                    const prev_c = @as(u8, @intCast(lbh2 >> 8));
                    if (!inSetRaw(prev_c, &.{ lbcI(.oea), lbcI(.onea), lbcI(.bk), lbcI(.cr), lbcI(.lf), lbcI(.nl), lbcI(.zw), lbcI(.wj), lbcI(.sp) })) {
                        line_unbreaks |= lb_required3 << (1 * 16);
                    }
                }
            },
        }

        // 3-char rules (abbreviated)
        const lbh3 = line_break_history & 0xFFFFFF;
        switch (lbh3) {
            lbc3(.sp, .is, .nu) => { line_breaks |= lb_allowed3 << (2 * 16); },
            lbc3(.clea, .sp, .nsnea), lbc3(.clea, .sp, .nsea), lbc3(.clnea, .sp, .nsnea), lbc3(.clnea, .sp, .nsea),
            lbc3(.cpea, .sp, .nsnea), lbc3(.cpea, .sp, .nsea), lbc3(.cpnea, .sp, .nsnea), lbc3(.cpnea, .sp, .nsea),
            lbc3(.b2, .sp, .b2) => { line_unbreaks |= lb_required2 << (1 * 16); },
            lbc3(.ak, .vi, .ak), lbc3(.ak, .vi, .dotted_circle), lbc3(.dotted_circle, .vi, .ak), lbc3(.dotted_circle, .vi, .dotted_circle),
            lbc3(.as, .vi, .ak), lbc3(.as, .vi, .dotted_circle) => { line_unbreaks |= lb_allowed0 << (1 * 16); },
            else => {
                // Hyphen rules (abbreviated): X HY/HYPHEN/BAnea Y -> UNBREAK for many X,Y
                // We check main cases
            },
        }

        if (start_of_text) {
            line_unbreaks |= lb_required5 << (1 * 16);
            BREAK_BITS.apply(&flag_state, GRAPHEME, 1);
        }

        {
            const eff = line_breaks & ~(line_unbreaks | line_unbreaks_async);
            doLineBreak(state, position_offset3 + lb3_off, eff >> 48);
            if (end_of_text) {
                doLineBreak(state, position_offset2 + lb2_off, eff >> 32);
                const flb_flags: u8 = blk: {
                    var f: u8 = 0;
                    if ((eff >> 16) & lb_allowed_mask != 0) f |= @intCast(LINE_SOFT);
                    if ((eff >> 16) & lb_required_mask != 0) f |= @intCast(LINE_HARD);
                    break :blk f;
                };
                BREAK_BITS.apply(&flag_state, flb_flags, 1);
            }
        }

        state.line_breaks = line_breaks;
        state.line_unbreaks = line_unbreaks;
        state.line_break2_position_offset = 0;
        state.line_break3_position_offset = lb2_off;
        state.last_line_break_class = lbc;
        state.line_break_history = line_break_history;
    } else {
        state.line_break2_position_offset -= @as(i16, @intCast(pi));
        state.line_break3_position_offset -= @as(i16, @intCast(pi));
    }

    state.line_unbreaks_async = line_unbreaks_async;

    // ── Flush scripts ──────────────────────────────────────────────────────────
    if ((flush_flags & ff_script != 0) and script_count_at_begin != 0) {
        doBreak(state, script_position_offset, @intCast(SCRIPT), .dont_know, .dont_know, @enumFromInt(break_script));
        script_position_offset = 0;
        if (hard_line_break) {
            script_position_offset = @intCast(pi);
        }
    }

    if (flush_flags & ff_direction_2 != 0) {
        flushDirection(state, &last_direction, bidi2, bidi2_pos_offset);
    }
    if (flush_flags & ff_direction_1 != 0) {
        flushDirection(state, &last_direction, bidi1, bidi1_pos_offset);
    }

    if (flush_flags & ff_direction_paragraph != 0) {
        bidi1 = 0;
        last_direction = 0;
        state.paragraph_start_position = state.current_position + 1;
        breakStateStartParagraph(state);
        if (state.user_paragraph_direction == .dont_know) {
            doBreak(state, 1, @intCast(PARAGRAPH_DIRECTION), .dont_know, .dont_know, .dont_know);
        }
    }

    script_position_offset -= @as(i16, @intCast(pi));

    // Flush buffered position breaks
    doBreak(state, position_offset3, @intCast((flag_state >> 24) & 0xFF), .dont_know, .dont_know, .dont_know);
    if (end_of_text) {
        doBreak(state, position_offset2, @intCast((flag_state >> 16) & 0xFF), .dont_know, .dont_know, .dont_know);
        doBreak(state, 0, @intCast((flag_state >> 8) & 0xFF), .dont_know, .dont_know, .dont_know);
        doBreak(state, @intCast(pi), @intCast(flag_state & 0xFF), .dont_know, .dont_know, .dont_know);
    }

    state.flag_state = flag_state;
    flags |= bsf_started;
    if (end_of_text) flags |= bsf_end;
    state.flags = flags;
    state.position_offset2 = -@as(i16, @intCast(pi));
    state.position_offset3 = @as(i16, @intCast(@as(i32, position_offset2) - @as(i32, @intCast(pi))));
    state.current_position += pi;

    if (flush_flags & ff_direction_2 != 0) {
        state.bidirectional_class2 = bidi1;
        state.bidirectional_class1 = bidi_class;
        state.bidirectional2_position_offset = bidi1_pos_offset - @as(i16, @intCast(pi));
        state.bidirectional1_position_offset = -@as(i16, @intCast(pi));
    }
    state.last_direction = last_direction;
    state.script_position_offset = script_position_offset;
    state.script_count = script_count;
}

pub fn breakEnd(state: *shape.BreakState) void {
    breakAddCodepoint(state, 3, 0, true);
}

pub fn breakBegin(state: *shape.BreakState, paragraph_direction: shape.Direction, japanese_style: shape.JapaneseLineBreak, config_flags: u32) void {
    state.* = std.mem.zeroes(shape.BreakState);
    state.user_paragraph_direction = paragraph_direction;
    state.paragraph_direction = paragraph_direction;
    state.japanese_line_break_style = japanese_style;
    state.config_flags = config_flags;
    state.last_direction = 3; // DIRECTION_COUNT = force direction break at start
    state.position_offset2 = -100;
    state.position_offset3 = -100;
    state.word_break2_position_offset = -100;
    state.line_break2_position_offset = -100;
    state.line_break3_position_offset = -100;
    state.bidirectional1_position_offset = -100;
    state.bidirectional2_position_offset = -100;
    breakStateStartParagraph(state);
    if (@intFromEnum(paragraph_direction) != 0) {
        doBreak(state, 0, @intCast(PARAGRAPH_DIRECTION), .dont_know, paragraph_direction, .dont_know);
    }
}

pub fn breakDrain(state: *shape.BreakState, brk: *shape.Break) i32 {
    if (state.break_count == 0) return 0;
    state.break_count -= 1;
    brk.* = state.breaks[state.break_count];
    return 1;
}

// ─── UTF-8 decoder ────────────────────────────────────────────────────────────

pub fn decodeUtf8(utf8: [*]const u8, length: usize) shape.Decode {
    var result = std.mem.zeroes(shape.Decode);
    if (length == 0) return result;
    const first = utf8[0];
    var followup: usize = 0;
    switch ((first & 0xF0) >> 4) {
        0...7 => { result.codepoint = first & 0x7F; result.valid = true; },
        0xC, 0xD => { followup = 1; result.codepoint = first & 0x1F; result.valid = true; },
        0xE => { followup = 2; result.codepoint = first & 0xF; result.valid = true; },
        0xF => { followup = 3; result.codepoint = first & 7; result.valid = true; },
        else => {},
    }
    if (length > followup) {
        var i: usize = 0;
        while (i < followup) : (i += 1) {
            const c = utf8[1 + i];
            if ((c & 0xC0) == 0x80) {
                result.codepoint = (result.codepoint << 6) | (c & 0x3F);
            } else {
                result.valid = false;
                break;
            }
        }
    } else {
        result.valid = false;
    }
    result.source_characters_consumed = @intCast(1 + followup);
    return result;
}

// ─── Input codepoint index ────────────────────────────────────────────────────

const InputCodepointIndex = struct {
    block_index: u32,
    codepoint_index: u32,
    block_codepoint_count: u32,
};

const input_first_block_msb: u32 = 6;

fn inputCodepointIndex(flat: usize) InputCodepointIndex {
    const msb = msbPositionOrZero(@intCast(flat));
    if (msb <= input_first_block_msb) {
        return .{
            .block_index = 0,
            .codepoint_index = @intCast(flat),
            .block_codepoint_count = 1 << (input_first_block_msb + 1),
        };
    } else {
        return .{
            .block_index = msb - input_first_block_msb,
            .codepoint_index = @intCast(flat & ~(@as(usize, 1) << @as(u6, @intCast(msb)))),
            .block_codepoint_count = @as(u32, 1) << @as(u5, @intCast(msb)),
        };
    }
}

fn inputCodepoint(ctx: *InternalContext, index: usize) ?*shape.ShapeCodepoint {
    if (ctx.err != .none) return null;
    const idx = inputCodepointIndex(index);
    var block = ctx.input_blocks[idx.block_index];
    if (block == null) {
        const new_block = pushArray(&ctx.permanent_arena, shape.ShapeCodepoint, idx.block_codepoint_count);
        if (new_block == null) {
            ctx.err = .out_of_memory;
            return null;
        }
        ctx.input_blocks[idx.block_index] = new_block;
        block = new_block;
    }
    return &block.?[idx.codepoint_index];
}

fn inputCodepointIterator(ctx: *InternalContext, start: usize, one_past_last: usize) shape.ShapeCodepointIterator {
    var result = std.mem.zeroes(shape.ShapeCodepointIterator);
    if (one_past_last <= start) return result;
    const start_idx = inputCodepointIndex(start);
    const end_idx = inputCodepointIndex(one_past_last);
    result.context = @ptrCast(ctx);
    result.block_index = start_idx.block_index;
    result.codepoint_index = start_idx.codepoint_index;
    result.end_block_index = end_idx.block_index;
    result.one_past_last_codepoint_index = end_idx.codepoint_index;
    result.current_block_codepoint_count = if (start_idx.block_index == end_idx.block_index)
        end_idx.codepoint_index
    else
        start_idx.block_codepoint_count;
    result.flat_codepoint_index = @intCast(start);
    return result;
}

fn nextInputCodepoint(it: *shape.ShapeCodepointIterator, codepoint_index: ?*i32) i32 {
    if (it.codepoint_index >= it.current_block_codepoint_count) {
        it.block_index += 1;
        it.codepoint_index = 0;
        it.current_block_codepoint_count = if (it.block_index == it.end_block_index)
            it.one_past_last_codepoint_index
        else
            @as(u32, 1) << @as(u5, @intCast(it.block_index + input_first_block_msb));
    }
    if (it.block_index > it.end_block_index) return 0;

    if (codepoint_index) |ci| ci.* = @intCast(it.flat_codepoint_index);
    const ctx: *InternalContext = @ptrCast(@alignCast(it.context));
    it.codepoint = &ctx.input_blocks[it.block_index].?[it.codepoint_index];
    it.codepoint_index += 1;
    it.flat_codepoint_index += 1;
    return 1;
}

// ─── Update breaks ────────────────────────────────────────────────────────────

fn updateBreaks(ctx: *InternalContext) void {
    if (ctx.flags & context_flag_manual_segmentation != 0) return;

    var brk: shape.Break = undefined;
    while (breakDrain(&ctx.break_state, &brk) != 0) {
        const break_pos: usize = @as(u32, @bitCast(brk.position)) + ctx.break_start_index;
        const input_cp = inputCodepoint(ctx, break_pos) orelse continue;

        if (brk.flags & LINE_HARD != 0) {
            ctx.last_line_break_index = @intCast(break_pos);
        }

        if (brk.flags & GRAPHEME != 0) {
            var match_font: ?*shape.Font = null;
            var fi = ctx.font_count;
            while (fi > 0) {
                fi -= 1;
                const font = ctx.fonts[fi].font orelse continue;
                if (font.user_data) |ud| {
                    const tf: *TatfiFont = @ptrCast(@alignCast(ud));
                    // Check coverage: all codepoints in this grapheme cluster
                    var it = inputCodepointIterator(ctx, ctx.last_grapheme_break_index, break_pos);
                    var covered = true;
                    while (true) {
                        var cp_idx: i32 = 0;
                        if (nextInputCodepoint(&it, &cp_idx) == 0) break;
                        const cp = inputCodepoint(ctx, @intCast(cp_idx)) orelse { covered = false; break; };
                        if (cp.codepoint > 0 and tf.face.glyph_index(@intCast(cp.codepoint)) == null) {
                            covered = false;
                            break;
                        }
                    }
                    if (covered) { match_font = font; break; }
                }
            }
            if (ctx.last_grapheme_break) |lgb| {
                lgb.font = match_font;
            }
            ctx.last_grapheme_break = input_cp;
            ctx.last_grapheme_break_index = @intCast(break_pos);
        }

        input_cp.break_flags |= brk.flags;
        if (brk.flags & SCRIPT != 0) input_cp.script = brk.script;
        if (brk.flags & DIRECTION != 0) input_cp.direction = brk.direction;
        if (brk.flags & PARAGRAPH_DIRECTION != 0) input_cp.paragraph_direction = brk.paragraph_direction;
    }
}

// ─── Context management ───────────────────────────────────────────────────────

fn initContext(ctx: *InternalContext, allocator: ?shape.AllocatorFn, allocator_data: ?*anyopaque) void {
    ctx.* = std.mem.zeroes(InternalContext);

    const alloc = allocator orelse &defaultAllocator;
    ctx.permanent_arena.allocator = alloc;
    ctx.permanent_arena.allocator_data = allocator_data;
    ctx.font_arena.allocator = alloc;
    ctx.font_arena.allocator_data = allocator_data;
    ctx.config_arena.allocator = alloc;
    ctx.config_arena.allocator_data = allocator_data;
    ctx.scratch_arena.allocator = alloc;
    ctx.scratch_arena.allocator_data = allocator_data;
    ctx.glyph_storage.arena.allocator = alloc;
    ctx.glyph_storage.arena.allocator_data = allocator_data;

    ctx.existing_shape_config_sentinel.prev = &ctx.existing_shape_config_sentinel;
    ctx.existing_shape_config_sentinel.next = &ctx.existing_shape_config_sentinel;
    ctx.existing_glyph_config_sentinel.prev = &ctx.existing_glyph_config_sentinel;
    ctx.existing_glyph_config_sentinel.next = &ctx.existing_glyph_config_sentinel;
}

pub fn createContext(allocator: ?shape.AllocatorFn, allocator_data: ?*anyopaque) ?*shape.ShapeContext {
    const alloc = allocator orelse &defaultAllocator;
    const mem = allocatorAllocate(alloc, allocator_data, @sizeOf(InternalContext));
    const ctx: *InternalContext = @ptrCast(@alignCast(mem orelse return null));
    initContext(ctx, alloc, allocator_data);
    ctx.self_allocator = alloc;
    ctx.self_allocator_data = allocator_data;
    return @ptrCast(ctx);
}

pub fn destroyContext(sc: ?*shape.ShapeContext) void {
    const ctx: *InternalContext = @ptrCast(@alignCast(sc orelse return));
    freeArena(&ctx.permanent_arena);
    freeArena(&ctx.config_arena);
    freeArena(&ctx.scratch_arena);
    freeArena(&ctx.font_arena);
    freeArena(&ctx.glyph_storage.arena);
    allocatorFree(ctx.self_allocator, ctx.self_allocator_data, ctx);
}

// Per-font tatfi state stored in font.user_data
pub const TatfiFont = struct {
    face: tatfi.Face,
    data: []u8,
};

pub fn shapePushFontFromFile(sc: *shape.ShapeContext, path: [*:0]const u8, font_index: i32) ?*shape.Font {
    const ctx: *InternalContext = @ptrCast(@alignCast(sc));

    // Read file via libc FILE*
    const FILE = std.c.FILE;
    const fseek_fn: *const fn (*FILE, c_long, c_int) callconv(.c) c_int = @extern(*const fn (*FILE, c_long, c_int) callconv(.c) c_int, .{ .name = "fseek" });
    const ftell_fn: *const fn (*FILE) callconv(.c) c_long = @extern(*const fn (*FILE) callconv(.c) c_long, .{ .name = "ftell" });

    const cfile = std.c.fopen(path, "rb") orelse return null;
    defer _ = std.c.fclose(cfile);
    _ = fseek_fn(cfile, 0, 2); // SEEK_END
    const file_size: usize = @intCast(ftell_fn(cfile));
    _ = fseek_fn(cfile, 0, 0); // SEEK_SET
    if (file_size == 0) return null;

    const data_ptr = pushSize(&ctx.font_arena, file_size, @alignOf(u8)) orelse return null;
    const file_bytes: []u8 = @as([*]u8, @ptrCast(data_ptr))[0..file_size];
    const read = std.c.fread(file_bytes.ptr, 1, file_size, cfile);
    if (read != file_size) return null;

    // Parse with tatfi
    const face = tatfi.Face.parse(file_bytes, @intCast(font_index)) catch return null;

    // Allocate TatfiFont in font arena
    const tf_ptr = pushSize(&ctx.font_arena, @sizeOf(TatfiFont), @alignOf(TatfiFont)) orelse return null;
    const tf: *TatfiFont = @ptrCast(@alignCast(tf_ptr));
    tf.* = .{ .face = face, .data = file_bytes };

    // Allocate shape.Font in font arena
    const font_ptr = pushSize(&ctx.font_arena, @sizeOf(shape.Font), @alignOf(shape.Font)) orelse return null;
    const font: *shape.Font = @ptrCast(@alignCast(font_ptr));
    font.* = std.mem.zeroes(shape.Font);
    font.user_data = tf;

    if (ctx.font_count < 32) {
        ctx.fonts[ctx.font_count] = .{ .font = font, .lifetime = .{ .arena = null, .block_header = null, .used = 0 } };
        ctx.font_count += 1;
    }
    return font;
}

// ─── Shape API ────────────────────────────────────────────────────────────────

pub fn shapeBegin(sc: *shape.ShapeContext, paragraph_direction: shape.Direction, language: shape.Language) void {
  const ctx: *InternalContext = @ptrCast(@alignCast(sc));
  if (ctx.err != .none) return;

  clearArena(&ctx.scratch_arena);
  clearActiveGlyphs(&ctx.glyph_storage);

  ctx.break_start_index = 0;
  ctx.current_feature_overrides = null;
  ctx.current_feature_override_count = 0;
  ctx.need_new_glyph_config = 1;
  ctx.paragraph_direction = paragraph_direction;
  ctx.language = language;
  ctx.input_codepoint_count = 0;
  ctx.next_user_id = 0;
  ctx.last_grapheme_break = null;
  ctx.last_grapheme_break_index = 0;
  ctx.last_line_break_index = 0;
  ctx.run_font = null;
  ctx.run_script = .dont_know;
  ctx.run_direction = .dont_know;

  breakBegin(&ctx.break_state, paragraph_direction, .normal, 0);
}

pub fn shapeCodepointWithUserId(sc: *shape.ShapeContext, codepoint: i32, user_id: i32) void {
    const ctx: *InternalContext = @ptrCast(@alignCast(sc));
    if (ctx.err != .none) return;

    // Handle feature overrides (simplified - just reset if needed)
    if (ctx.need_new_glyph_config != 0) {
        ctx.current_feature_override_count = 0;
        ctx.current_feature_overrides = null;
        ctx.need_new_glyph_config = 0;
    }

    const flat_idx = ctx.input_codepoint_count;
    var input_cp = std.mem.zeroes(shape.ShapeCodepoint);
    input_cp.codepoint = codepoint;
    input_cp.user_id = user_id;
    input_cp.feature_overrides = ctx.current_feature_overrides;
    input_cp.feature_override_count = @intCast(ctx.current_feature_override_count);

    if (flat_idx > 0 and flat_idx == ctx.last_line_break_index) {
        input_cp.break_flags |= LINE;
    }

    if (ctx.flags & context_flag_start_of_manual_run != 0) {
        input_cp.break_flags |= MANUAL;
        if (ctx.flags & context_flag_use_manual_break_info != 0) {
            input_cp.direction = ctx.manual_run_direction;
            input_cp.script = ctx.manual_run_script;
        }
        ctx.flags &= ~context_flag_start_of_manual_run;
    }

    const to = inputCodepoint(ctx, flat_idx) orelse return;
    to.* = input_cp;

    if (ctx.last_grapheme_break == null) {
        ctx.last_grapheme_break = to;
    }

    ctx.input_codepoint_count += 1;

    if (ctx.flags & context_flag_manual_segmentation == 0) {
        breakAddCodepoint(&ctx.break_state, @intCast(codepoint), 1, false);
        updateBreaks(ctx);
    }
}

pub fn shapeUtf8(sc: *shape.ShapeContext, utf8: [*]const u8, length: i32, mode: shape.UserIdGenerationMode) void {
    const ctx: *InternalContext = @ptrCast(@alignCast(sc));
    if (ctx.err != .none or length <= 0) return;
    var at: usize = 0;
    const end: usize = @intCast(length);
    while (at < end) {
        const decode = decodeUtf8(utf8 + at, end - at);
        if (decode.valid) {
            const increment: i32 = switch (mode) {
                .codepoint_index => 1,
                .source_index => decode.source_characters_consumed,
            };
            const user_id = ctx.next_user_id;
            ctx.next_user_id += increment;
            shapeCodepointWithUserId(sc, decode.codepoint, user_id);
        }
        at += @intCast(decode.source_characters_consumed);
    }
}

fn beginParagraph(ctx: *InternalContext) void {
    ctx.run_font = if (ctx.font_count > 0) ctx.fonts[ctx.font_count - 1].font else null;
    ctx.run_script = .dont_know;
    ctx.run_paragraph_direction = .dont_know;
    ctx.run_direction = .dont_know;
}

pub fn shapeEnd(sc: *shape.ShapeContext) void {
    const ctx: *InternalContext = @ptrCast(@alignCast(sc));
    if (ctx.err != .none) return;

    // Zero out the one-past-last codepoint slot
    const opl = inputCodepoint(ctx, ctx.input_codepoint_count);
    if (opl) |p| p.* = std.mem.zeroes(shape.ShapeCodepoint);

    breakEnd(&ctx.break_state);
    updateBreaks(ctx);

    ctx.run_codepoint_iterator.context = null;
    ctx.done_shaping_runs = 0;

    beginParagraph(ctx);
}

pub fn shapeRun(sc: *shape.ShapeContext, run: *shape.Run) i32 {
    const ctx: *InternalContext = @ptrCast(@alignCast(sc));
    if (ctx.err != .none or ctx.done_shaping_runs != 0) return 0;

    var run_font = ctx.run_font;
    var run_script = ctx.run_script;
    var run_para_dir = ctx.run_paragraph_direction;
    var run_dir = ctx.run_direction;
    var result: i32 = 0;

    run.flags = 0;
    clearActiveGlyphs(&ctx.glyph_storage);

    var initialized = true;

    if (ctx.run_codepoint_iterator.context == null) {
        ctx.run_codepoint_iterator = inputCodepointIterator(ctx, 0, ctx.input_codepoint_count);
        initialized = false;
    }

    const it = &ctx.run_codepoint_iterator;

    if (it.context != null and it.block_index <= it.end_block_index) {
        var input_index: i32 = 0;
        main_loop: while (nextInputCodepoint(it, &input_index) != 0) {
            const input_cp = it.codepoint orelse continue;

            // Resolve neutral direction
            if ((input_cp.break_flags & DIRECTION != 0) and
                input_cp.direction == .dont_know)
            {
                input_cp.direction = run_para_dir;
            }

            const first = (result == 0);
            result = 1;

            const cp_font = input_cp.font;
            const cp_script = input_cp.script;
            const cp_dir = input_cp.direction;
            const cp_para_dir = input_cp.paragraph_direction;
            const cp_flags = input_cp.break_flags;

            const new_line = !first and (cp_flags & (LINE_HARD | MANUAL) != 0);

            if (first) {
                run.flags = cp_flags;
                if (cp_flags & LINE_HARD != 0) {
                    beginParagraph(ctx);
                    run_font = ctx.run_font;
                    run_script = .dont_know;
                    run_dir = .dont_know;
                    initialized = false;
                }
            }

            const font_changed = cp_font != null and cp_font != run_font;
            const script_changed = @intFromEnum(cp_script) != 0 and cp_script != run_script;
            const dir_changed = @intFromEnum(cp_dir) != 0 and cp_dir != run_dir;
            const para_dir_changed = @intFromEnum(cp_para_dir) != 0 and cp_para_dir != run_para_dir;

            if (font_changed or script_changed or dir_changed or para_dir_changed or new_line) {
                if (cp_font != null) { ctx.run_font = cp_font; }
                if (@intFromEnum(cp_script) != 0) { ctx.run_script = cp_script; }
                if (@intFromEnum(cp_dir) != 0) { ctx.run_direction = cp_dir; }
                if (@intFromEnum(cp_para_dir) != 0) { ctx.run_paragraph_direction = cp_para_dir; }

                if (initialized or new_line) {
                    // Rewind
                    if (it.codepoint_index == 0) {
                        it.block_index -= 1;
                        it.codepoint_index = (@as(u32, 1) << @as(u5, @intCast(it.block_index + input_first_block_msb))) - 1;
                    } else {
                        it.codepoint_index -= 1;
                    }
                    it.flat_codepoint_index -= 1;
                    break :main_loop;
                } else {
                    // Initialize and keep going
                    run_font = ctx.run_font;
                    run_script = ctx.run_script;
                    run_dir = ctx.run_direction;
                    run_para_dir = ctx.run_paragraph_direction;
                    _ = pushGlyph(&ctx.glyph_storage, run_font, input_cp.codepoint, null, input_index);
                    initialized = true;
                }
            } else {
                _ = pushGlyph(&ctx.glyph_storage, run_font, input_cp.codepoint, null, input_index);
            }
        }

        if (result != 0) {
            if (@intFromEnum(run_dir) == 0) {
                run_dir = .ltr;
                // Check if script is RTL (arabic/hebrew)
                switch (run_script) {
                    .arabic, .hebrew => { run_dir = .rtl; },
                    else => {},
                }
            }
        }
    } else {
        // Check for trailing hard line break
        const opl = inputCodepoint(ctx, ctx.input_codepoint_count);
        if (opl) |p| {
            if (p.break_flags & LINE_HARD != 0) {
                run.flags = p.break_flags;
                result = 1;
            }
        }
        ctx.done_shaping_runs = 1;
    }

    if (result != 0) {
        run.font = run_font;
        run.script = run_script;
        run.paragraph_direction = run_para_dir;
        run.direction = run_dir;
        run.glyphs = activeGlyphIterator(&ctx.glyph_storage);
    }

    return result;
}

// ─── Helper: inSet for small sets ────────────────────────────────────────────

fn inSet(x: u8, comptime values: anytype) bool {
    var mask: u32 = 0;
    const info = @typeInfo(@TypeOf(values));
    inline for (0..info.@"struct".fields.len) |i| {
        const v: u5 = @intCast(values[i]);
        mask |= @as(u32, 1) << v;
    }
    return (((@as(u32, 1) << @as(u5, @intCast(x))) & mask)) != 0;
}

fn inSetRaw(x: u8, values: []const u8) bool {
    for (values) |v| {
        if (x == v) return true;
    }
    return false;
}

// ─── Word break helpers ───────────────────────────────────────────────────────

fn wbc2(a: WBC, b: WBC) u16 {
    return (@as(u16, @intFromEnum(a)) << 8) | @intFromEnum(b);
}
fn wbc3(a: WBC, b: WBC, c: WBC) u32 {
    return (@as(u32, @intFromEnum(a)) << 16) | (@as(u32, @intFromEnum(b)) << 8) | @intFromEnum(c);
}
