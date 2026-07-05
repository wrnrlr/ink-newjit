/// Byte cursor over an in-memory image file, shared by every decoder. Modeled on
/// stb_image's `stbi__context` but memory-only (extensions read the whole file
/// into a heap buffer first, so there is no streaming/callback path). Out-of-range
/// reads return 0 (stb's behaviour: a truncated file decodes to a best effort
/// rather than crashing); bounds-sensitive callers check `atEof`.

pub const Reader = struct {
  data: []const u8,
  pos: usize = 0,

  pub fn init(data: []const u8) Reader {
    return .{ .data = data };
  }

  pub fn rewind(self: *Reader) void {
    self.pos = 0;
  }

  pub fn atEof(self: *const Reader) bool {
    return self.pos >= self.data.len;
  }

  pub fn remaining(self: *const Reader) usize {
    return if (self.pos < self.data.len) self.data.len - self.pos else 0;
  }

  pub fn get8(self: *Reader) u8 {
    if (self.pos >= self.data.len) return 0;
    const v = self.data[self.pos];
    self.pos += 1;
    return v;
  }

  pub fn get16be(self: *Reader) u32 {
    const hi: u32 = self.get8();
    const lo: u32 = self.get8();
    return (hi << 8) | lo;
  }

  pub fn get32be(self: *Reader) u32 {
    const hi = self.get16be();
    const lo = self.get16be();
    return (hi << 16) | lo;
  }

  pub fn get16le(self: *Reader) u32 {
    const lo: u32 = self.get8();
    const hi: u32 = self.get8();
    return (hi << 8) | lo;
  }

  pub fn get32le(self: *Reader) u32 {
    const lo = self.get16le();
    const hi = self.get16le();
    return (hi << 16) | lo;
  }

  /// Copy the next `n` bytes into `buf` (buf.len == n). Returns false if the
  /// stream runs short (buf is zero-filled past the available bytes).
  pub fn getn(self: *Reader, buf: []u8) bool {
    const avail = self.remaining();
    const n = @min(avail, buf.len);
    if (n > 0) @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
    if (n < buf.len) @memset(buf[n..], 0);
    self.pos += n;
    return n == buf.len;
  }

  /// Borrow the next `n` bytes (aliases the source buffer); short at EOF.
  pub fn bytes(self: *Reader, n: usize) []const u8 {
    const avail = self.remaining();
    const m = @min(avail, n);
    const s = self.data[self.pos .. self.pos + m];
    self.pos += m;
    return s;
  }

  pub fn skip(self: *Reader, n: usize) void {
    self.pos = @min(self.data.len, self.pos + n);
  }

  pub fn seek(self: *Reader, off: usize) void {
    self.pos = @min(self.data.len, off);
  }
};
