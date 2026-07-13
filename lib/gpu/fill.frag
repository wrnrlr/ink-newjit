// Vulkan port of fill.wgsl fs_main. Regenerate the .spv with:
//   glslangValidator -V lib/gpu/fill.frag -o lib/gpu/fill.frag.spv
// (temporary GLSL→SPIR-V bridge; Phase 7 re-authors this in dye.k.)
#version 450

layout(set = 0, binding = 1) uniform FragUniforms {
  vec4 frag[11];
} u_frag;
layout(set = 0, binding = 2) uniform texture2D tex;
layout(set = 0, binding = 3) uniform sampler tex_samp;
layout(set = 0, binding = 4) uniform texture2D colormap;
layout(set = 0, binding = 5) uniform sampler colormap_samp;

layout(location = 0) in vec2 ftcoord;
layout(location = 1) in vec2 fpos;
layout(location = 0) out vec4 outColor;

mat3 get_scissorMat() { return mat3(u_frag.frag[0].xyz, u_frag.frag[1].xyz, u_frag.frag[2].xyz); }
mat3 get_paintMat()   { return mat3(u_frag.frag[3].xyz, u_frag.frag[4].xyz, u_frag.frag[5].xyz); }
vec4 get_innerCol()   { return u_frag.frag[6]; }
vec4 get_outerCol()   { return u_frag.frag[7]; }
vec2 get_scissorExt() { return u_frag.frag[8].xy; }
vec2 get_scissorScale(){ return u_frag.frag[8].zw; }
vec2 get_extent()     { return u_frag.frag[9].xy; }
float get_radius()    { return u_frag.frag[9].z; }
float get_feather()   { return u_frag.frag[9].w; }
int get_texType()     { return int(u_frag.frag[10].x); }
int get_type()        { return int(u_frag.frag[10].y); }
vec2 get_blurDir()    { return u_frag.frag[10].zw; }

float sdroundrect(vec2 pt, vec2 ext, float rad) {
  vec2 ext2 = ext - vec2(rad, rad);
  vec2 d = abs(pt) - ext2;
  return min(max(d.x, d.y), 0.0) + length(max(d, vec2(0.0))) - rad;
}

float scissorMask(vec2 p) {
  vec2 sc = abs((get_scissorMat() * vec3(p, 1.0)).xy) - get_scissorExt();
  sc = vec2(0.5) - sc * get_scissorScale();
  return clamp(sc.x, 0.0, 1.0) * clamp(sc.y, 0.0, 1.0);
}

void main() {
  int type_val = get_type();
  float scissor = scissorMask(fpos);
  vec4 color = vec4(0.0);

  if (type_val == 0) { // Gradient
    vec2 pt = (get_paintMat() * vec3(fpos, 1.0)).xy;
    vec2 ext = get_extent();
    float feather = get_feather();
    if (ext.x < 0.5) {
      color = get_innerCol();
    } else {
      float d = clamp((sdroundrect(pt, ext, get_radius()) + feather * 0.5) / max(feather, 0.0001), 0.0, 1.0);
      color = mix(get_innerCol(), get_outerCol(), d);
    }
    color.a *= clamp(ftcoord.y, 0.0, 1.0);
    color *= scissor;
  } else if (type_val == 1) { // Image
    vec2 pt = (get_paintMat() * vec3(fpos, 1.0)).xy / get_extent();
    color = texture(sampler2D(tex, tex_samp), pt);
    int texType = get_texType();
    if (texType == 1) { color = vec4(color.rgb * color.a, color.a); }
    else if (texType == 2) { color = vec4(color.r, color.r, color.r, color.r); }
    else if (texType == 3) {
      color = texture(sampler2D(colormap, colormap_samp), vec2(color.r, 0.5));
      color = vec4(color.rgb * color.a, color.a);
    }
    color *= get_innerCol() * scissor;
  } else if (type_val == 2) { // Stencil fill
    color = vec4(1.0);
  } else if (type_val == 3) { // Textured tris
    color = texture(sampler2D(tex, tex_samp), ftcoord);
    int texType = get_texType();
    if (texType == 1) { color = vec4(color.rgb * color.a, color.a); }
    else if (texType == 2) { color = vec4(color.r, color.r, color.r, color.r); }
    else if (texType == 3) {
      color = texture(sampler2D(colormap, colormap_samp), vec2(color.r, 0.5));
      color = vec4(color.rgb * color.a, color.a);
    }
    color *= get_innerCol() * scissor;
  } else if (type_val == 4) { // Blur
    vec2 pt = (get_paintMat() * vec3(fpos, 1.0)).xy / get_extent();
    vec2 blurDir = get_blurDir();
    vec4 b = vec4(0.0);
    b += texture(sampler2D(tex, tex_samp), pt - 4.0 * blurDir) * 0.02853226260337099;
    b += texture(sampler2D(tex, tex_samp), pt - 3.0 * blurDir) * 0.06723453549491201;
    b += texture(sampler2D(tex, tex_samp), pt - 2.0 * blurDir) * 0.1240093299792275;
    b += texture(sampler2D(tex, tex_samp), pt - 1.0 * blurDir) * 0.1790438646174162;
    b += texture(sampler2D(tex, tex_samp), pt + 0.0 * blurDir) * 0.2023600146101466;
    b += texture(sampler2D(tex, tex_samp), pt + 1.0 * blurDir) * 0.1790438646174162;
    b += texture(sampler2D(tex, tex_samp), pt + 2.0 * blurDir) * 0.1240093299792275;
    b += texture(sampler2D(tex, tex_samp), pt + 3.0 * blurDir) * 0.06723453549491201;
    b += texture(sampler2D(tex, tex_samp), pt + 4.0 * blurDir) * 0.02853226260337099;
    color = b * get_innerCol() * scissor;
  }

  outColor = color;
}
