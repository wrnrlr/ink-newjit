const std = @import("std");

// pub const Lab = struct { l: f32 = 0, a: f32 = 0, b: f32 = 0 };
// pub const Lch = struct { l: f32 = 0, c: f32 = 0, h: f32 = 0, a: f32 = 1.0 };

// Oklch color space
pub const Lch = struct {
  l: f32 = 0, c: f32 = 0, h: f32 = 0, a: f32 = 1.0,

  pub fn toRgba(self: Lch) Rgba {
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

  pub fn toF32x4(self: Lch) [4]f32 {
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
    var r_lin = clamp(4.0767416621 * l_c - 3.3077115913 * m_c + 0.2309699292 * s_c);
    var g_lin = clamp(-1.2684380046 * l_c + 2.6097574011 * m_c - 0.3413193965 * s_c);
    var b_lin = clamp(-0.0041960863 * l_c - 0.7034186147 * m_c + 1.7076147010 * s_c);
    _ = &r_lin; _ = &g_lin; _ = &b_lin;
    return .{ srgbGamma(r_lin), srgbGamma(g_lin), srgbGamma(b_lin), self.a };
  }
}; 

pub const Rgba = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 0 };

fn clamp(x: f32) f32 { return @max(0.0, @min(1.0, x)); }

pub fn srgbGamma(x: f32) f32 {
  if (x <= 0.0031308) return 12.92 * x;
  return 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

pub fn srgbToLinear(x: f32) f32 {
  return if (x <= 0.04045) x / 12.92
         else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

pub fn rgbToLch(r: f32, g: f32, b: f32) Lch {
  const rl = srgbToLinear(r);
  const gl = srgbToLinear(g);
  const bl = srgbToLinear(b);
  const lm = std.math.cbrt(0.4122214708 * rl + 0.5363325363 * gl + 0.0514459929 * bl);
  const mm = std.math.cbrt(0.2119034982 * rl + 0.6806995451 * gl + 0.1073969566 * bl);
  const sm = std.math.cbrt(0.0883024619 * rl + 0.2817188376 * gl + 0.6299787005 * bl);
  const L  = 0.2104542553 * lm + 0.7936177850 * mm - 0.0040720468 * sm;
  const a  = 1.9779984951 * lm - 2.4285922050 * mm + 0.4505937099 * sm;
  const bv = 0.0259040371 * lm + 0.7827717662 * mm - 0.8086757660 * sm;
  const c  = @sqrt(a * a + bv * bv);
  const h  = std.math.atan2(bv, a) * (180.0 / std.math.pi);
  return .{ .l = L, .c = c, .h = if (h < 0) h + 360.0 else h };
}

pub const TransparentRgba: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

pub const Black: Lch = .{ .l = 0.0, .c = 0.0, .h = 0.0 };
pub const White: Lch = .{ .l = 1.0, .c = 0.0, .h = 0.0 };
pub const Transparent: Lch = .{ .l = 0, .c = 0, .h = 0, .a = 0 };
pub const Red50: Lch = .{ .l = 0.971, .c = 0.013, .h = 17.38 };
pub const Red100: Lch = .{ .l = 0.936, .c = 0.032, .h = 17.717 };
pub const Red200: Lch = .{ .l = 0.885, .c = 0.062, .h = 18.334 };
pub const Red300: Lch = .{ .l = 0.808, .c = 0.114, .h = 19.571 };
pub const Red400: Lch = .{ .l = 0.704, .c = 0.191, .h = 22.216 };
pub const Red500: Lch = .{ .l = 0.637, .c = 0.237, .h = 25.331 };
pub const Red600: Lch = .{ .l = 0.577, .c = 0.245, .h = 27.325 };
pub const Red700: Lch = .{ .l = 0.505, .c = 0.213, .h = 27.518 };
pub const Red800: Lch = .{ .l = 0.444, .c = 0.177, .h = 26.899 };
pub const Red900: Lch = .{ .l = 0.396, .c = 0.141, .h = 25.723 };
pub const Red950: Lch = .{ .l = 0.258, .c = 0.092, .h = 26.042 };
pub const Orange50: Lch = .{ .l = 0.98, .c = 0.016, .h = 73.684 };
pub const Orange100: Lch = .{ .l = 0.954, .c = 0.038, .h = 75.164 };
pub const Orange200: Lch = .{ .l = 0.901, .c = 0.076, .h = 70.697 };
pub const Orange300: Lch = .{ .l = 0.837, .c = 0.128, .h = 66.29 };
pub const Orange400: Lch = .{ .l = 0.75, .c = 0.183, .h = 55.934 };
pub const Orange500: Lch = .{ .l = 0.705, .c = 0.213, .h = 47.604 };
pub const Orange600: Lch = .{ .l = 0.646, .c = 0.222, .h = 41.116 };
pub const Orange700: Lch = .{ .l = 0.553, .c = 0.195, .h = 38.402 };
pub const Orange800: Lch = .{ .l = 0.47, .c = 0.157, .h = 37.304 };
pub const Orange900: Lch = .{ .l = 0.408, .c = 0.123, .h = 38.172 };
pub const Orange950: Lch = .{ .l = 0.266, .c = 0.079, .h = 36.259 };
pub const Amber50: Lch = .{ .l = 0.987, .c = 0.022, .h = 95.277 };
pub const Amber100: Lch = .{ .l = 0.962, .c = 0.059, .h = 95.617 };
pub const Amber200: Lch = .{ .l = 0.924, .c = 0.12, .h = 95.746 };
pub const Amber300: Lch = .{ .l = 0.879, .c = 0.169, .h = 91.605 };
pub const Amber400: Lch = .{ .l = 0.828, .c = 0.189, .h = 84.429 };
pub const Amber500: Lch = .{ .l = 0.769, .c = 0.188, .h = 70.08 };
pub const Amber600: Lch = .{ .l = 0.666, .c = 0.179, .h = 58.318 };
pub const Amber700: Lch = .{ .l = 0.555, .c = 0.163, .h = 48.998 };
pub const Amber800: Lch = .{ .l = 0.473, .c = 0.137, .h = 46.201 };
pub const Amber900: Lch = .{ .l = 0.414, .c = 0.112, .h = 45.904 };
pub const Amber950: Lch = .{ .l = 0.279, .c = 0.077, .h = 45.635 };
pub const Yellow50: Lch = .{ .l = 0.987, .c = 0.026, .h = 102.212 };
pub const Yellow100: Lch = .{ .l = 0.973, .c = 0.071, .h = 103.193 };
pub const Yellow200: Lch = .{ .l = 0.945, .c = 0.129, .h = 101.54 };
pub const Yellow300: Lch = .{ .l = 0.905, .c = 0.182, .h = 98.111 };
pub const Yellow400: Lch = .{ .l = 0.852, .c = 0.199, .h = 91.936 };
pub const Yellow500: Lch = .{ .l = 0.795, .c = 0.184, .h = 86.047 };
pub const Yellow600: Lch = .{ .l = 0.681, .c = 0.162, .h = 75.834 };
pub const Yellow700: Lch = .{ .l = 0.554, .c = 0.135, .h = 66.442 };
pub const Yellow800: Lch = .{ .l = 0.476, .c = 0.114, .h = 61.907 };
pub const Yellow900: Lch = .{ .l = 0.421, .c = 0.095, .h = 57.708 };
pub const Yellow950: Lch = .{ .l = 0.286, .c = 0.066, .h = 53.813 };
pub const Lime50: Lch = .{ .l = 0.986, .c = 0.031, .h = 120.757 };
pub const Lime100: Lch = .{ .l = 0.967, .c = 0.067, .h = 122.328 };
pub const Lime200: Lch = .{ .l = 0.938, .c = 0.127, .h = 124.321 };
pub const Lime300: Lch = .{ .l = 0.897, .c = 0.196, .h = 126.665 };
pub const Lime400: Lch = .{ .l = 0.841, .c = 0.238, .h = 128.85 };
pub const Lime500: Lch = .{ .l = 0.768, .c = 0.233, .h = 130.85 };
pub const Lime600: Lch = .{ .l = 0.648, .c = 0.2, .h = 131.684 };
pub const Lime700: Lch = .{ .l = 0.532, .c = 0.157, .h = 131.589 };
pub const Lime800: Lch = .{ .l = 0.453, .c = 0.124, .h = 130.933 };
pub const Lime900: Lch = .{ .l = 0.405, .c = 0.101, .h = 131.063 };
pub const Lime950: Lch = .{ .l = 0.274, .c = 0.072, .h = 132.109 };
pub const Green50: Lch = .{ .l = 0.982, .c = 0.018, .h = 155.826 };
pub const Green100: Lch = .{ .l = 0.962, .c = 0.044, .h = 156.743 };
pub const Green200: Lch = .{ .l = 0.925, .c = 0.084, .h = 155.995 };
pub const Green300: Lch = .{ .l = 0.871, .c = 0.15, .h = 154.449 };
pub const Green400: Lch = .{ .l = 0.792, .c = 0.209, .h = 151.711 };
pub const Green500: Lch = .{ .l = 0.723, .c = 0.219, .h = 149.579 };
pub const Green600: Lch = .{ .l = 0.627, .c = 0.194, .h = 149.214 };
pub const Green700: Lch = .{ .l = 0.527, .c = 0.154, .h = 150.069 };
pub const Green800: Lch = .{ .l = 0.448, .c = 0.119, .h = 151.328 };
pub const Green900: Lch = .{ .l = 0.393, .c = 0.095, .h = 152.535 };
pub const Green950: Lch = .{ .l = 0.266, .c = 0.065, .h = 152.934 };
pub const Emerald50: Lch = .{ .l = 0.979, .c = 0.021, .h = 166.113 };
pub const Emerald100: Lch = .{ .l = 0.95, .c = 0.052, .h = 163.051 };
pub const Emerald200: Lch = .{ .l = 0.905, .c = 0.093, .h = 164.15 };
pub const Emerald300: Lch = .{ .l = 0.845, .c = 0.143, .h = 164.978 };
pub const Emerald400: Lch = .{ .l = 0.765, .c = 0.177, .h = 163.223 };
pub const Emerald500: Lch = .{ .l = 0.696, .c = 0.17, .h = 162.48 };
pub const Emerald600: Lch = .{ .l = 0.596, .c = 0.145, .h = 163.225 };
pub const Emerald700: Lch = .{ .l = 0.508, .c = 0.118, .h = 165.612 };
pub const Emerald800: Lch = .{ .l = 0.432, .c = 0.095, .h = 166.913 };
pub const Emerald900: Lch = .{ .l = 0.378, .c = 0.077, .h = 168.94 };
pub const Emerald950: Lch = .{ .l = 0.262, .c = 0.051, .h = 172.552 };
pub const Teal50: Lch = .{ .l = 0.984, .c = 0.014, .h = 180.72 };
pub const Teal100: Lch = .{ .l = 0.953, .c = 0.051, .h = 180.801 };
pub const Teal200: Lch = .{ .l = 0.91, .c = 0.096, .h = 180.426 };
pub const Teal300: Lch = .{ .l = 0.855, .c = 0.138, .h = 181.071 };
pub const Teal400: Lch = .{ .l = 0.777, .c = 0.152, .h = 181.912 };
pub const Teal500: Lch = .{ .l = 0.704, .c = 0.14, .h = 182.503 };
pub const Teal600: Lch = .{ .l = 0.6, .c = 0.118, .h = 184.704 };
pub const Teal700: Lch = .{ .l = 0.511, .c = 0.096, .h = 186.391 };
pub const Teal800: Lch = .{ .l = 0.437, .c = 0.078, .h = 188.216 };
pub const Teal900: Lch = .{ .l = 0.386, .c = 0.063, .h = 188.416 };
pub const Teal950: Lch = .{ .l = 0.277, .c = 0.046, .h = 192.524 };
pub const Cyan50: Lch = .{ .l = 0.984, .c = 0.019, .h = 200.873 };
pub const Cyan100: Lch = .{ .l = 0.956, .c = 0.045, .h = 203.388 };
pub const Cyan200: Lch = .{ .l = 0.917, .c = 0.08, .h = 205.041 };
pub const Cyan300: Lch = .{ .l = 0.865, .c = 0.127, .h = 207.078 };
pub const Cyan400: Lch = .{ .l = 0.789, .c = 0.154, .h = 211.53 };
pub const Cyan500: Lch = .{ .l = 0.715, .c = 0.143, .h = 215.221 };
pub const Cyan600: Lch = .{ .l = 0.609, .c = 0.126, .h = 221.723 };
pub const Cyan700: Lch = .{ .l = 0.52, .c = 0.105, .h = 223.128 };
pub const Cyan800: Lch = .{ .l = 0.45, .c = 0.085, .h = 224.283 };
pub const Cyan900: Lch = .{ .l = 0.398, .c = 0.07, .h = 227.392 };
pub const Cyan950: Lch = .{ .l = 0.302, .c = 0.056, .h = 229.695 };
pub const Sky50: Lch = .{ .l = 0.977, .c = 0.013, .h = 236.62 };
pub const Sky100: Lch = .{ .l = 0.951, .c = 0.026, .h = 236.824 };
pub const Sky200: Lch = .{ .l = 0.901, .c = 0.058, .h = 230.902 };
pub const Sky300: Lch = .{ .l = 0.828, .c = 0.111, .h = 230.318 };
pub const Sky400: Lch = .{ .l = 0.746, .c = 0.16, .h = 232.661 };
pub const Sky500: Lch = .{ .l = 0.685, .c = 0.169, .h = 237.323 };
pub const Sky600: Lch = .{ .l = 0.588, .c = 0.158, .h = 241.966 };
pub const Sky700: Lch = .{ .l = 0.5, .c = 0.134, .h = 242.749 };
pub const Sky800: Lch = .{ .l = 0.443, .c = 0.11, .h = 240.79 };
pub const Sky900: Lch = .{ .l = 0.391, .c = 0.09, .h = 240.876 };
pub const Sky950: Lch = .{ .l = 0.293, .c = 0.066, .h = 243.157 };
pub const Blue50: Lch = .{ .l = 0.97, .c = 0.014, .h = 254.604 };
pub const Blue100: Lch = .{ .l = 0.932, .c = 0.032, .h = 255.585 };
pub const Blue200: Lch = .{ .l = 0.882, .c = 0.059, .h = 254.128 };
pub const Blue300: Lch = .{ .l = 0.809, .c = 0.105, .h = 251.813 };
pub const Blue400: Lch = .{ .l = 0.707, .c = 0.165, .h = 254.624 };
pub const Blue500: Lch = .{ .l = 0.623, .c = 0.214, .h = 259.815 };
pub const Blue600: Lch = .{ .l = 0.546, .c = 0.245, .h = 262.881 };
pub const Blue700: Lch = .{ .l = 0.488, .c = 0.243, .h = 264.376 };
pub const Blue800: Lch = .{ .l = 0.424, .c = 0.199, .h = 265.638 };
pub const Blue900: Lch = .{ .l = 0.379, .c = 0.146, .h = 265.522 };
pub const Blue950: Lch = .{ .l = 0.282, .c = 0.091, .h = 267.935 };
pub const Indigo50: Lch = .{ .l = 0.962, .c = 0.018, .h = 272.314 };
pub const Indigo100: Lch = .{ .l = 0.93, .c = 0.034, .h = 272.788 };
pub const Indigo200: Lch = .{ .l = 0.87, .c = 0.065, .h = 274.039 };
pub const Indigo300: Lch = .{ .l = 0.785, .c = 0.115, .h = 274.713 };
pub const Indigo400: Lch = .{ .l = 0.673, .c = 0.182, .h = 276.935 };
pub const Indigo500: Lch = .{ .l = 0.585, .c = 0.233, .h = 277.117 };
pub const Indigo600: Lch = .{ .l = 0.511, .c = 0.262, .h = 276.966 };
pub const Indigo700: Lch = .{ .l = 0.457, .c = 0.24, .h = 277.023 };
pub const Indigo800: Lch = .{ .l = 0.398, .c = 0.195, .h = 277.366 };
pub const Indigo900: Lch = .{ .l = 0.359, .c = 0.144, .h = 278.697 };
pub const Indigo950: Lch = .{ .l = 0.257, .c = 0.09, .h = 281.288 };
pub const Violet50: Lch = .{ .l = 0.969, .c = 0.016, .h = 293.756 };
pub const Violet100: Lch = .{ .l = 0.943, .c = 0.029, .h = 294.588 };
pub const Violet200: Lch = .{ .l = 0.894, .c = 0.057, .h = 293.283 };
pub const Violet300: Lch = .{ .l = 0.811, .c = 0.111, .h = 293.571 };
pub const Violet400: Lch = .{ .l = 0.702, .c = 0.183, .h = 293.541 };
pub const Violet500: Lch = .{ .l = 0.606, .c = 0.25, .h = 292.717 };
pub const Violet600: Lch = .{ .l = 0.541, .c = 0.281, .h = 293.009 };
pub const Violet700: Lch = .{ .l = 0.491, .c = 0.27, .h = 292.581 };
pub const Violet800: Lch = .{ .l = 0.432, .c = 0.232, .h = 292.759 };
pub const Violet900: Lch = .{ .l = 0.38, .c = 0.189, .h = 293.745 };
pub const Violet950: Lch = .{ .l = 0.283, .c = 0.141, .h = 291.089 };
pub const Purple50: Lch = .{ .l = 0.977, .c = 0.014, .h = 308.299 };
pub const Purple100: Lch = .{ .l = 0.946, .c = 0.033, .h = 307.174 };
pub const Purple200: Lch = .{ .l = 0.902, .c = 0.063, .h = 306.703 };
pub const Purple300: Lch = .{ .l = 0.827, .c = 0.119, .h = 306.383 };
pub const Purple400: Lch = .{ .l = 0.714, .c = 0.203, .h = 305.504 };
pub const Purple500: Lch = .{ .l = 0.627, .c = 0.265, .h = 303.9 };
pub const Purple600: Lch = .{ .l = 0.558, .c = 0.288, .h = 302.321 };
pub const Purple700: Lch = .{ .l = 0.496, .c = 0.265, .h = 301.924 };
pub const Purple800: Lch = .{ .l = 0.438, .c = 0.218, .h = 303.724 };
pub const Purple900: Lch = .{ .l = 0.381, .c = 0.176, .h = 304.987 };
pub const Purple950: Lch = .{ .l = 0.291, .c = 0.149, .h = 302.717 };
pub const Fuchsia50: Lch = .{ .l = 0.977, .c = 0.017, .h = 320.058 };
pub const Fuchsia100: Lch = .{ .l = 0.952, .c = 0.037, .h = 318.852 };
pub const Fuchsia200: Lch = .{ .l = 0.903, .c = 0.076, .h = 319.62 };
pub const Fuchsia300: Lch = .{ .l = 0.833, .c = 0.145, .h = 321.434 };
pub const Fuchsia400: Lch = .{ .l = 0.74, .c = 0.238, .h = 322.16 };
pub const Fuchsia500: Lch = .{ .l = 0.667, .c = 0.295, .h = 322.15 };
pub const Fuchsia600: Lch = .{ .l = 0.591, .c = 0.293, .h = 322.896 };
pub const Fuchsia700: Lch = .{ .l = 0.518, .c = 0.253, .h = 323.949 };
pub const Fuchsia800: Lch = .{ .l = 0.452, .c = 0.211, .h = 324.591 };
pub const Fuchsia900: Lch = .{ .l = 0.401, .c = 0.17, .h = 325.612 };
pub const Fuchsia950: Lch = .{ .l = 0.293, .c = 0.136, .h = 325.661 };
pub const Pink50: Lch = .{ .l = 0.971, .c = 0.014, .h = 343.198 };
pub const Pink100: Lch = .{ .l = 0.948, .c = 0.028, .h = 342.258 };
pub const Pink200: Lch = .{ .l = 0.899, .c = 0.061, .h = 343.231 };
pub const Pink300: Lch = .{ .l = 0.823, .c = 0.12, .h = 346.018 };
pub const Pink400: Lch = .{ .l = 0.718, .c = 0.202, .h = 349.761 };
pub const Pink500: Lch = .{ .l = 0.656, .c = 0.241, .h = 354.308 };
pub const Pink600: Lch = .{ .l = 0.592, .c = 0.249, .h = 0.584 };
pub const Pink700: Lch = .{ .l = 0.525, .c = 0.223, .h = 3.958 };
pub const Pink800: Lch = .{ .l = 0.459, .c = 0.187, .h = 3.815 };
pub const Pink900: Lch = .{ .l = 0.408, .c = 0.153, .h = 2.432 };
pub const Pink950: Lch = .{ .l = 0.284, .c = 0.109, .h = 3.907 };
pub const Rose50: Lch = .{ .l = 0.969, .c = 0.015, .h = 12.422 };
pub const Rose100: Lch = .{ .l = 0.941, .c = 0.03, .h = 12.58 };
pub const Rose200: Lch = .{ .l = 0.892, .c = 0.058, .h = 10.001 };
pub const Rose300: Lch = .{ .l = 0.81, .c = 0.117, .h = 11.638 };
pub const Rose400: Lch = .{ .l = 0.712, .c = 0.194, .h = 13.428 };
pub const Rose500: Lch = .{ .l = 0.645, .c = 0.246, .h = 16.439 };
pub const Rose600: Lch = .{ .l = 0.586, .c = 0.253, .h = 17.585 };
pub const Rose700: Lch = .{ .l = 0.514, .c = 0.222, .h = 16.935 };
pub const Rose800: Lch = .{ .l = 0.455, .c = 0.188, .h = 13.697 };
pub const Rose900: Lch = .{ .l = 0.41, .c = 0.159, .h = 10.272 };
pub const Rose950: Lch = .{ .l = 0.271, .c = 0.105, .h = 12.094 };
pub const Slate50: Lch = .{ .l = 0.984, .c = 0.003, .h = 247.858 };
pub const Slate100: Lch = .{ .l = 0.968, .c = 0.007, .h = 247.896 };
pub const Slate200: Lch = .{ .l = 0.929, .c = 0.013, .h = 255.508 };
pub const Slate300: Lch = .{ .l = 0.869, .c = 0.022, .h = 252.894 };
pub const Slate400: Lch = .{ .l = 0.704, .c = 0.04, .h = 256.788 };
pub const Slate500: Lch = .{ .l = 0.554, .c = 0.046, .h = 257.417 };
pub const Slate600: Lch = .{ .l = 0.446, .c = 0.043, .h = 257.281 };
pub const Slate700: Lch = .{ .l = 0.372, .c = 0.044, .h = 257.287 };
pub const Slate800: Lch = .{ .l = 0.279, .c = 0.041, .h = 260.031 };
pub const Slate900: Lch = .{ .l = 0.208, .c = 0.042, .h = 265.755 };
pub const Slate950: Lch = .{ .l = 0.129, .c = 0.042, .h = 264.695 };
pub const Gray50: Lch = .{ .l = 0.985, .c = 0.002, .h = 247.839 };
pub const Gray100: Lch = .{ .l = 0.967, .c = 0.003, .h = 264.542 };
pub const Gray200: Lch = .{ .l = 0.928, .c = 0.006, .h = 264.531 };
pub const Gray300: Lch = .{ .l = 0.872, .c = 0.01, .h = 258.338 };
pub const Gray400: Lch = .{ .l = 0.707, .c = 0.022, .h = 261.325 };
pub const Gray500: Lch = .{ .l = 0.551, .c = 0.027, .h = 264.364 };
pub const Gray600: Lch = .{ .l = 0.446, .c = 0.03, .h = 256.802 };
pub const Gray700: Lch = .{ .l = 0.373, .c = 0.034, .h = 259.733 };
pub const Gray800: Lch = .{ .l = 0.278, .c = 0.033, .h = 256.848 };
pub const Gray900: Lch = .{ .l = 0.21, .c = 0.034, .h = 264.665 };
pub const Gray950: Lch = .{ .l = 0.13, .c = 0.028, .h = 261.692 };
pub const Zinc50: Lch = .{ .l = 0.985, .c = 0, .h = 0 };
pub const Zinc100: Lch = .{ .l = 0.967, .c = 0.001, .h = 286.375 };
pub const Zinc200: Lch = .{ .l = 0.92, .c = 0.004, .h = 286.32 };
pub const Zinc300: Lch = .{ .l = 0.871, .c = 0.006, .h = 286.286 };
pub const Zinc400: Lch = .{ .l = 0.705, .c = 0.015, .h = 286.067 };
pub const Zinc500: Lch = .{ .l = 0.552, .c = 0.016, .h = 285.938 };
pub const Zinc600: Lch = .{ .l = 0.442, .c = 0.017, .h = 285.786 };
pub const Zinc700: Lch = .{ .l = 0.37, .c = 0.013, .h = 285.805 };
pub const Zinc800: Lch = .{ .l = 0.274, .c = 0.006, .h = 286.033 };
pub const Zinc900: Lch = .{ .l = 0.21, .c = 0.006, .h = 285.885 };
pub const Zinc950: Lch = .{ .l = 0.141, .c = 0.005, .h = 285.823 };
pub const Neutral50: Lch = .{ .l = 0.985, .c = 0, .h = 0 };
pub const Neutral100: Lch = .{ .l = 0.97, .c = 0, .h = 0 };
pub const Neutral200: Lch = .{ .l = 0.922, .c = 0, .h = 0 };
pub const Neutral300: Lch = .{ .l = 0.87, .c = 0, .h = 0 };
pub const Neutral400: Lch = .{ .l = 0.708, .c = 0, .h = 0 };
pub const Neutral500: Lch = .{ .l = 0.556, .c = 0, .h = 0 };
pub const Neutral600: Lch = .{ .l = 0.439, .c = 0, .h = 0 };
pub const Neutral700: Lch = .{ .l = 0.371, .c = 0, .h = 0 };
pub const Neutral800: Lch = .{ .l = 0.269, .c = 0, .h = 0 };
pub const Neutral900: Lch = .{ .l = 0.205, .c = 0, .h = 0 };
pub const Neutral950: Lch = .{ .l = 0.145, .c = 0, .h = 0 };
pub const Stone50: Lch = .{ .l = 0.985, .c = 0.001, .h = 106.423 };
pub const Stone100: Lch = .{ .l = 0.97, .c = 0.001, .h = 106.424 };
pub const Stone200: Lch = .{ .l = 0.923, .c = 0.003, .h = 48.717 };
pub const Stone300: Lch = .{ .l = 0.869, .c = 0.005, .h = 56.366 };
pub const Stone400: Lch = .{ .l = 0.709, .c = 0.01, .h = 56.259 };
pub const Stone500: Lch = .{ .l = 0.553, .c = 0.013, .h = 58.071 };
pub const Stone600: Lch = .{ .l = 0.444, .c = 0.011, .h = 73.639 };
pub const Stone700: Lch = .{ .l = 0.374, .c = 0.01, .h = 67.558 };
pub const Stone800: Lch = .{ .l = 0.268, .c = 0.007, .h = 34.298 };
pub const Stone900: Lch = .{ .l = 0.216, .c = 0.006, .h = 56.043 };
pub const Stone950: Lch = .{ .l = 0.147, .c = 0.004, .h = 49.25 };
