const std = @import("std");

pub const Oklch = struct {
  l: f32, c: f32, h: f32,

  pub fn toRgba(self: Oklch) Rgba {
    const h_rad = std.math.degreesToRadians(self.h);
    const a_lab = self.c * std.math.cos(h_rad);
    const b_lab = self.c * std.math.sin(h_rad);
    const L = self.l;

    const l_m = L + 0.3963377774 * a_lab + 0.2158037573 * b_lab;
    const m_m = L - 0.1055613458 * a_lab - 0.0638541728 * b_lab;
    const s_m = L - 0.0894841775 * a_lab - 1.2914855480 * b_lab;

    const l_c = l_m * l_m * l_m;
    const m_c = m_m * m_m * m_m;
    const s_c = s_m * s_m * s_m;

    var r_lin = 4.0767416621 * l_c - 3.3077115913 * m_c + 0.2309699292 * s_c;
    var g_lin = -1.2684380046 * l_c + 2.6097574011 * m_c - 0.3413193965 * s_c;
    var b_lin = -0.0041960863 * l_c - 0.7034186147 * m_c + 1.7076147010 * s_c;

    r_lin = clamp(r_lin);
    g_lin = clamp(g_lin);
    b_lin = clamp(b_lin);

    const r_srgb = srgbGamma(r_lin);
    const g_srgb = srgbGamma(g_lin);
    const b_srgb = srgbGamma(b_lin);

    return Rgba{
      .r = @intFromFloat(@round(r_srgb * 255.0)),
      .g = @intFromFloat(@round(g_srgb * 255.0)),
      .b = @intFromFloat(@round(b_srgb * 255.0)),
      .a = 255,
    };
  }
}; 

pub const Rgba = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 0 };

fn clamp(x: f32) f32 { return @max(0.0, @min(1.0, x)); }

fn srgbGamma(x: f32) f32 {
  if (x <= 0.0031308) {
    return 12.92 * x;
  } else {
    return 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
  }
}

pub const Transparent: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
