const std = @import("std");
const VM = @import("runtime/vm.zig").VM;
const V = @import("noun/value.zig").V;
const N = @import("noun/value.zig").N;
const TerseFormatter = @import("noun/format.zig").TerseFormatter;
const MockWriter = @import("./util.zig").MockWriter;

const testing = std.testing;

pub const Tester = struct {
  vm: *VM, fmt: TerseFormatter, w: MockWriter,
  out: *MockWriter, out_w: *MockWriter.Writer,
  const alloc = std.testing.allocator;
  fn init() !Tester {
    const vm = try VM.create(alloc);
    const out = try alloc.create(MockWriter);
    out.* = try MockWriter.init(alloc);
    const out_w = try alloc.create(MockWriter.Writer);
    out_w.* = out.writer();
    vm.out = &out_w.interface;
    return .{
      .vm = vm, .out = out, .out_w = out_w,
      .fmt = TerseFormatter.init(vm, vm.alloc, .Text),
      .w = try MockWriter.init(vm.alloc),
    };
  }
  fn check(self: *Tester, txt: []const u8, expected: []const u8) !void {
    var res = try self.vm.eval(txt);
    defer res.deinit(self.vm.alloc);
    self.w.buffer.clearRetainingCapacity();
    var mw = self.w.writer();
    try self.fmt.formatter().fmt(res, &mw.interface);
    try testing.expectEqualStrings(expected, self.w.getText());
  }
  fn checkPretty(self: *Tester, txt: []const u8, expected: []const u8) !void {
    self.fmt.pretty = true;
    defer self.fmt.pretty = false;
    try self.check(txt, expected);
  }
  fn printout(self: *Tester) ![]const u8 {
    const copy = try self.out.alloc.dupe(u8, self.out.getText());
    self.out.buffer.clearRetainingCapacity();
    return copy;
  }
  fn eval(self: *Tester, txt: []const u8) !V { return try self.vm.eval(txt); }
  fn deinit(self: *Tester) void {
    self.w.deinit();
    self.out.deinit();
    alloc.destroy(self.out);
    alloc.destroy(self.out_w);
    self.vm.deinit();
  }
};

const TestTxt = struct {
  name: []u8, in: []u8, out: []u8,
  const Self = @This();
  fn fromFile() Self {}
};

test "basic syntax" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("0 1 -2 0N", "0 1 -2 0N"); // integers
  try t.check("0.1 2. .3 0n 0w -0w", "0.1 2.0 0.3 0n 0w -0w"); // floats
  try t.check("\"a\"", "\"a\"");
  try t.check("\"Hello, World!\"", "\"Hello, World!\"");
  try t.check("`abc", "`abc");
  try t.check("(1;2;3)", "1 2 3");
  try t.check("(1;2.3;`c;%)", "(1;2.3;`c;%)");
  try t.check(",()", ",()");
  try t.check("[a:1]", "[a:1]");
  try t.check("[a:1;b:2 3]", "[a:1;b:2 3]");
  try t.check("[[]n:`b`c;i:2 3]", "[[]n:`b`c;i:2 3]");
  try t.check("[[n:`b`c]i:2 3]", "[[n:`b`c]i:2 3]"); // keyed table (utable)
}

test "pretty repl dict/table rendering" {
  var t = try Tester.init(); defer t.deinit();
  _ = try t.eval("d:[a:1 2 3;c:\"abc\"]");
  // Dict: one key|value per line, char data shown as raw text.
  try t.checkPretty("d", "a|1 2 3\nc|abc");
  // Misaligned keys pad so the bars line up.
  try t.checkPretty("`a`bb!1 2", "a |1\nbb|2");
  // Table: header row, dashed separator, then a row of values per record.
  try t.checkPretty("+d", "a c\n- -\n1 a\n2 b\n3 c");
  // Numeric columns right-align (k9-style); symbol/char columns left-align.
  _ = try t.eval("e:[a:100 2 30;s:`x`yy`z]");
  try t.checkPretty("+e", "  a s\n--- --\n100 x\n  2 yy\n 30 z");
  // Keyed table: key columns and value columns share rows, joined by `|`.
  try t.checkPretty("[[n:`b`c]i:2 3]", "n|i\n-|-\nb|2\nc|3");
  // Single-key dict still renders one line.
  try t.checkPretty("[a:1]", "a|1");
  // Without pretty (raw / leading-whitespace path) the k literal is unchanged.
  try t.check("d", "[a:1 2 3;c:\"abc\"]");
}

test "parse preserves vector literal values" {
  var t = try Tester.init(); defer t.deinit();
  // Vector literals must keep their values in the CST table's `value column; the
  // SPIR-V shader compiler reads them from there. Regression for parse.zig
  // dropping .F/.I/.B/.S/.C literal payloads. Row 1 is the sole statement (the
  // literal); row 0 is the enclosing terse.
  try t.check("((parse \"1.0 2.0 3.0\")`value)1", "1.0 2.0 3.0");
  try t.check("((parse \"1 2 3\")`value)1", "1 2 3");
  try t.check("((parse \"127.1 311.7\")`kind)1", "`floats");
  try t.check("((parse \"127.1 311.7\")`value)1", "127.1 311.7");
}
test "string" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("\"\"", "\"\"");
  try t.check("\"A\"", "\"A\"");
  try t.check("\"Abc\"", "\"Abc\"");
  try t.check("\"\\0\"", "\"\\0\""); // null string (single char)
  try t.check("\"\\n\"", "\"\\n\"");
  try t.check("\"\\t\"", "\"\\t\"");
  try t.check("\"\"\"", "\"\"\"");
  try t.check("\"\"Hi\"\"", "\"\"Hi\"\"");
  try t.check("\"Hello\\0\"", "\"Hello\\0\""); // null string (single char)
}

test "multi-line string" {
  var t = try Tester.init(); defer t.deinit();
  // Closing quote on the content line → no trailing newline; common indent stripped.
  try t.check("\"\n  Hello,\n  World!\"", "\"Hello,\\nWorld!\"");
  // Closing quote on its own line → trailing newline survives.
  try t.check("\"\n  Hello,\n  World!\n\"", "\"Hello,\\nWorld!\\n\"");
  // Deeper indentation beyond the common prefix is preserved; blank lines ignored.
  try t.check("\"\n  a\n\n    b\"", "\"a\\n\\n  b\"");
  // Single-char result still collapses to a char atom.
  try t.check("\"\n  X\"", "\"X\"");
}

test "vector" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("(1 2 3) 2", "3");
  try t.check("a: (1 2 3); a 2", "3");
  try t.check("{x 2} 1 2 3", "3");
  try t.check("1.0 2.0 3.0 4.0 5.0 6.0", "1.0 2.0 3.0 4.0 5.0 6.0");
  try t.check("1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 11.0", "1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 11.0");
  try t.check("(2;3;4)", "2 3 4");
  try t.check("(3;4)", "3 4");
  try t.check("a:3; b:4; (a;b)", "3 4");
}

test "dict syntax" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("[a:1]", "[a:1]");
  try t.check("[a:,1]", "[a:,1]");
  try t.check("[a:1 2 3]", "[a:1 2 3]");
  try t.check("i:!3; [a:i]", "[a:0 1 2]");
  // Empty dict literal: [] is a proper type-`m` dict with no keys/values,
  // and round-trips to its [] literal form.
  try t.check("[]", "[]");
  try t.check("d:[]; @d", "`m");
  try t.check("d:[]; #d", "0");
  try t.check("d:[]; !d", "()");   // keys: empty list prints ()
  try t.check("d:[]; .d", "()");   // values: empty list prints ()
  try t.check("[],[a:1;b:2]", "[a:1;b:2]");
  // Empty list round-trips as () (not ,() which is a one-element list).
  try t.check("()", "()");
  try t.check(",()", ",()");
}

// Arithmetic
test "arithmetic" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("1+2", "3");
  try t.check("2*3", "6");
  try t.check("1.0+2", "3.0");
  try t.check("2.0*3.0", "6.0");
  try t.check("4.0*2", "8.0");
  try t.check("10 20 - 1 2", "9 18");
  try t.check("1 2 + 3 4", "4 6");
  try t.check("1+2 3 4", "3 4 5");
  try t.check("1+`a`b!1 2", "[a:2;b:3]");
  try t.check("1+[a:1;b:2]", "[a:2;b:3]");
  try t.check("1+1 2!`a`b", "!type");
  try t.check("1 2+2 3 4", "!length");
  try t.check("15 mod 15", "0");
  try t.check("15 mod 3", "0");
  try t.check("15 mod 5", "0");
  try t.check("9 mod 5", "4");
  try t.check("9.0 mod 5", "!type");
  try t.check("9 mod 5.0", "!type");
  try t.check("9.0 mod 5.0", "!type");
  try t.check("-(1;2.3;`c)", "!type");
  // try t.check("-`a", "!type"); // TODO maybe we can define user/all erros with neg symbol
  try t.check("sqrt 4 9", "2.0 3.0");
  try t.check("sqr 2 3", "4 9");
  try t.check("sin 0.0", "0.0");
  try t.check("sin 1.0", "0.84147096");
  try t.check("cos 0.0", "1.0");
  // Inverse-trig helpers on the `sym@x call path (src/runtime/syms.zig)
  try t.check("`asin@0.0", "0.0");
  try t.check("`asin@1.0", "1.5707964");
  try t.check("`acos@1.0", "0.0");
  try t.check("`atan@0.0", "0.0");
  try t.check("`asin@(0.0 1.0)", "0.0 1.5707964");
  try t.check("`atan2@(1.0;1.0)", "0.7853982");
  try t.check("`atan2@(0.0 1.0; 1.0 0.0)", "0.0 1.5707964");
  // Phase 1: math fns are prelude NAMES (nouns), not verbs, so `abs -4.0` now
  // parses as `abs - 4.0` (dyadic subtract). Apply a negative literal via brackets.
  // The juxtaposition prelude (`` `abs x ``) keeps abs integer-closed on ints.
  try t.check("abs[-4.0]", "4.0"); // TODO abs 0N crashes
  try t.check("abs[-4]", "4");
  try t.check("sqr 3", "9");
  try t.check("sin 0", "0.0");
  // Phase 3: a literal intrinsic symbol applied lowers to the Op1 kernel at compile
  // time (compileApposit/compileApply peephole) — fusable, integer-closed, correct.
  try t.check("`sqr 2 3", "4 9");
  try t.check("`sqrt 4", "2.0");
  try t.check("`abs 3", "3");
  try t.check("`sqrt 1.0+1.0 2.0 3.0", "1.4142135 1.7320508 2.0"); // fused add+sqrt
  // Phase 3 Level B: a prelude NAME (`:`-bound intrinsic wrapper) lowers to the
  // opcode at the call site (fuses add+sqrt), and shadowing is respected.
  try t.check("sqrt 1.0+1.0 2.0 3.0", "1.4142135 1.7320508 2.0");
  try t.check("{[sin] sin 5}[{x*10}]", "50"); // a param named sin shadows the alias
  // Phase 3: general `:`-constant propagation. A `:`-bound literal global folds into
  // downstream expressions (here `2*n` -> 200) and inlines inside lambdas; a `::`
  // variable or a name the unit mutates is never folded (see "global/list assign").
  try t.check("n:100; 2*n", "200");
  try t.check("dt:0.5; {x+dt}[10.0]", "10.5");
  // try t.check("min 5 3 4 8 2", "2");
  // try t.check("min 5", "!class");
  // try t.check("min `a`b!1 2", "!rank"); 
}

test "logical" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("~0 1 2", "100b");
  try t.check("~0.0", "1b");
  try t.check("1 4 & 3 2", "1 2");
  try t.check("1 4 | 3 2", "3 4");
  // try t.check("~(`a`b!0 1)", "`a`b!1 0");
  try t.check("1=1", "1b");
  try t.check("1=2", "0b");
  try t.check("1<2", "1b");
  try t.check("1>2", "0b");
  try t.check("1.0=1.0", "1b");
  try t.check("1.0<2.0", "1b");
  try t.check("1 2 3 < 2 2 4", "101b");
  try t.check("1 2 3 has 9", "0b");
  try t.check("1 2 3 has 2 9 1", "101b");
  try t.check("\"aeiou\" has \"e\"", "1b");
  try t.check("2 in 1 2 3", "1b");
  try t.check("9 in 1 2 3", "0b");
  try t.check("2 9 1 in 1 2 3", "101b");
  try t.check("\"aeiou\" has \"azbz\"", "1000b");
  try t.check("1.0 0n 3.0 has 0n", "1b");
  try t.check("1.0 0n 3.0 has 2.0", "0b");
}
test "division" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("5%2", "2.5");
  try t.check("4%0", "0w");
  try t.check("0n%2", "0n");
}
test "conditional" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("$[3>2;`a;`b]", "`a");
  try t.check("{$[x=0; 0; x<0; -1; 1]}' -10 0 10", "-1 0 1");
}
test "ordering" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("<3 1 2", "1 2 0");
  try t.check(">3 1 2", "0 2 1");
  try t.check("<\"cba\"", "2 1 0");
  try t.check("<42", ",0"); // TODO should be !class
  try t.check(">\"abc\"", "2 1 0");
  try t.check("<1.1 0n 0.5", "1 2 0");
}

test "amend" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("@[10 20 30 40; 1; :; 99]", "10 99 30 40");
  try t.check("@[10 20 30 40; 1; :; 7.0]", "!type");
  try t.check("@[100 103 110; 0 2; +; 5]", "105 103 115");
  try t.check("@[1 2 3 4; 0 2; :; 8 9]", "8 2 9 4");
  try t.check("@[1 2 3 4; 1 2; {x*2}]", "1 4 6 4");
  try t.check("@[1; 0; :; 5 ]", "!type");
  try t.check("d:[a:10;b:20]; @[d; `a; +; 5]", "[a:15;b:20]");
  // `:`-assign fast path: typed scatter (float) and list assign
  try t.check("@[0.0 0.0 0.0; 0 2; :; 1.5 2.5]", "1.5 0.0 2.5");
  try t.check("@[(1;\"ab\";3); 1; :; 9]", "(1;9;3)");
}
test "splice" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("?[\"abcd\";1 3;\"xyz\"]", "\"axyzd\"");
  try t.check("?[1 2 3 4;1 1;99]", "1 99 2 3 4");
  try t.check("?[1 2 3 4;1 3;100 200]", "1 100 200 4");
  try t.check("?[\"abcd\";0 2;\"\"]", "\"cd\"");
}
test "drill" {
  var t = try Tester.init(); defer t.deinit();
  try t.check(".[(1 2; 3 4); 1 0; :; 9]", "(1 2;9 4)");
  try t.check(".[(1 2; (3 4; 5 6)); 1 1 0; +; 10]", "(1 2;(3 4;15 6))");
  try t.check("u: `name`settings!(`Bob; `theme`vol!(0; 50)); .[u; `settings`vol; +; 10]", "[name:`Bob;settings:[theme:0;vol:60]]");
}

test "deep indexed assign" {
  var t = try Tester.init(); defer t.deinit();
  // A chained single-index lvalue `name[k][i]:v` flattens to one drill .[name;(k;i);:;v],
  // amending the leaf in place without materializing the intermediate container.
  try t.check("G:((1 2 3);(4 5 6)); G[1][2]:99; G", "(1 2 3;4 5 99)");
  // three levels deep
  try t.check("G:(((1 2 3);(4 5 6));((7 8 9);(0 1 2))); G[0][1][2]:99; G 0", "(1 2 3;4 5 99)");
  // a dict slot, then a list element inside it
  try t.check("G:`xs`ys!((1 2 3);(4 5 6)); G[`xs][1]:99; G", "[xs:1 99 3;ys:4 5 6]");
  // compound op folds into the amend at depth (G[`c][1] += 100)
  try t.check("G:`c!,1 2 3; G[`c][1]+:100; G", "[c:,1 102 3]");
  // a deep write EXTENDS a nested dict with a new key (8 absent -> added)
  try t.check("G:()!(); G[`loc]:7 9!3 5; G[`loc][8]:99; G", "[loc:,7 9 8!3 5 99]");
  // the global form `::` works from inside a lambda (no closure over G)
  try t.check("G::((1 2 3);(4 5 6)); {G[1][2]::99}[]; G", "(1 2 3;4 5 99)");
  // regressions: single-level and the semicolon multi-index drill are unaffected
  try t.check("G:`x`y!(1;2); G[`x]:9; G", "[x:9;y:2]");
  try t.check("G:((1 2 3);(4 5 6)); G[1;2]:99; G", "(1 2 3;4 5 99)");
}

// Variadics
test "lambda" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("f: {x+1};f", "{x+1}"); // TODO fix space
}
test "recursion" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("fib: {$[x<2; x; fib[x-1]+fib[x-2]]}", "");
  try t.check("fib 0", "0");
  try t.check("fib 1", "1");
  try t.check("fib 2", "1");
  try t.check("fib 3", "2");
  try t.check("fib 10", "55");
}
test "partial" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("p:1+; p", "1+");
  try t.check("p 2", "3");
  try t.check("@p", "`p");
}
test "partial adverb" {
  var t = try Tester.init(); defer t.deinit();
  // Bracket form: scan(*) applied immediately.
  try t.check("\\[*;1 2 3]", "1 2 6");
  // Bracket form: fold(+) applied immediately.
  try t.check("\\[+;1 2 3 4 5]", "1 3 6 10 15");
  // Partial of an adverb saved, then completed via apposit-call.
  try t.check("a:(\\[*;]); a 1 2 3", "1 2 6");
  // Same partial via bracket-call.
  try t.check("b:(\\[+;]); b[1 2 3 4 5]", "1 3 6 10 15");
}
test "partial amend" {
  var t = try Tester.init(); defer t.deinit();
  // 3-arg amend with the function slot blank, then completed.
  try t.check("@[\"ABC\";1;](_:)", "\"AbC\"");
  try t.check("@[1 2 3;1;](-:)", "1 -2 3");
  // 3-arg drill (path), function completed later.
  try t.check(".[(1 2 3;4 5 6);0 1;](-:)", "(1 -2 3;4 5 6)");
  // Partial amend saved, then completed.
  try t.check("c:(@[\"aBc\";1;]); c(_:)", "\"abc\"");
}
test "dyadic verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("+", "+");
  try t.check("a:+;a[1;3]", "4");
  try t.check("%[4;2]", "2.0");
  try t.check("p:a[1];p[3]", "4");
}
test "monadic verb" {
  var t = try Tester.init(); defer t.deinit();
  // try t.check("*:", "*:"); // should be parsed as a monadic verb
  // try t.check("first: *:; first 1 2 3", "3");
}
test "train assignment" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("h: *|; h 1 2 3", "3"); // *| stored as train: max then first
  try t.check("g: -|; g 1 2 3", "-3 -2 -1"); // -| stored as train: reverse then negate
}
test "function application" {
  var t = try Tester.init(); defer t.deinit();
  _ = try t.eval("f:{x+1}");
  try t.check("f 1", "2");
}
test "partial application" {
  var t = try Tester.init(); defer t.deinit();
  _ = try t.eval("g:{x+y}");
  try t.check("g[1]", "{x+y}[1;]");
  try t.check("g 1", "{x+y}[1;]");
  try t.check("{x+y}[1;2]", "3");
}
test "partial operators" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("(1+) 2", "3");
  try t.check("(1+)[2]", "3");
  _ = try t.eval("a:+");
  try t.check("a[1;2]", "3");
  _ = try t.eval("p:a[1;]");
  try t.check("p", "1+");
  try t.check("p[2]", "3");
  // _ = try t.eval("q:a[;1]");
  // try t.check("q", "+[;1]");
  // try t.check("q[2]", "3");
}
test "juxtoposition" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("d:`a`b`c!1 2 3", "");
  try t.check("d`a`c", "1 3");
}
test "projection" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("inc: 1+; inc 2", "3");
  try t.check("third: {z}[0;1]; third 2", "2");
  // try t.check("@[;i;;]", "???"); // Not sure what this is yet, ignore
}

test "composition" {
  var t = try Tester.init(); defer t.deinit();
  // try t.check("last: *|:; last 1 2 3", "3");
  // try t.check("train: 1+{x*y}@; train[2;3]", "7");
}

test "derived verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("sum: +/; sum 2 3", "5");
}

// try t.check("Decode: 2/; Decode 1 1 0 1", "13"); // Decode and encode adverb not implemented yet

test "idioms" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("*|1 2 3", "3"); // last
  try t.check("&/8 2 5 1 9 4", "1"); // minimum
  // try t.check("0 0 1 1=0 1 0 1", "1001b"); // Kronecker delta
  // try t.check("0 1 0 1>0 0 1 1", "0100b"); // x but not y
  // try t.check("~0 1 0 1>0 0 1 1", "1011b"); // x implies y
  // try t.check("~0 0 1 1=0 1 0 1", "0110b"); // exclusive or
  // try t.check("*:\\(1 2;3 5 7)", "");
}
// 1<:\ 8 6 3 9 1 4
// (8 6 3 9 1 4
// 4 2 5 1 0 3)
// 1 *:\(1 2;3 5 7)

test "extended verbs idioms" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("&/ 5 1 7 3", "1"); // minimum
  try t.check("|/ 5 1 7 3", "7"); // maximum
  // try t.check("&/ 1110b", "0b"); // all
  // try t.check("|/ 0001b", "1b"); // any
  // try t.check("~|/ 0000b", "1b"); // none
}

// Structural verbs
test "#x tally" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("#1", "1");
  try t.check("#1 2 3", "3");
  try t.check("#\"a\"", "1");
  try t.check("#\"abc\"", "3");
  try t.check("#`a", "1");
  try t.check("#`a`b`c", "3");
}
test "+X flip" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("+1 2 3", ",1 2 3");
  try t.check("+(\"ab\";\"cd\")", "(\"ac\";\"bd\")");
  try t.check("+(1 2; 4 5)", "(1 4;2 5)");
  try t.check("+(1 2; 4.5 5.5)", "((1;4.5);(2;5.5))");
}
test "flip dict & table" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("+`a`b!(1 2;3 4)", "[[]a:1 2;b:3 4]");
  try t.check("+([a:1 2;b:3 4])", "[[]a:1 2;b:3 4]");
  try t.check("+([[]a:1 2;b:3 4])", "[a:1 2;b:3 4]");
}
test "amend a table column" {
  // A table (M) shares the Dict payload with a dict (m); amend-by-key replaces a COLUMN.
  // Regression: this used to crash (the amend path assumed the `.m` union tag).
  var t = try Tester.init(); defer t.deinit();
  try t.check("v:[[]px:10. 20.;vx:1. 2.]; @[v;`px;:;99. 99.]", "[[]px:99.0 99.0;vx:1.0 2.0]");
  try t.check("v:[[]px:10. 20.;vx:1. 2.]; @[v;`px;:;(v`px)+v`vx]", "[[]px:11.0 22.0;vx:1.0 2.0]");
  // dict amend (m) still works
  try t.check("d:`px`vx!((10. 20.);(1. 2.)); @[d;`px;:;99. 99.]", "[px:99.0 99.0;vx:1.0 2.0]");
}
test "single-column table column access" {
  // A 1-column table's column names must be a typed S vector (not L), so column
  // access by symbol works the same as a multi-column table.
  var t = try Tester.init(); defer t.deinit();
  try t.check("@!([[]n:`b`c])", "`S");
  try t.check("t:[[]n:`b`c]; t`n", "`b`c");
  try t.check("t:[[]id:1 2 3]; t`id", "1 2 3");
  // Multi-column read returns a LIST of columns (like a dict m`a`b), NOT a sub-table, so
  // column arithmetic is positional: (t`px`py)+t`vx`vy pairs px with vx.
  try t.check("t:[[]px:10. 20.;py:5. 6.;vx:1. 2.;vy:3. 4.]; @t`px`py", "`L");
  try t.check("t:[[]px:10. 20.;py:5. 6.;vx:1. 2.;vy:3. 4.]; (t`px`py)+t`vx`vy", "(11.0 22.0;8.0 10.0)");
  try t.check("t:[[]px:10. 20.;py:5. 6.;vx:1. 2.;vy:3. 4.]; @[t;`px`py;:;(t`px`py)+t`vx`vy]",
              "[[]px:11.0 22.0;py:8.0 10.0;vx:1.0 2.0;vy:3.0 4.0]");
}
test "utable (keyed table)" {
  var t = try Tester.init(); defer t.deinit();
  // construction + round-trip formatting; a keyed table is a dict (m) of rows
  try t.check("[[n:`b`c]i:2 3]", "[[n:`b`c]i:2 3]");
  try t.check("@[[n:`b`c]i:2 3]", "`m");
  try t.check("#[[n:`b`c]i:2 3]", "2");
  try t.check("@!([[n:`b`c]i:2 3])", "`M");        // keys are a table
  // index by key -> value row; absent key -> null
  try t.check("u:[[n:`b`c]i:2 3]; u@`c", "[i:,3]");
  try t.check("u:[[id:1 2 3]px:10. 20. 30.]; u@2", "[px:,20.0]");
  // upsert: insert a new key, then replace an existing key's value row
  try t.check("[[id:1 2]px:10. 20.],`id`px!(3;30.)", "[[id:1 2 3]px:10.0 20.0 30.0]");
  try t.check("[[id:1 2]px:10. 20.],`id`px!(2;99.)", "[[id:1 2]px:10.0 99.0]");
  // columns are TYPE-STABLE: an upsert/insert with a wrong-typed value is a domain
  // error, not a silent re-type (int into a float column → !type).
  try t.check("[[id:1 2]px:10. 20.],`id`px!(3;30)", "!type");
}
test "utable as ECS archetype" {
  var t = try Tester.init(); defer t.deinit();
  // reading a value column by name (so a system can do W`px)
  try t.check("W:[[id:1 2]px:10. 20.;vx:1. 2.]; W`px", "10.0 20.0");
  // amend a value column by name = a whole-column system; keys preserved, stays a utable
  try t.check("W:[[id:1 2]px:10. 20.;vx:1. 2.]; @[W;`px;:;(W`px)+W`vx]", "[[id:1 2]px:11.0 22.0;vx:1.0 2.0]");
  try t.check("W:[[id:1 2]px:10. 20.]; @@[W;`px;:;99. 99.]", "`m");
  // int-key lookup returns a row; a value-column symbol is NOT mistaken for a key
  try t.check("W:[[id:1 2]px:10. 20.]; W@2", "[px:,20.0]");
  // despawn: drop the row(s) whose key is in x
  try t.check("W:[[id:1 2 3]px:10. 20. 30.]; 2 _ W", "[[id:1 3]px:10.0 30.0]");
  try t.check("W:[[id:1 2 3]px:10. 20. 30.]; 1 3 _ W", "[[id:,2]px:,20.0]");
  // amend BY KEY = upsert the row: replace an existing entity, or insert a new one
  try t.check("W:[[id:1 2]px:10. 20.]; @[W;2;:;(`px!99.)]", "[[id:1 2]px:10.0 99.0]");
  try t.check("W:[[id:1 2]px:10. 20.]; @[W;3;:;(`px!30.)]", "[[id:1 2 3]px:10.0 20.0 30.0]");
  // the `u[key]:valrow` sugar lowers to that amend (replace, then insert)
  try t.check("W:[[id:1 2]px:10. 20.]; W[2]:(`px!99.); W", "[[id:1 2]px:10.0 99.0]");
  try t.check("W:[[id:1 2]px:10. 20.]; W[3]:(`px!30.); W", "[[id:1 2 3]px:10.0 20.0 30.0]");
}
test "utable joins" {
  var t = try Tester.init(); defer t.deinit();
  // left join t,k — keep every row of t; merge k's columns by key (shared col overridden
  // where matched, k-only col 0-filled where unmatched). This is the k9 manual example.
  try t.check("t:[[]s:`a`b`c;p:1 2 3;q:7 8 9]; k:[[s:`a`b`x`y`z]q:101 102 103 104 105;r:51 52 53 54 55]; t,k",
              "[[]s:`a`b`c;p:1 2 3;q:101 102 9;r:51 52 0]");
  // outer join k1,k2 — union of keys, k2 wins on shared keys (k9 manual example)
  try t.check("k1:[[s:`a`b]p:1 2;q:3 4]; k2:[[s:`b`c]p:9 8;q:7 6]; k1,k2",
              "[[s:`a`b`c]p:1 9 8;q:3 7 6]");
  // ECS use: dense archetype left-joined with a sparse keyed component = ssetAlign(default 0)
  try t.check("a:[[]id:1 2 3 4;px:10. 20. 30. 40.]; b:[[id:2 4]boost:5. 9.]; (a,b)`boost",
              "0.0 5.0 0.0 9.0");
}
test "nulls verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("^0N", "1b");
  try t.check("^1 0N 3", "010b");
}
test "not verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("~0", "1b");
  try t.check("~1", "0b");
  try t.check("~0 1 2", "100b");
}
test "unit verb gives identity matrix" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("=2", "(1 0;0 1)");
}
test "group verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("=1 2 1", "1 2!(0 2;,1)");
  try t.check("=`a`b`b`c", "[b:1 2;c:,3;a:,0]");
  try t.check("=\"mississippi\"", "\"imps\"!(1 4 7 10;,0;8 9;2 3 5 6)");
}
test "distinct verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("?1 2 1 3 2", "1 2 3");
}
test "uniform verb" {
  var t = try Tester.init(); defer t.deinit();
  var res = try t.eval("?3");
  defer res.deinit(t.vm.alloc);
  try testing.expect(res.len() == 3);
  try testing.expect(std.meta.activeTag(res) == .F);
}
test "!x iota" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("!3", "0 1 2");
  try t.check("!-3", "-3 -2 -1");
  try t.check("!2 3", "(0 0 0 1 1 1;0 1 2 0 1 2)");
}
test "@x type" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("a:;@a", "`"); // blank
  try t.check("@1", "`i");
  try t.check("@12.3", "`f");
  try t.check("@`a", "`s");
  try t.check("@\"\"", "`C");
  try t.check("@\"A\"", "`c");
  try t.check("@\"\\0\"", "`c");
  try t.check("@\"Abc\"", "`C");
  try t.check("@1 2 3", "`I");
  try t.check("@1.2 .3 .4", "`F");
  try t.check("@`a`b`c", "`S");
  try t.check("@`a!1", "`m"); // dict
  try t.check("@()", "`L");
  try t.check("@(1;2.3;`c)", "`L");
  try t.check("@([n:1 2])", "`m");
  try t.check("@([[]n:`a`b`c;i:0 1 2])", "`M"); // table
  
  // try t.check("@{x}", "`o"); // partial
  try t.check("@(1+)", "`p"); // partial
  // try t.check("@(*|:)", "`q"); // composition
  // try t.check("@(*:)", "`u"); // monadic verb
  // try t.check("@(+)", "`v"); // dyadic verb
  // try t.check("@(')", "`w"); // adverb
  // try t.check("@(/:)", "`w"); // adverb — bare / inside parens is parsed as comment
  
  // try t.check("@([[n:`b`c]i:2 3])", "`m"); // incorrect but ignore for now
  // try t.check("@+`a!1", "`M"); // should be a table, but you can ignore for now
}
// TODO: @*| --> @:*:|
test "*X first" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("* 1 2 3", "1");
  try t.check("* 1.0 2.2 3", "1.0");
  try t.check("* \"Abc\"", "\"A\"");
}
test "_N floor" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("_2.1", "2");
  try t.check("_1.2 3.4 5.6", "1 3 5");
}
test "_C lowercase" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("_\"a\"", "\"a\"");
  try t.check("_\"ABC\"", "\"abc\"");
}
test "i_X drop verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("2_1 2 3 4", "3 4");
  try t.check("2_1.2 2.4 3.0 4.0", "3.0 4.0");
  try t.check("-2_`a`b`c", ",`a");
  // try t.check("2_\"abc\"", ",\"c\"");
}
test "X_d drop keys verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("`a_`a`b`c!0 1 2", "[b:1;c:2]");
  try t.check("`a`c_`a`b`c!0 1 2", "[b:1]");
  try t.check("(,2)_1 2 3!\"abc\"", "1 3!\"ac\"");
  try t.check("2 1_1 2 3!\"abc\"", ",3!,\"c\"");
}
test "&x where" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("&3", "0 0 0");
  try t.check("&0", "!0");
  try t.check("&-1", "!domain");
  try t.check("&`a", "!type");
}
test "X!X dict" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("`a`b`c!0N", "[a:0N;b:0N;c:0N]"); // broadcast
  try t.check("`a!1 2 3", "[a:1 2 3]");
  try t.check("`a`b`c!1 2 3", "[a:1;b:2;c:3]");
  try t.check("`a`b`c!(1 2;3 4;5 6)", "[a:1 2;b:3 4;c:5 6]");
  try t.check("1 2!`a`b", "1 2!`a`b");
  try t.check("1.2 3.4!\"ab\"", "1.2 3.4!\"ab\"");
  try t.check("`a`b!1 2 3", "!length");
  try t.check("(,`a)!1 2 3", "!length");
  // try t.check("(1;2.3;`c)!1 2 3", "!nyi");
  // try t.check("(`a!(1 2 3);`b!(4 5 6))", "[a:1 2 3];[b:4 5 6]");
}

// Adverbs
test "each1 adverb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("{_x}' 1.2 2.7 -3.2", "1 2 -4");
  // try t.check("x: !3; y: 10+!3; {x,y}/'[x;y]", "(0 10;1 11;2 12)");
  try t.check("x: !3; y: 10+!3; {x,y}'[x;y]", "(0 10;1 11;2 12)");
  try t.check("x: !3; y: 10+!3; z: 100+!3; {x,y,z}/'[x;y;z]", "(0 10 100;1 11 101;2 12 102)");
  try t.check("x: !3; y: 10+!4; {x,y}'[x;y]", "!length");
}
test "fold with init" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("{x,y}/[0;10]", "0 10");
}
test "fold" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("+/ 1 2 3", "6");
  try t.check("10+/1 2 3", "16");
  try t.check("f:{x+y}\n10 f/1 2 3", "16");
}
test "scan" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("+\\1 2 3", "1 3 6");
  try t.check("10+\\1 2 3", "11 13 16"); // seeded
}
test "ndo" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("5{2*x}/1", "32");
  try t.check("0{2*x}/1", "1");
  try t.check("3{x+1}/10", "13");

  try t.check("5(2*)/1", "32"); // partial not working
}
test "ndos" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("5{2*x}\\1", "1 2 4 8 16 32");
  try t.check("0{2*x}\\1", ",1");
  try t.check("3{x+1}\\10", "10 11 12 13");
  try t.check("5(2*)\\1", "1 2 4 8 16 32"); // partial not working
}
test "while" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("(1<){$[x mod 2; 1+3*x; x div 2]}/3", "1");
}
test "whiles" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("(1<){$[x mod 2; 1+3*x; x div 2]}\\3", "3 10 5 16 8 4 2 1");
}
test "converge" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("{x div 2}/100", "0");
}
test "converges" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("{x div 2}\\100", "100 50 25 12 6 3 1 0");
}
test "stencil" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("3{x,\".\"}' \"abcde\"", "(\"abc.\";\"bcd.\";\"cde.\")");
  try t.check("2{+/x}' 1 2 3 4", "3 5 7");
}
test "window" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("3'\"abcde\"", "(\"abc\";\"bcd\";\"cde\")");
  try t.check("3':1 2 3 4 5", "(1 2 3;2 3 4;3 4 5)");
}
test "eachprior monadic" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("-':12 13 11 17 14", "12 1 -2 6 -3");
}
test "reduce-of-zip fusion" {
  var t = try Tester.init(); defer t.deinit();
  // Fused results must match the unfused `red/ (x bin y)` semantics.
  try t.check("x:1 2 3 4; y:5 6 7 8; +/x*y", "70");   // dot product
  try t.check("x:1 2 3; y:10 20 30; +/x+y", "66");
  try t.check("x:3 1 4; y:1 5 9; &/x|y", "3");
  try t.check("x:1 5 3; y:2 2 9; |/x<y", "1b");        // any
  try t.check("x:1 5 3; y:2 2 9; +/x<y", "2");         // count
  try t.check("x:1 1 1; y:2 2 2; &/x<y", "1b");        // all
  try t.check("x:1.5 2.0; y:2.0 3.0; +/x*y", "9.0");   // float dot
  try t.check("x:1 2 3; y:1.0 2.0 3.0; +/x*y", "14.0"); // mixed -> fallback
  try t.check("x:1 2 3; +/x*2", "12");                  // scalar -> fallback
}
test "eachprior seeded" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("10-':12 13 11 17 14", "2 1 -2 6 -3");
}
// verb like adverbs 
test "encode decode" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("24 60 60/1 2 3", "3723");
  try t.check("24 60 60\\3723", "1 2 3");
  try t.check("2/1 1 0 1", "13");
  try t.check("2\\13", "1 1 0 1");
}
test "join split strings" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("\"ra\"/\"ab\",\"cadab\",\"\"", "!rank"); // C/C falls through to fold; join needs C/L (list syntax pending)
}

test "function calling" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("f:{x+1}", "");
  try t.check("f[1]", "2");
}
test "inline function" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("{x+1} 1", "2");
}

test "monadic verb type" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("*:1 2 3", "1");
  try t.check("+:1 2 3", ",1 2 3");
}

test "global assign" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("a:1; {a::2}[]; a", "2");
}
// test "return" {
//   var t = try Tester.init(); defer t.deinit();
//   try t.check("{:x+1;2}[3]", "4");
// }
test "binding function" {
  var t = try Tester.init(); defer t.deinit();
  _ = try t.eval("f:{x+1}");
  try t.check("f[2]", "3");
}

test "X[I] index array with vector" {
  var t = try Tester.init(); defer t.deinit();
  _ = try t.eval("a:10 20 30 40 50");
  try t.check("a[1 2 3]", "20 30 40");
}

test "!I odometer" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("!2 3", "(0 0 0 1 1 1;0 1 2 0 1 2)");
  try t.check("!2 2", "(0 0 1 1;0 1 0 1)");
  try t.check("!,3", ",0 1 2");
  try t.check("!2 2 2", "(0 0 0 0 1 1 1 1;0 0 1 1 0 0 1 1;0 1 0 1 0 1 0 1)");
}

test "!m keys" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("!`a`b!1 2", "`a`b");
  // try t.check("![[]a:1 2;b:3 4]", "`a`b");
  // try t.check("![[n:`b`c]i:2 3]", "[[]n:`b`c]");
}

test "=i unimat" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("=3", "(1 0 0;0 1 0;0 0 1)");
}

test ",x enlist verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check(",1", ",1");
  try t.check(",\"A\"", ",\"A\"");
  try t.check("@,\"A\"", "`C");
  try t.check(",\"Hi\"", ",\"Hi\"");
  try t.check(",()", ",()");
}

test "X,Y concat verb with vector result" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("1,2", "1 2");
  try t.check("1.2,2.3", "1.2 2.3");
  try t.check("`a,`b", "`a`b");
  try t.check("\"a\",\"b\"", "\"ab\"");
  try t.check("1,2 3", "1 2 3");
  try t.check("1 2,3", "1 2 3");
  try t.check("1.2,3.4 5.6", "1.2 3.4 5.6");
  try t.check("1.2 3.4,5.6", "1.2 3.4 5.6");
  try t.check("`a,`b`c", "`a`b`c");
  try t.check("`a`b,`c", "`a`b`c");
  try t.check("\"ab\",\"c\"", "\"abc\"");
  try t.check("\"a\",\"bc\"", "\"abc\"");
  try t.check("0 1,2 3", "0 1 2 3");
  try t.check("0.0 1.0,2.0 3.0", "0.0 1.0 2.0 3.0");
  try t.check("`a`b,`c`d", "`a`b`c`d");
}

test "concat verb list result" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("1.2,3", "(1.2;3)");
  try t.check("1,2.3", "(1;2.3)");
  try t.check("\"a\",1", "(\"a\";1)");
  try t.check("1,\"a\"", "(1;\"a\")");
  try t.check("\"ab\",1", "(\"ab\";1)");
  try t.check("1,\"ab\"", "(1;\"ab\")");
  try t.check("\"a\",1 2", "(\"a\";1 2)");
  try t.check("{x-1},{x+1}", "({x-1};{x+1})");
  try t.check("1,+", "(1;+)");
  // try t.check("1,+:", "(1;+:)"); // TODO partial (formatting) broken ignore
  try t.check("1,{x}", "(1;{x})");
  try t.check("(1;2.3),`a", "(1;2.3;`a)");
  try t.check("1 2,(3;4.5)", "(1;2;3;4.5)");
}

test "I#y reshape" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("2 3#!6", "(0 1 2;3 4 5)");
  try t.check("2 3#4 5 6 7", "(4 5 6;7 4 5)");
  try t.check("2 2#4 5 6 7 8 9", "(4 5;6 7)");
  try t.check("2 3#`", "(```;```)");
  try t.check("2 1#\"a\"", "(,\"a\";,\"a\")");
  try t.check("3 3 2 # 1", "((1 1;1 1;1 1);(1 1;1 1;1 1);(1 1;1 1;1 1))");
  try t.check("3 3 2 # 1 2", "((1 2;1 2;1 2);(1 2;1 2;1 2);(1 2;1 2;1 2))");
  try t.check("0N 3#!6", "(0 1 2;3 4 5)");
}

test "m,m merge dictionaries" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("[a:1;b:2],[b:3;c:4]", "[a:1;b:3;c:4]");
}

test "m,m merge dictionaries with general-list values" {
  var t = try Tester.init(); defer t.deinit();
  _ = try t.eval("d1: (,`a)!(,(1 2))");
  _ = try t.eval("d2: (,`b)!(,(3 4))");
  _ = try t.eval("d: d1,d2");
  try t.check("d[`a]", "1 2");
  try t.check("d[`b]", "3 4");
}

test "i#y take i number of elements from y" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("5#\"abc\"", "\"abcab\"");
}

test "X#d take key from dictionary d" {
  var t = try Tester.init(); defer t.deinit();
  _ = try t.eval("d: `a`b`c!1 2 3");
  try t.check("`b`c`d#d", "[b:2;c:3;d:0N]");
}

test "null verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("^0 0N 2", "010b");
  try t.check("^0.0 0n 2.1", "010b");
  try t.check("^``a`b", "100b");
}

test "X^y without returns all elements in X not in y" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("\"bc\"^\"abracadabra\"", "\"araadara\"");
}

test "n^N fill empty numeric value with n" {
  var t = try Tester.init(); defer t.deinit();
  // try t.check("3^0N", "3");
  try t.check("1^0 0N 2", "0 1 2");
  try t.check("3^1.2 0n 4.5", "(1.2;3;4.5)");
}

test "I_X cut" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("2 4_\"abcdefg\"", "(\"cd\";\"efg\")");
  try t.check("2 4 4_\"abcde\"", "(\"cd\";\"\";,\"e\")");
  try t.check("0 3_10 20 30 40 50", "(10 20 30;40 50)");
  try t.check("5 10_1 2 3", "(!0;!0)");
}

test "Y_i delete" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("\"abcde\"_2", "\"abde\"");
  try t.check("1 2 3 4_0", "2 3 4");
  try t.check("1 2 3 4_2", "1 2 4");
  try t.check("1 2 3 4_3", "1 2 3");
  try t.check("1 2 3_5", "!length");
}

test "weed out" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("(3>0 3 2)_1 2 3", ",2");   // keep where mask is false
  try t.check("(1<0 0 0)_1 2 3", "1 2 3"); // all-false mask: keep all
  try t.check("(0<1 1 1)_1 2 3", "!0");    // all-true mask: remove all
  try t.check("(3>0 3 2)_1.0 2.0 3.0", ",2.0"); // float weedout
  try t.check("(3>0 3 2)_\"abc\"", ",\"b\"");   // char weedout
}

test "$X string any verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("$123", "\"123\"");
}

test "i$C pad verb" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("5$\"abc\"", "\"abc  \"");
  try t.check("-5$\"abc\"", "\"  abc\"");
}

test "s$y cast y into type of s" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("`c$65", "\"A\"");
  try t.check("`c$65 98 99", "\"Abc\"");
  try t.check("`i$\"Abc\"", "65 98 99");
  try t.check("`s$\"Hi\"", "`Hi");
  // try t.check("`$\"Hi\"", "`Hi"); // TODO: `$ is parsed as symbol named "$", not empty symbol
  try t.check("`i$(1;2.3)", "1 2");
  try t.check("`f$`a`b!1 2", "[a:1.0;b:2.0]");
}

test "s$y to int/float" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("`I$\"123456\"", "123456");
  try t.check("`F$\"12.3\"", "12.3");
  try t.check("`I$\"1.23\"", "0N");
}

test "X?Y find" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("\"abcb\"?\"b\"", "1");
  try t.check("\"abc\"?\"z\"", "3");
  try t.check("\"abc\"?\"ca\"", "2 0");
  try t.check("(1;2.3;`c)?2.3", "1");
  // try t.check("(`a`b`c!1 2 3)?2", "`b"); // Not implemented in Finc or dispatch fallback logic
  try t.check("3 1 4 1 5?3", "0");
  try t.check("3 1 4 1 5?9", "5");
  try t.check("3 1 4?4 9 3", "2 3 0");
}

test "i_Y drop" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("2_1 2 3 4 5", "3 4 5");
  try t.check("-2_1 2 3 4 5", "1 2 3");
  try t.check("0_1 2 3", "1 2 3");
  try t.check("10_1 2 3", "!0");
  try t.check("2_\"hello\"", "\"llo\"");
}

test "?X distinct" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("?3 1 4 1 3", "3 1 4");
  try t.check("?\"banana\"", "\"ban\"");
  try t.check("?7 7 7", ",7");
  try t.check("?1.0 0n 1.0 0n", "1.0 0n");
}

test ".S get variable value by symbol" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("a:2; .`a", "2");
  // try t.check("b.c:3; .`b`c", "3");
}

test ".C eval string" {
  // var t = try Tester.init(); defer t.deinit();
  // try t.check(".\"2+3\"", "5");
}

test ".d values" {
  var t = try Tester.init(); defer t.deinit();
  try t.check(".`x`y!10 20", "10 20");
}

test "x@y apply(1)" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("f:{x}; f@42", "42");
  try t.check("f:{x}; f@1 2 3", "1 2 3");
  try t.check("(*:)@1 2 3", "1");
  try t.check("1 2 3@0", "1");
  try t.check("1 2 3@2", "3");
  try t.check("1 2 3@2 0 1", "3 1 2");
  try t.check("(1 2 3;4 5 6)@0", "1 2 3");
  try t.check("(1 2 3;4 5 6)@1", "4 5 6");
}

test "x.y apply(n)" {
  var t = try Tester.init(); defer t.deinit();
  // try t.check("{x*y+1}.2 3", "8");
  // try t.check("(0 1 2).1", "1");
  // try t.check("(1 2 3;4 5 6). 1 2", "6");
  // try t.check("(1 2 3;4 5 6). 2 5", "0N");
  // try t.check("(1 2 3).0 2", ""); // should error but which, type domain or range
}

test "list assign" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("(a;b): 4.2; a,b", "4.2 4.2");       // from scalar
  try t.check("(a;b): !2; a,b", "0 1");            // from array
  try t.check("(a;b): (1;4.2); (a;b)", "(1;4.2)"); // from list
  try t.check("(a;b): 1 2!3 4; a,b", "3 4");       // from dict
  try t.check("(a;b;c): 1 2", "!length");
  try t.check("(a;b): 1 2 3", "!length");
  try t.check("(a;b;c): 1 2!4 5", "!length");
  try t.check("a:2;b:3; (a;b)*:2; a,b", "4 6");       // from scalar
  try t.check("a:2;b:3; (a;b)+:1 2; a,b", "3 5");     // from array
  try t.check("a:2;b:3; (a;b)+:2 3!1 2; a,b", "3 5"); // from dict Broken
  // try t.check("a:2;b:3; (a;b)+:2 3!1 2; a,b", "3 5"); 
}

test "list assign local" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("{(a;b):42;a,b}[]", "42 42");
  try t.check("{(a;b):!2;a,b}[]", "0 1");
  try t.check("{(a;b):10 20!0 1;a,b}[]", "0 1");
  try t.check("{(a;b;c):1 2}[]", "!length");
  try t.check("{a:10;b:20; (a;b)+:5;a,b}[]", "15 25");
  try t.check("{a:10;b:20; (a;b)+:1 2;a,b}[]", "11 22");
  try t.check("{a:10;b:20; (a;b)+:10 20!1 2;a,b}[]", "11 22"); // Broken
}

test "do not reuse the left argument" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("a: 1 2 3; b: a+1; a", "1 2 3");
}

test "identity" {
  var t = try Tester.init(); defer t.deinit();
  try t.check(":2.3", "2.3");
}

test "right" {
  var t = try Tester.init(); defer t.deinit();
  // `2:` is the IO write digraph, so the numeric left arg needs a space to
  // disambiguate the dyadic right verb `x:y`.
  try t.check("1 2 : 4 5", "4 5");
}

test "Dihedral group of degree 4" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("g:(:; |:; +:; |+:; +|+:; |+|:; +|+|:)", "");
  try t.check("M: 2 2#!4", "");
  try t.check("g@\\:M", "((0 1;2 3);(2 3;0 1);(0 2;1 3);(1 3;0 2);(1 0;3 2);(3 1;2 0);(3 2;1 0))");
}

test "csv parsing quoted fields via file" {
  var t = try Tester.init(); defer t.deinit();
  const csv_content = "name,city\n\"Alice\",\"NYC\"\nBob,LA";
  const tmp_file = "tmp_test_quoted.csv";
  const zio = std.Io.Threaded.global_single_threaded.io();
  {
    const file = try std.Io.Dir.cwd().createFile(zio, tmp_file, .{});
    defer file.close(zio);
    try file.writePositionalAll(zio, csv_content, 0);
  }
  defer std.Io.Dir.cwd().deleteFile(zio, tmp_file) catch {};
  // try t.check("`csv$1:<`\"tmp_test_quoted.csv\"", "[[]name:(\"Alice\";\"Bob\");city:(\"NYC\";\"LA\")]");
}

test "io and csv integration" {
  var t = try Tester.init(); defer t.deinit();
  const csv_content = "name,age\nAlice,30\nBob,25";
  const tmp_file = "tmp_test.csv";
  const zio = std.Io.Threaded.global_single_threaded.io();
  {
    const file = try std.Io.Dir.cwd().createFile(zio, tmp_file, .{});
    defer file.close(zio);
    try file.writePositionalAll(zio, csv_content, 0);
  }
  defer std.Io.Dir.cwd().deleteFile(zio, tmp_file) catch {};

  // try t.check("data: 1: <`\"tmp_test.csv\"; `csv$ data", "[[]name:(\"Alice\";\"Bob\");age:30 25]");
}

test "io verbs" {
  var t = try Tester.init(); defer t.deinit();
  const content = "name,age\nAlice,23\nBob,47\n";
  const tmp_file = "user.csv";
  const zio = std.Io.Threaded.global_single_threaded.io();
  {
    const file = try std.Io.Dir.cwd().createFile(zio, tmp_file, .{});
    defer file.close(zio);
    try file.writePositionalAll(zio, content, 0);
  }
  defer std.Io.Dir.cwd().deleteFile(zio, tmp_file) catch {};

  try t.check("1: `\"user.csv\"", "\"name,age\\nAlice,23\\nBob,47\\n\"");
  try t.check("f: <`\"user.csv\"; 1: f", "\"name,age\\nAlice,23\\nBob,47\\n\"");
}

test "grade ascending list" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("<(1 2 3; 4 5 6)", "0 1");
  try t.check("<(4 5 6; 1 2 3)", "1 0");
  try t.check("<(\"b\";\"a\";\"c\")", "1 0 2");
}

test "comment" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("\"Hi\" /comment ", "\"Hi\"");
}

test "natural (n) dispatch" {
  var t = try Tester.init(); defer t.deinit();
  const dispatch = @import("primitive/dispatch.zig");
  const vm = t.vm;
  // stage-1 atoms: wraps like i, % divides as f32, & | are min/max
  var r = dispatch.dispatch2(vm, .@"+", .{ .n = 2 }, .{ .n = 3 });
  try testing.expect(r.tag() == .n and r.n == 5);
  r = dispatch.dispatch2(vm, .@"-", .{ .n = 2 }, .{ .n = 3 });
  try testing.expect(r.n == std.math.maxInt(u32));
  r = dispatch.dispatch2(vm, .@"*", .{ .n = 6 }, .{ .n = 7 });
  try testing.expect(r.n == 42);
  r = dispatch.dispatch2(vm, .@"%", .{ .n = 1 }, .{ .n = 2 });
  try testing.expect(r.tag() == .f and r.f == 0.5);
  r = dispatch.dispatch2(vm, .@"&", .{ .n = 9 }, .{ .n = 3 });
  try testing.expect(r.n == 3);
  r = dispatch.dispatch2(vm, .@"|", .{ .n = 9 }, .{ .n = 3 });
  try testing.expect(r.n == 9);
  // stage-2 comparisons and match
  r = dispatch.dispatch2(vm, .@"=", .{ .n = 3 }, .{ .n = 3 });
  try testing.expect(r.tag() == .b and r.b);
  r = dispatch.dispatch2(vm, .@"<", .{ .n = 3 }, .{ .n = 9 });
  try testing.expect(r.b);
  r = dispatch.dispatch2(vm, .@"~", .{ .n = 3 }, .{ .n = 3 });
  try testing.expect(r.b);
  r = dispatch.dispatch2(vm, .@"~", .{ .n = 3 }, .{ .i = 3 });
  try testing.expect(!r.b);
  // naturals never mix with other numerics implicitly
  r = dispatch.dispatch2(vm, .@"+", .{ .n = 2 }, .{ .i = 3 });
  try testing.expect(r.tag() == .err);
  r = dispatch.dispatch2(vm, .@"+", .{ .f = 2.0 }, .{ .n = 3 });
  try testing.expect(r.tag() == .err);
  // vectors
  const xv = try V.make(.N, u32, vm.alloc, &.{ 1, 2, 3 });
  defer xv.deinit(vm.alloc);
  const yv = try V.make(.N, u32, vm.alloc, &.{ 10, 20, 30 });
  defer yv.deinit(vm.alloc);
  const rv = dispatch.dispatch2(vm, .@"+", xv, yv);
  defer rv.deinit(vm.alloc);
  try testing.expect(rv.tag() == .N);
  try testing.expectEqualSlices(u32, &.{ 11, 22, 33 }, rv.N.slice());
}

test "tier-2 float precision (f64/f16) dispatch" {
  var t = try Tester.init(); defer t.deinit();
  const dispatch = @import("primitive/dispatch.zig");
  const vm = t.vm;
  // f64 stays in f64; % is a true f64 divide; comparison → bool
  var r = dispatch.dispatch2(vm, .@"+", .{ .d = 2.5 }, .{ .d = 1.5 });
  try testing.expect(r.tag() == .d and r.d == 4.0);
  r = dispatch.dispatch2(vm, .@"%", .{ .d = 1.0 }, .{ .d = 2.0 });
  try testing.expect(r.tag() == .d and r.d == 0.5);
  r = dispatch.dispatch2(vm, .@">", .{ .d = 2.5 }, .{ .d = 1.5 });
  try testing.expect(r.tag() == .b and r.b);
  // f16 closed under its own arithmetic
  r = dispatch.dispatch2(vm, .@"*", .{ .h = 2.0 }, .{ .h = 3.0 });
  try testing.expect(r.tag() == .h and r.h == 6.0);
  // precision never mixes implicitly — every cross-precision pair is !type
  try testing.expect(dispatch.dispatch2(vm, .@"+", .{ .d = 2.0 }, .{ .f = 3.0 }).tag() == .err);
  try testing.expect(dispatch.dispatch2(vm, .@"+", .{ .d = 2.0 }, .{ .h = 3.0 }).tag() == .err);
  try testing.expect(dispatch.dispatch2(vm, .@"+", .{ .h = 2.0 }, .{ .i = 3 }).tag() == .err);
  // vectors
  const xv = try V.make(.D, f64, vm.alloc, &.{ 1.0, 2.0, 3.0 });
  defer xv.deinit(vm.alloc);
  const yv = try V.make(.D, f64, vm.alloc, &.{ 10.0, 20.0, 30.0 });
  defer yv.deinit(vm.alloc);
  const rv = dispatch.dispatch2(vm, .@"+", xv, yv);
  defer rv.deinit(vm.alloc);
  try testing.expect(rv.tag() == .D);
  try testing.expectEqualSlices(f64, &.{ 11.0, 22.0, 33.0 }, rv.D.slice());
}

test "tier-2 literals and casts round-trip" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("3u", "3u");
  try t.check("@3u", "`u32");
  try t.check("2.3d", "2.3d");
  try t.check("@2.3d", "`f64");
  try t.check("2.3h", "2.3h");
  try t.check("@2.3h", "`f16");
  try t.check("2d", "2.0d");
  try t.check("`u32$5", "5u");
  try t.check("`f64$5", "5.0d");
  try t.check("`f$2.5d", "2.5");
  try t.check("`i$2.9d", "2");
  // null literals round-trip
  try t.check("0Nu", "0Nu");
  try t.check("0nd", "0nd");
  try t.check("0nh", "0nh");
}

test "tier-2 structural verbs" {
  var t = try Tester.init(); defer t.deinit();
  // first / last / reverse / tally
  try t.check("*1.0d 2.0d 3.0d", "1.0d");
  try t.check("*|1u 2u 3u", "3u");
  try t.check("|1.0h 2.0h 3.0h", "3.0h 2.0h 1.0h");
  try t.check("#1.0d 2.0d 3.0d", "3");
  // index / take
  try t.check("5u 6u 7u@2", "7u");
  try t.check("2#3.5d", "3.5d 3.5d");
  // fused folds
  try t.check("+/1.0d 2.0d 3.0d", "6.0d");
  try t.check("+/1u 2u 3u", "6u");
  try t.check("|/1u 5u 3u", "5u");
  // grade (returns int indices) + null mask
  try t.check("<3.0d 1.0d 2.0d", "1 2 0");
  try t.check("^0Nu 1u 2u", "100b");
  // naturals: distinct + find
  try t.check("?1u 2u 2u 3u 1u", "1u 2u 3u");
  try t.check("1u 2u 3u?2u", "1");
}

test "dyad dispatch structure" {
  const verbs = @import("primitive/verb/verbs.zig");
  const Op2 = @import("noun/operator.zig").Op2;
  // offsets are monotone and cover all slots
  try testing.expectEqual(@as(u16, 0), verbs.stage2off[0]);
  for (1..verbs.stage2off.len) |i|
    try testing.expect(verbs.stage2off[i] >= verbs.stage2off[i - 1]);
  try testing.expectEqual(verbs.stage2keys.len, verbs.stage2off[verbs.DYAD2_COUNT]);
  try testing.expectEqual(verbs.stage2keys.len, verbs.stage2fns.len);
  // rows are sorted by key
  for (0..verbs.DYAD2_COUNT) |row| {
    var j: usize = verbs.stage2off[row];
    while (j + 1 < verbs.stage2off[row + 1]) : (j += 1)
      try testing.expect(verbs.stage2keys[j] < verbs.stage2keys[j + 1]);
  }
  try testing.expectEqual(Op2.QUICK_COUNT * verbs.S1_STRIDE * verbs.S1_STRIDE, verbs.quick_table.len);
}

// ── Phase 0: the math-intrinsic registry stays faithful to the live enums.
// Guards src/primitive/intrinsic.zig so Phase 1 can generate the lexer keyword
// list / syms dispatch / fuse map from it without drift. See doc/design/dye.md.
test "intrinsic registry parity with Op1/Op2" {
  const intrinsic = @import("primitive/intrinsic.zig");
  const Op1 = @import("noun/operator.zig").Op1;
  const Op2 = @import("noun/operator.zig").Op2;
  for (intrinsic.table) |it| {
    // Any intrinsic that names a CPU opcode must match the real enum member.
    if (it.op1) |o1| try testing.expectEqual(o1, Op1.fromString(it.name).?);
    if (it.op2) |o2| try testing.expectEqual(o2, Op2.fromString(it.name).?);
    // Prelude names must have a working CPU form: either a monadic Op1 kernel
    // (sqrt sqr exp log sin cos abs), or one of the syms.zig std.math helpers
    // (asin acos atan atan2). None should be GPU-only.
    if (it.prelude) {
      const stdmath = std.mem.eql(u8, it.name, "asin") or std.mem.eql(u8, it.name, "acos") or
        std.mem.eql(u8, it.name, "atan") or std.mem.eql(u8, it.name, "atan2");
      try testing.expect(it.op1 != null or stdmath);
    }
  }
  // Spot-checks on the lookup + derived prelude list.
  try testing.expectEqual(Op1.sin, intrinsic.find("sin").?.op1.?);
  try testing.expect(intrinsic.find("atan2").?.arity == .two);
  try testing.expect(intrinsic.find("nope") == null);
  try testing.expectEqual(@as(usize, 11), intrinsic.prelude_names.len);
}
