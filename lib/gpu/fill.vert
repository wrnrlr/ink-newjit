// Vulkan port of fill.wgsl vs_main. Regenerate the .spv with:
//   glslangValidator -V lib/gpu/fill.vert -o lib/gpu/fill.vert.spv
// (temporary GLSL→SPIR-V bridge; Phase 7 re-authors this in dye.k — see
//  doc/design/vulkan-migration.md §6.)
#version 450

layout(set = 0, binding = 0) uniform ViewUniforms {
  vec2 viewSize;
  vec2 _pad;
} u_view;

layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv;

layout(location = 0) out vec2 ftcoord;
layout(location = 1) out vec2 fpos;

void main() {
  ftcoord = uv;
  fpos = pos;
  gl_Position = vec4(
    2.0 * pos.x / u_view.viewSize.x - 1.0,
    1.0 - 2.0 * pos.y / u_view.viewSize.y,
    0.0,
    1.0
  );
}
