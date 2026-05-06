const Primitive = struct {};
const Primitives = struct {
  
  const @"!i" = struct {
    name: "Iota" 
  };
  
  const @"+x" = struct {};
  
  const @"-N" = struct {};
  const @"*x" = struct {};
  const @"+i" = struct {};
  const @"!I" = struct {};
  const @"!d" = struct {};
  const @"&x" = struct {};
  const @"|x" = struct {};
  const @"<s" = struct {};
  const @"<X" = struct {};
  const @">X" = struct {};
  const @"=X" = struct {};
  const @"=i" = struct {};
  const @"~x" = struct {};
  const @",x" = struct {};
  const @"^x" = struct {};
  const @"#x" = struct {};
  const @"_c" = struct {};
  const @"_n" = struct {};

  const @"N+N" = struct {};
  const @"N-N" = struct {};
  const @"N*N" = struct {};
  const @"N%N" = struct {};
  const @"N&N" = struct {};
  const @"N|N" = struct {};
  const @"X=X" = struct {};

  // pub const @"x,x" = @import("pair.zig").Pair;
  const @"i_X"     = struct {};
  const @"I_X"     = struct {};
  const @"B_X"     = struct {};
  const @"X_i"     = struct {};
  const @"x_m"     = struct {};
  const @"m,m"     = struct {};
  const @"x#m"     = struct {};
  const @"M,m"     = struct {};
  // const @"M,m2" = struct {};
  // const @"m|m"  = struct {};
  // const @"m,m2" = struct {};
  // const @"m^m"  = struct {};
  const @"i#X"     = struct {};
  const @"I#X"     = struct {};
  const @"x^X"     = struct {};
  const @"X^X"     = struct {};
  const @"i$C"     = struct {};
  const @"s$x"     = struct {};
  const @"X?x"     = struct {};
  const @"i?X"     = struct {};
  const @"X@X"     = struct {};
  const @"s?x"     = struct {};
  const @"s@x"     = struct {};
  // const @"x@x"  = struct {};
  const @"x has y"     = struct {};
  const @"x in y"      = struct {};

  // IO Verbs
  const @"x 0: x"    = struct {};
  const @"x 1: x"    = struct {};
  const @"x 2: x"    = struct {};

  // Graphical Verbs
  const @"9:x"  = @import("graphics.zig").Draw;
  const @"x9:x" = @import("graphics.zig").DrawDyad;

  // Special Forms
  const @"@[x;y;f]" = struct{};
  const @"@[x;y;F;z]" = struct{};
  const @".[x;y;f]" = struct{};
  const @".[x;y;F;z]" = struct{};
  // const @".[f;y;f]" = struct{}; // try
  const @"?[x;y;z]" = struct{}; // splice
  
  // Adverbs
  const @"i f'" = struct {};
  const @"f'" = struct {};
  const @"x F'" = struct {};
  const @"X'" = struct {};
  const @"F/" = struct {};
  const @"F\\" = struct {};
  const @"x F/" = struct {};
  const @"x F\\" = struct {};
  const @"i f/" = struct {};
  const @"i f\\" = struct {};
  const @"f f/" = struct {};
  const @"f f\\" = struct {};
  const @"f/" = struct {};
  const @"f\\" = struct {};
  const @"C/" = struct {};
  const @"C\\" = struct {};
  const @"I/" = struct {};
  const @"I\\" = struct {};
  const @"i'" = struct {};
  const @"i f':" = struct {};
  const @"F'" = struct {};
  const @"x F':" = struct {};
  const @"x F/:" = struct {};
  const @"x F\\:" = struct {};
};

// Here a colon at the end indicates a monadic phrase.
const Phrase = enum(u8) {
  @"*|:", // last idiom used in a monadic way,
  @"-_-", // ceil
  @"+/", // sum
  @"+\\",
  @"*/", @"*\\",
  @"-/", @"-\\",
};

const Category = enum {
  Arithmetic, IO, 
};

const Call = struct {
};
