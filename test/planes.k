/ test/planes.k — intersecting planes with Phong shading via vertex+fragment SPIR-V
/
/ Three intersecting rectangular planes rendered with a Phong lighting model.
/ Geometry: two quads per plane (triangulated), normals per vertex.
/ Camera: 45° around Y then 30° around X so all three planes are visible.
/ Colors: XY=blue, XZ=green, YZ=red (driven by world-space normal in fragment shader).
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

/ Fragment shader: color each plane by its world-space normal (R=YZ, G=XZ, B=XY)
/ with Phong diffuse modulation.
phongFrag: FragmentShader[`nor`out!`v3`v4; {[nor]
  amb: 0.15
  ld: normalize[(0.6; 0.8; 0.4)]
  diff: smoothstep[0.0; 0.1; dot[nor; ld]]
  br: amb+diff
  (nor[0]*br; nor[1]*br; nor[2]*br; 1.0)}]

/ Vertex shader: rotate scene (45° Y, 30° X) so all three planes are visible,
/ pass world-space normal through unchanged for lighting.
/ WebGPU depth: z=0 is near, z=1 is far; negate z so front face wins depth test.
phongVtx: VertexShader[`pos`nor!`v3`v3; (,`vNor)!(,`v3); {[pos;nor]
  c45: 0.7071; s45: 0.7071; c30: 0.8165; s30: 0.5774; sc: 0.5;
  py0: (c45*pos[0])+(s45*pos[2])
  py1: pos[1]
  py2: (0.0-s45*pos[0])+(c45*pos[2])
  px0: py0
  px1: (c30*py1)+(0.0-s30*py2)
  px2: (s30*py1)+(c30*py2)
  clipPos: (sc*px0; sc*px1; 0.5+(0.0-px2*sc*0.5); 1.0)
  (clipPos; nor)}]

/ Render loop
meshHandle:: 0
loop: {[props]
  $[meshHandle=0; meshHandle:: CompileMesh[phongVtx; phongFrag]; 0]
  DrawMesh[verts; meshHandle]}

RunWindow[loop; 0]
