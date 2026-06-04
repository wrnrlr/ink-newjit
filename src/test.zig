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
    try self.fmt.formatter().format(res, &mw.interface);
    try testing.expectEqualStrings(expected, self.w.getText());
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
  // try t.check("[[n:`b`c]i:2 3]", "[[n:`b`c]i:2 3]");
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
}

test "- neg" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("-(1;2.3;`c)", "!type");
  // try t.check("-`a", "!type"); // TODO maybe we can define user/all erros with neg symbol
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
}
test "named math operators" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("sqrt 4 9", "2.0 3.0");
  try t.check("sqr 2 3", "4 9");
  try t.check("sin 0.0", "0.0");
  try t.check("sin 1.0", "0.84147096");
  try t.check("cos 0.0", "1.0");
  try t.check("abs -4.0", "4.0"); // TODO abs 0N crashes
  // try t.check("min 5 3 4 8 2", "2");
  // try t.check("min 5", "!class");
  // try t.check("min `a`b!1 2", "!rank");
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
}
test "drill" {
  var t = try Tester.init(); defer t.deinit();
  try t.check(".[(1 2; 3 4); 1 0; :; 9]", "(1 2;9 4)");
  try t.check(".[(1 2; (3 4; 5 6)); 1 1 0; +; 10]", "(1 2;(3 4;15 6))");
  try t.check("u: `name`settings!(`Bob; `theme`vol!(0; 50)); .[u; `settings`vol; +; 10]", "[name:`Bob;settings:[theme:0;vol:60]]");
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
  // try t.check("@[\"ABC\";1;](_:)", "\"AbC\"");
  // try t.check("@[1 2 3;1;](-:)", "1 -2 3");
  // 3-arg drill (path), function completed later.
  // try t.check(".[(1 2 3;4 5 6);0 1;](-:)", "(1 -2 3;4 5 6)");
  // Partial amend saved, then completed.
  // try t.check("c:(@[\"aBc\";1;]); c(_:)", "\"abc\"");
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
  try t.check("=`a`b`b`c", "[a:,0;b:1 2;c:,3]");
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
  try t.check("_ 2.1", "2");
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
  try t.check("&0", "&0");
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

// test "each2 adverb" {
//   var t = try Tester.init(); defer t.deinit();
//   try t.check("2 3#'\"ab\"", "(\"aa\";\"bbb\")");
// }
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

// Assignment
test "name binding" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("a:10; a", "10");
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
}

test "m,m merge dictionaries" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("[a:1;b:2],[b:3;c:4]", "[a:1;b:3;c:4]");
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

test "I_C cut characters at every N" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("2 4_\"abcdefg\"", "(\"cd\";\"efg\")");
}

test "C_i delete character at n" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("\"abcde\"_2", "\"abde\"");
}

test "weed out" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("(3>0 3 2)_1 2 3", ",2"); // FIXME lhs needs to be a bitmask 
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
  try t.check("\"abc\"?\"z\"", "0N");
  try t.check("\"abc\"?\"ca\"", "2 0");
  try t.check("(1;2.3;`c)?2.3", "1");
  // try t.check("(`a`b`c!1 2 3)?2", "`b"); // Not implemented in Finc or dispatch fallback logic
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
  try t.check(":2.3", "2.4");
}

test "right" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("1 2:4 5", "4 5");
}

test "Dihedral group of degree 4" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("g:(:; |:; +:; |+:; +|+:; |+|:; +|+|:)", "");
  try t.check("M: 2 2#!4", "");
  try t.check("g@\\:M", "((0 1;2 3);(2 3;0 1);(0 2;1 3);(1 3;0 2);(1 0;3 2);(3 1;2 0);(3 2;1 0))");
}

test "csv parsing" {
  var t = try Tester.init(); defer t.deinit();
  // try t.check("`csv$\"name,age\nAlice,30\nBob,25\"", "[[]name:(\"Alice\";\"Bob\");age:30 25]");
  // try t.check("`csv@\"name,age\nAlice,30\nBob,25\"", "[[]name:(\"Alice\";\"Bob\");age:30 25]");
  // try t.check("`csv@\"name,age\nAlice,30\nBob,25\n\"", "[[]name:(\"Alice\";\"Bob\");age:30 25]");
  // try t.check("`csv@\"name,age\r\nAlice,30\r\nBob,25\r\n\"", "[[]name:(\"Alice\";\"Bob\");age:30 25]");
  // try t.check("`csv@\"1,2\n3,4\"", "[[]a:1 3;b:2 4]");
  // try t.check("`csv@\"val\n1\n2\n3\"", "[[]val:1 2 3]");
  // try t.check("@`csv@\"name,age\"", "[[]name:`L;age:`L]");
  // try t.check("`csv@\"x,y\n1.5,2.5\n3.0,4.0\"", "[[]x:1.5 3.0;y:2.5 4.0]");
  // try t.check("`csv@\"\"", "!domain");
  // try t.check("`csv@\"n\n1\n2.5\n3\"", "[[]n:1.0 2.5 3.0]");
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

// JSON encoding tests

test "json atom integer" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("`json@\"42\"", "42");
  try t.check("`json@\"3.14\"", "3.14");
  try t.check("`json@\"true\"", "1b");
  try t.check("`json@\"false\"", "0b");
  try t.check("`json@\"null\"", "");
  try t.check("`json@\"[1,2,3]\"", "1 2 3");
  try t.check("`json@\"[1.5,2.5,3.0]\"", "1.5 2.5 3.0");
  try t.check("`json@\"[true,false,true]\"", "101b");
  try t.check("`json@\"\"", "!domain");
}

test "json empty string returns domain error" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("`json@\"\"", "!domain");
}

test "json nested array" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("`json@\"[1,[2,3]]\"", "(1;2 3)");
}

test "json object via file" {
  var t = try Tester.init(); defer t.deinit();
  const json_content = "{\"x\":1,\"y\":2}";
  const tmp = "tmp_test_obj.json";
  const zio = std.Io.Threaded.global_single_threaded.io();
  { const f = try std.Io.Dir.cwd().createFile(zio, tmp, .{}); defer f.close(zio);
    try f.writePositionalAll(zio, json_content, 0); }
  defer std.Io.Dir.cwd().deleteFile(zio, tmp) catch {};
  // try t.check("`json$1:<`\"tmp_test_obj.json\"", "[x:1;y:2]");
}

test "json array of same-schema objects becomes table" {
  var t = try Tester.init(); defer t.deinit();
  const json_content = "[{\"a\":1,\"b\":2},{\"a\":3,\"b\":4}]";
  const tmp = "tmp_test_arr.json";
  const zio = std.Io.Threaded.global_single_threaded.io();
  { const f = try std.Io.Dir.cwd().createFile(zio, tmp, .{}); defer f.close(zio);
    try f.writePositionalAll(zio, json_content, 0); }
  defer std.Io.Dir.cwd().deleteFile(zio, tmp) catch {};
  // try t.check("`json$1:<`\"tmp_test_arr.json\"", "[[]a:1 3;b:2 4]");
}

// XML encoding tests

// test "xml parsing column schema" {
//   var t = try Tester.init(); defer t.deinit();
//   const xml_content = "<a/>";
//   const tmp = "tmp_test.xml";
//   const zio = std.Io.Threaded.global_single_threaded.io();
//   { const f = try std.Io.Dir.cwd().createFile(zio, tmp, .{}); defer f.close(zio);
//     try f.writePositionalAll(zio, xml_content, 0); }
//   defer std.Io.Dir.cwd().deleteFile(zio, tmp) catch {};
//   // try t.check("@`xml$1:<`\"tmp_test.xml\"", "[[]id:`L;parent:`L;kind:`L;name:`L;value:`L]");
// }

// test "xml parsing self-closing element has one node" {
//   var t = try Tester.init(); defer t.deinit();
//   const xml_content = "<a/>";
//   const tmp = "tmp_test_self.xml";
//   const zio = std.Io.Threaded.global_single_threaded.io();
//   { const f = try std.Io.Dir.cwd().createFile(zio, tmp, .{}); defer f.close(zio);
//     try f.writePositionalAll(zio, xml_content, 0); }
//   defer std.Io.Dir.cwd().deleteFile(zio, tmp) catch {};
//   // try t.check("#`xml$1:<`\"tmp_test_self.xml\"", "1");
// }

// test "xml parsing nested elements" {
//   var t = try Tester.init(); defer t.deinit();
//   const xml_content = "<a><b/><c/></a>";
//   const tmp = "tmp_test_nest.xml";
//   const zio = std.Io.Threaded.global_single_threaded.io();
//   { const f = try std.Io.Dir.cwd().createFile(zio, tmp, .{}); defer f.close(zio);
//     try f.writePositionalAll(zio, xml_content, 0); }
//   defer std.Io.Dir.cwd().deleteFile(zio, tmp) catch {};
//   // try t.check("#`xml$1:<`\"tmp_test_nest.xml\"", "3");
// }

// test "xml parsing element with attribute" {
//   var t = try Tester.init(); defer t.deinit();
//   const xml_content = "<item id=\"1\"/>";
//   const tmp = "tmp_test_attr.xml";
//   const zio = std.Io.Threaded.global_single_threaded.io();
//   { const f = try std.Io.Dir.cwd().createFile(zio, tmp, .{}); defer f.close(zio);
//     try f.writePositionalAll(zio, xml_content, 0); }
//   defer std.Io.Dir.cwd().deleteFile(zio, tmp) catch {};
//   // 1 elem + 1 attr = 2 nodes
//   // try t.check("#`xml$1:<`\"tmp_test_attr.xml\"", "2");
// }

// test "xml parsing element with text content" {
//   var t = try Tester.init(); defer t.deinit();
//   const xml_content = "<a>hello</a>";
//   const tmp = "tmp_test_txt.xml";
//   const zio = std.Io.Threaded.global_single_threaded.io();
//   { const f = try std.Io.Dir.cwd().createFile(zio, tmp, .{}); defer f.close(zio);
//     try f.writePositionalAll(zio, xml_content, 0); }
//   defer std.Io.Dir.cwd().deleteFile(zio, tmp) catch {};
//   // 1 elem + 1 text = 2 nodes
//   // try t.check("#`xml$1:<`\"tmp_test_txt.xml\"", "2");
// }

// test "xml empty string returns domain error" {
//   var t = try Tester.init(); defer t.deinit();
//   const xml_content = "";
//   const tmp = "tmp_test_empty.xml";
//   const zio = std.Io.Threaded.global_single_threaded.io();
//   { const f = try std.Io.Dir.cwd().createFile(zio, tmp, .{}); defer f.close(zio);
//     try f.writePositionalAll(zio, xml_content, 0); }
//   defer std.Io.Dir.cwd().deleteFile(zio, tmp) catch {};
//   // try t.check("`xml$1:<`\"tmp_test_empty.xml\"", "!domain");
// }

test "grade ascending list" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("<(1 2 3; 4 5 6)", "0 1");
  try t.check("<(4 5 6; 1 2 3)", "1 0");
  try t.check("<(\"b\";\"a\";\"c\")", "1 0 2");
}

// test "print verb writes to out" {
//   var t = try Tester.init(); defer t.deinit();
//   (try t.eval("` 0: \"Hello\"")).deinit(t.vm.alloc);
//   const o1 = try t.printout();
//   defer testing.allocator.free(o1);
//   try testing.expectEqualStrings("Hello\n", o1);
//   (try t.eval("` 0: \"foo\"\n` 0: \"bar\"")).deinit(t.vm.alloc);
//   const o2 = try t.printout();
//   defer testing.allocator.free(o2);
//   try testing.expectEqualStrings("foo\nbar\n", o2);
//   // no-space form: `0:"world" parses as symbol-0 bind, routed to WriteLines
//   (try t.eval("`0:\"world\"")).deinit(t.vm.alloc);
//   const o3 = try t.printout();
//   defer testing.allocator.free(o3);
//   try testing.expectEqualStrings("world\n", o3);
// }

test "insert dict into table" {
  var t = try Tester.init(); defer t.deinit();
  // try t.check("[[]c1:`a`b`a;c2:1 2 7],`c1`c2!(`a;12)", "[[]c1:`a`b`a`a;c2:1 2 7 12]");
  // try t.check("[[]c1:`a`b`a;c2:1 2 7],[c1:`c;c2:12]", "[[]c1:`a`b`a`c;c2:1 2 7 12]");
}

test "upsert dict into utable" {
  var t = try Tester.init(); defer t.deinit();
  // update existing key
  // try t.check("[[c1:`a`b`c]c2:1 2 7],[c1:`a;c2:12]", "[[c1:`a`b`c]c2:12 2 7]");
  // try t.check("[[c1:`a`b`c]c2:1 2 7],[c1:`b;c2:12]", "[[c1:`a`b`c]c2:1 12 7]");
  // insert new key
  // try t.check("[[c1:`a`b`c]c2:1 2 7],`c1`c2!(`d;12)", "[[c1:`a`b`c`d]c2:1 2 7 12]");
}

test "union join two tables" {
  // var t = try Tester.init(); defer t.deinit();
  // basic union join
  // try t.check("[[]s:`a`b;p:1 2;q:3 4],[[]s:`b`c;p:11 12;q:21 22]", "[[]s:`a`b`b`c;p:1 2 11 12;q:3 4 21 22]");
  // single-row tables
  // try t.check("[[]x:1;y:10],[[]x:2;y:20]", "[[]x:1 2;y:10 20]");
  // different columns: return t1 unchanged
  // try t.check("[[]x:1 2;y:3 4],[[]a:5 6;b:7 8]", "[[]x:1 2;y:3 4]");
}

test "left join table with utable" {
  // var t = try Tester.init(); defer t.deinit();
  // value column override + new column
  // try t.check("[[]s:`a`b`c;p:1 2 3;q:7 8 9],[[s:`a`b`x`y`z]q:101 102 103 104 105;r:51 52 53 54 55]", "[[]s:`a`b`c;p:1 2 3;q:101 102 9;r:51 52 0]");
  // all rows match
  // try t.check("[[]s:`a`b;v:10 20],[[s:`a`b]v:100 200;w:1 2]", "[[]s:`a`b;v:100 200;w:1 2]");
  // no rows match: all from t, extra col is 0
  // try t.check("[[]s:`c`d;v:10 20],[[s:`a`b]v:100 200;w:1 2]", "[[]s:`c`d;v:10 20;w:0 0]");
}

test "outer join two utables" {
  var t = try Tester.init(); defer t.deinit();
  // from spec: overlapping keys update, new keys append
  // try t.check("[[s:`a`b]p:1 2;q:3 4],[[s:`b`c]p:9 8;q:7 6]", "[[s:`a`b`c]p:1 9 8;q:3 7 6]");
  // no overlap: all rows from both
  // try t.check("[[s:`a]p:1;q:3],[[s:`b]p:9;q:7]", "[[s:`a`b]p:1 9;q:3 7]");
  // full overlap: k2 overrides all of k1
  // try t.check("[[s:`a`b]p:1 2;q:3 4],[[s:`a`b]p:9 8;q:7 6]", "[[s:`a`b]p:9 8;q:7 6]");
}

test "comment" {
  var t = try Tester.init(); defer t.deinit();
  try t.check("\"Hi\" /comment ", "\"Hi\"");
}
