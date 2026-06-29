// Fullscreen-triangle blit: copies the offscreen render target to the swapchain.
// Only used in snapshot mode (see gpuRun); the normal path renders straight to
// the swapchain with no blit.

@group(0) @binding(0) var src_tex: texture_2d<f32>;
@group(0) @binding(1) var src_smp: sampler;

struct VsOut {
  @builtin(position) pos: vec4<f32>,
  @location(0) uv: vec2<f32>,
};

@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
  // One oversized triangle covering the screen.
  var xy = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -1.0),
    vec2<f32>( 3.0, -1.0),
    vec2<f32>(-1.0,  3.0),
  );
  let p = xy[vi];
  var out: VsOut;
  out.pos = vec4<f32>(p, 0.0, 1.0);
  out.uv = vec2<f32>((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
  return out;
}

@fragment fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
  return textureSampleLevel(src_tex, src_smp, in.uv, 0.0);
}
