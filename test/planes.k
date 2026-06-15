/ test/planes.k — intersecting planes with Phong shading via vertex+fragment SPIR-V
/
/ Three intersecting rectangular planes rendered with a Phong lighting model.
/ Geometry: two quads per plane (triangulated), normals per vertex.
/ Lighting: one directional light, ambient+diffuse+specular.
/
/ TODO: requires vertex shader support in spirv.k (not yet implemented).
/ The current FragmentShader API only covers the fragment stage;
/ vertex shaders need a VertexShader compiler + DrawMesh API with depth buffer.
/
/ Planned API:
/   vtxWds:  VertexShader[`pos`nor!`v3`v3; `glPos`vNor!`v4`v3; {[pos;nor] ...}]
/   frgWds:  FragmentShader[`vNor`out!`v3`v4; {[vNor] ...}]
/   mesh:    CompileMesh[vtxWds; frgWds]
/   DrawMesh[verts; mesh]
/
/ Run: zig build gpu && ink test/planes.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ Plane geometry — XY, XZ, YZ planes as two triangles each (6 verts per plane).
/ Format: [x y z nx ny nz] stride 6.

xyPlane: (-1. -1. 0. 0. 0. 1.   1. -1. 0. 0. 0. 1.   1. 1. 0. 0. 0. 1.   -1. -1. 0. 0. 0. 1.   1. 1. 0. 0. 0. 1.  -1. 1. 0. 0. 0. 1.)
xzPlane: (-1. 0. -1. 0. 1. 0.   1. 0. -1. 0. 1. 0.   1. 0. 1. 0. 1. 0.   -1. 0. -1. 0. 1. 0.   1. 0. 1. 0. 1. 0.  -1. 0. 1. 0. 1. 0.)
yzPlane: (0. -1. -1. 1. 0. 0.   0. -1. 1. 1. 0. 0.   0. 1. 1. 1. 0. 0.   0. -1. -1. 1. 0. 0.   0. 1. 1. 1. 0. 0.  0. 1. -1. 1. 0. 0.)
verts: xyPlane,xzPlane,yzPlane

/ Phong fragment shader (world-space normal input, directional light).
/ lightDir and view direction are baked in as constants for now.
phongFrag: FragmentShader[`nor`out!`v3`v4; {[nor]
  amb: 0.15
  ld: normalize[(0.6; 0.8; 0.4)]
  diff: smoothstep[0.0; 0.1; dot[nor; ld]]
  (amb+diff; amb+diff; amb+diff; 1.0)}]

/ TODO: VertexShader and DrawMesh once vertex stage is supported.
/ For now, print the compiled fragment SPIR-V word count as a sanity check.
`0: #phongFrag
