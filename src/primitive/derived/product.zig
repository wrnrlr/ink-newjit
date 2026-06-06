const util = @import("../../util.zig");
const r = @import("reduce.zig");

pub const Product = struct {
  pub const op = .@"*/";
  _I: util.MonadFn = r.typedFold(i32, .@"*"),
  _F: util.MonadFn = r.typedFold(f32, .@"*"),
  _L: util.MonadFn = r.listFold(.@"*"),
};
