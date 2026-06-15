/ test/sphere.k — icosahedron sphere with Phong shading via vertex+fragment SPIR-V
/
/ An icosahedron tesselated to approximate a sphere, rendered with Phong shading.
/ Each vertex carries a position and a normal (normalised position for a unit sphere).
/
/ Run: zig build gpu && ink test/sphere.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

phi: (1.0+sqrt[5.0])*0.5
invLen: 1.0%sqrt[1.0+(phi*phi)]

a: invLen; b: phi*invLen; na: 0.0-invLen; nb: 0.0-phi*invLen

/ 12 icosahedron vertices — must use explicit , (space-separated vars don't form arrays)
icoVerts: ,/((0.0,a,b);(0.0,a,nb);(0.0,na,b);(0.0,na,nb);(a,b,0.0);(a,nb,0.0);(na,b,0.0);(na,nb,0.0);(b,0.0,a);(b,0.0,na);(nb,0.0,a);(nb,0.0,na))

/ 20 faces — all on one line (newlines inside parens act as separators)
icoFaces: (0 2 8; 0 8 4; 0 4 6; 0 6 10; 0 10 2; 3 1 9; 3 9 5; 3 5 11; 3 11 7; 3 7 1; 2 10 7; 10 6 11; 6 4 1; 4 8 9; 8 2 5; 7 11 1; 11 5 9; 5 1 4; 9 4 8; 2 7 5)

/ Flat [x y z nx ny nz ...] vertex array (position = normal for unit sphere)
icoMesh: ,/ {[f] v0:icoVerts[(3*f[0])+!3]; v1:icoVerts[(3*f[1])+!3]; v2:icoVerts[(3*f[2])+!3]; (v0,v0),(v1,v1),(v2,v2)}' icoFaces

/ Phong diffuse fragment shader — no specular to keep it robust.
phongFrag: FragmentShader[`nor`out!`v3`v4; {[nor]
  amb: 0.1
  ld: normalize[(0.5; 1.0; 0.3)]
  diff: smoothstep[0.0; 0.05; dot[nor; ld]]
  base: (0.2; 0.5; 0.9)
  col: (base[0]*(amb+diff); base[1]*(amb+diff); base[2]*(amb+diff); 1.0)
  col}]

/ Vertex shader: 45° Y then isometric X tilt, scale 0.8.
/ Normals are rotated by the same transform so lighting stays in world space.
phongVtx: VertexShader[`pos`nor!`v3`v3; (,`vNor)!(,`v3); {[pos;nor]
  c45: 0.7071; s45: 0.7071; c30: 0.8165; s30: 0.5774; sc: 0.8
  / rotate position
  py0: (c45*pos[0])+(s45*pos[2])
  py1: pos[1]
  py2: (0.0-s45*pos[0])+(c45*pos[2])
  px0: py0
  px1: (c30*py1)+(0.0-s30*py2)
  px2: (s30*py1)+(c30*py2)
  clipPos: (sc*px0; sc*px1; 0.5+(0.0-px2*sc*0.5); 1.0)
  / rotate normal identically so lighting stays consistent
  ny0: (c45*nor[0])+(s45*nor[2])
  ny1: nor[1]
  ny2: (0.0-s45*nor[0])+(c45*nor[2])
  nx0: ny0
  nx1: (c30*ny1)+(0.0-s30*ny2)
  nx2: (s30*ny1)+(c30*ny2)
  rotNor: (nx0; nx1; nx2)
  (clipPos; rotNor)}]

meshHandle:: 0
loop: {[props]
  $[meshHandle=0; meshHandle:: CompileMesh[phongVtx; phongFrag]; 0]
  DrawMesh[icoMesh; meshHandle]}

RunWindow[loop; 0]
