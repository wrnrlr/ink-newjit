/ test/sphere.k — icosphere with Phong shading via vertex+fragment SPIR-V
/
/ Starts from the base icosahedron, subdivides 3× (20→1280 triangles) by
/ splitting each edge at its spherical midpoint, giving a smooth geodesic sphere.
/ Each vertex position equals its unit normal, so Phong shading is smooth.
/
/ Run: zig build gpu && ink test/sphere.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ Golden ratio — icosahedron edge lengths are 1 and φ
F: 1.618034

/ 12 base icosahedron vertices (unnormalized) — ONE LINE (newlines inside parens
/ act as extra list separators in ink, so all vertices must fit on one line)
icoBase: ((-1.0;F;0.0);(1.0;F;0.0);(-1.0;-F;0.0)
          (1.0;-F;0.0);(0.0;-1.0;F);(0.0;1.0;F)
          (0.0;-1.0;-F);(0.0;1.0;-F);(F;0.0;-1.0)
          (F;0.0;1.0);(-F;0.0;-1.0);(-F;0.0;1.0))

/ 20 base faces — ONE LINE for same reason
icoBaseF: (0 11 5;0 5 1;0 1 7;0 7 10;0 10 11;11 10 2;5 11 4;1 5 9;7 1 8;10 7 6;3 9 4;3 4 2;3 2 6;3 6 8;3 8 9;9 8 1;4 9 5;2 4 11;6 2 10;8 6 7)

/ Project a 3-vector onto the unit sphere
sphNorm: {[v] s:1.0%sqrt[(v[0]*v[0])+(v[1]*v[1])+(v[2]*v[2])]; (v[0]*s;v[1]*s;v[2]*s)}

/ Spherical midpoint of two unit-sphere vertices (normalize the Euclidean midpoint)
sphMid: {[a;b] sphNorm[((a[0]+b[0])*0.5;(a[1]+b[1])*0.5;(a[2]+b[2])*0.5)]}

/ Split one triangle into 4 by inserting spherical edge midpoints
sphSub1: {[t] a:t[0]; b:t[1]; c:t[2]; ab:sphMid[a;b]; bc:sphMid[b;c]; ca:sphMid[c;a]; ((a;ab;ca);(b;bc;ab);(c;ca;bc);(ab;bc;ca))}

/ One full subdivision pass
sphSubAll: {[ts] ,/ sphSub1' ts}

/ Build initial triangle list, normalizing base vertices onto unit sphere
sphFace: {[f] (sphNorm[icoBase[f[0]]];sphNorm[icoBase[f[1]]];sphNorm[icoBase[f[2]]])}
icoTris: sphFace' icoBaseF

/ 3 rounds of subdivision: 20 → 80 → 320 → 1280 triangles
icoTris: sphSubAll[icoTris]
icoTris: sphSubAll[icoTris]
icoTris: sphSubAll[icoTris]

/ Flatten to [x y z nx ny nz ...] strip — position equals normal for unit sphere
sphVert: {[t] v0:t[0]; v1:t[1]; v2:t[2]; (v0,v0),(v1,v1),(v2,v2)}
icoMesh: ,/ sphVert' icoTris

/ Blinn-Phong fragment shader.
/ Light direction ld and half-vector h are constants (safe, no NaN risk).
/ h = normalize(ld + viewDir) where viewDir=(0,0,1) in rotated screen space.
phongFrag: FragmentShader[`nor`out!`v3`v4; {[nor]
  ld: normalize[(0.5;1.0;0.3)]
  h: normalize[(0.5;1.0;1.3)]
  amb: 0.08
  diff: max[0.0;dot[nor;ld]]
  spec: pow[max[0.0;dot[nor;h]];64.0]
  base: (0.25;0.55;0.9)
  lit: amb+diff
  (base[0]*lit+spec;base[1]*lit+spec;base[2]*lit+spec;1.0)}]

/ Vertex shader: 45° Y + isometric X tilt; rotate normals by the same matrix
phongVtx: VertexShader[`pos`nor!`v3`v3;(,`vNor)!(,`v3);{[pos;nor]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.8
  py0:(c45*pos[0])+(s45*pos[2])
  py1:pos[1]
  py2:(0.0-s45*pos[0])+(c45*pos[2])
  px0:py0
  px1:(c30*py1)+(0.0-s30*py2)
  px2:(s30*py1)+(c30*py2)
  clipPos:(sc*px0;sc*px1;0.5+(0.0-px2*sc*0.5);1.0)
  ny0:(c45*nor[0])+(s45*nor[2])
  ny1:nor[1]
  ny2:(0.0-s45*nor[0])+(c45*nor[2])
  nx0:ny0
  nx1:(c30*ny1)+(0.0-s30*ny2)
  nx2:(s30*ny1)+(c30*ny2)
  (clipPos;(nx0;nx1;nx2))}]

meshHandle:: 0
loop: {[props]
  $[meshHandle=0; meshHandle:: CompileMesh[phongVtx; phongFrag]; 0]
  DrawMesh[icoMesh; meshHandle]}

RunWindow[loop; 0]
