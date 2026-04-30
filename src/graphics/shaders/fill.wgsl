struct ViewUniforms {
  viewSize: vec2<f32>,
  _pad: vec2<f32>,
}

struct FragUniforms {
  frag: array<vec4<f32>, 11>,
}

@group(0) @binding(0) var<uniform> u_view: ViewUniforms;
@group(0) @binding(1) var<uniform> u_frag: FragUniforms;
@group(0) @binding(2) var tex: texture_2d<f32>;
@group(0) @binding(3) var tex_samp: sampler;
@group(0) @binding(4) var colormap: texture_2d<f32>;
@group(0) @binding(5) var colormap_samp: sampler;

struct VertexInput {
  @location(0) pos: vec2<f32>,
  @location(1) uv: vec2<f32>,
}

struct VertexOutput {
  @builtin(position) position: vec4<f32>,
  @location(0) ftcoord: vec2<f32>,
  @location(1) fpos: vec2<f32>,
}

fn get_scissorMat() -> mat3x3<f32> {
  return mat3x3<f32>(u_frag.frag[0].xyz, u_frag.frag[1].xyz, u_frag.frag[2].xyz);
}
fn get_paintMat() -> mat3x3<f32> {
  return mat3x3<f32>(u_frag.frag[3].xyz, u_frag.frag[4].xyz, u_frag.frag[5].xyz);
}
fn get_innerCol() -> vec4<f32> { return u_frag.frag[6]; }
fn get_outerCol() -> vec4<f32> { return u_frag.frag[7]; }
fn get_scissorExt() -> vec2<f32> { return u_frag.frag[8].xy; }
fn get_scissorScale() -> vec2<f32> { return u_frag.frag[8].zw; }
fn get_extent() -> vec2<f32> { return u_frag.frag[9].xy; }
fn get_radius() -> f32 { return u_frag.frag[9].z; }
fn get_feather() -> f32 { return u_frag.frag[9].w; }
fn get_texType() -> i32 { return i32(u_frag.frag[10].x); }
fn get_type() -> i32 { return i32(u_frag.frag[10].y); }
fn get_blurDir() -> vec2<f32> { return u_frag.frag[10].zw; }

fn sdroundrect(pt: vec2<f32>, ext: vec2<f32>, rad: f32) -> f32 {
  let ext2 = ext - vec2<f32>(rad, rad);
  let d = abs(pt) - ext2;
  return min(max(d.x, d.y), 0.0) + length(max(d, vec2<f32>(0.0, 0.0))) - rad;
}

fn scissorMask(p: vec2<f32>) -> f32 {
  let scMat = get_scissorMat();
  let scExt = get_scissorExt();
  let scScale = get_scissorScale();
  var sc = (abs((scMat * vec3<f32>(p, 1.0)).xy) - scExt);
  sc = vec2<f32>(0.5, 0.5) - sc * scScale;
  return clamp(sc.x, 0.0, 1.0) * clamp(sc.y, 0.0, 1.0);
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
  var out: VertexOutput;
  out.ftcoord = in.uv;
  out.fpos = in.pos;
  out.position = vec4<f32>(
    2.0 * in.pos.x / u_view.viewSize.x - 1.0,
    1.0 - 2.0 * in.pos.y / u_view.viewSize.y,
    0.0,
    1.0
  );
  return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
  let type_val = get_type();
  let scissor = scissorMask(in.fpos);
  var color: vec4<f32> = vec4<f32>(0.0);

  if (type_val == 0) { // Gradient
    let pt = (get_paintMat() * vec3<f32>(in.fpos, 1.0)).xy;
    let ext = get_extent();
    let feather = get_feather();
    if (ext.x < 0.5) {
      color = get_innerCol();
    } else {
      let d = clamp((sdroundrect(pt, ext, get_radius()) + feather * 0.5) / max(feather, 0.0001), 0.0, 1.0);
      color = mix(get_innerCol(), get_outerCol(), d);
    }
    color.a *= clamp(in.ftcoord.y, 0.0, 1.0);
    color *= scissor;
  } else if (type_val == 1) { // Image
    let pt = (get_paintMat() * vec3<f32>(in.fpos, 1.0)).xy / get_extent();
    color = textureSample(tex, tex_samp, pt);
    let texType = get_texType();
    if (texType == 1) { color = vec4<f32>(color.rgb * color.a, color.a); }
    else if (texType == 2) { color = vec4<f32>(color.r, color.r, color.r, color.r); }
    else if (texType == 3) {
      color = textureSample(colormap, colormap_samp, vec2<f32>(color.r, 0.5));
      color = vec4<f32>(color.rgb * color.a, color.a);
    }
    color *= get_innerCol() * scissor;
  } else if (type_val == 2) { // Stencil fill
    color = vec4<f32>(1.0, 1.0, 1.0, 1.0);
  } else if (type_val == 3) { // Textured tris
    color = textureSample(tex, tex_samp, in.ftcoord);
    let texType = get_texType();
    if (texType == 1) { color = vec4<f32>(color.rgb * color.a, color.a); }
    else if (texType == 2) { color = vec4<f32>(color.r, color.r, color.r, color.r); }
    else if (texType == 3) {
      color = textureSample(colormap, colormap_samp, vec2<f32>(color.r, 0.5));
      color = vec4<f32>(color.rgb * color.a, color.a);
    }
    color *= get_innerCol() * scissor;
  } else if (type_val == 4) { // Blur
    let pt = (get_paintMat() * vec3<f32>(in.fpos, 1.0)).xy / get_extent();
    let blurDir = get_blurDir();
    var blurCol = vec4<f32>(0.0);
    blurCol += textureSample(tex, tex_samp, pt - 4.0 * blurDir) * 0.02853226260337099;
    blurCol += textureSample(tex, tex_samp, pt - 3.0 * blurDir) * 0.06723453549491201;
    blurCol += textureSample(tex, tex_samp, pt - 2.0 * blurDir) * 0.1240093299792275;
    blurCol += textureSample(tex, tex_samp, pt - 1.0 * blurDir) * 0.1790438646174162;
    blurCol += textureSample(tex, tex_samp, pt + 0.0 * blurDir) * 0.2023600146101466;
    blurCol += textureSample(tex, tex_samp, pt + 1.0 * blurDir) * 0.1790438646174162;
    blurCol += textureSample(tex, tex_samp, pt + 2.0 * blurDir) * 0.1240093299792275;
    blurCol += textureSample(tex, tex_samp, pt + 3.0 * blurDir) * 0.06723453549491201;
    blurCol += textureSample(tex, tex_samp, pt + 4.0 * blurDir) * 0.02853226260337099;
    color = blurCol * get_innerCol() * scissor;
  }

  return color;
}
