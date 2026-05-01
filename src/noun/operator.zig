const std = @import("std");

pub const Op = enum(u8) {
  // Monadic veresion of op
  @"%:", @"!:", @"&:", @"+:", @"*:", @"|:", @"<:", @">:", @"=:", @"~:",
  @",:", @"^:", @"#:", @"_:", @"$:", @"?:", @"@:", @"-:", @".:",
  @"0::", @"1::", @"2::", @"9::", // read ops
  sqrt, sqr, exp, log, sin, cos, abs, first, last, count,

  // Dyadic veresion of op
  @"%", @"!", @"&", @"+", @"*", @"|", @"<", @">", @"=", @"~",
  @",", @"^", @"#", @"_", @"$", @"?", @"@", @"-", @".",
  @"0:", @"1:", @"2:", @"9:", // write ops
  in, has,
  @":", // Needed here?
  
  amend3, amend4,
  drill3, drill4,
  splice,
  
  // adverbs
  @"'", @"/", @"\\", @"':", @"/:", @"\\:",
  
  pub const COUNT = @typeInfo(Op).@"enum".fields.len;
  pub inline fn code(op: Op) usize { return @intFromEnum(op); }
};
