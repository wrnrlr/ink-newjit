/ test/sphere.k — icosphere with Phong shading via vertex+fragment SPIR-V
/
/ Starts from the base icosahedron, subdivides 3× (20→1280 triangles) by
/ splitting each edge at its spherical midpoint, giving a smooth geodesic sphere.
/ Each vertex position equals its unit normal, so Phong shading is smooth.
/
/ Run: zig build gpu && ink test/sphere.k

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/pbr.k"   / shared PBR renderer: PbrFragment (Cook-Torrance)

/ Golden ratio — icosahedron edge lengths are 1 and φ
F: 1.618034

/ 12 base icosahedron vertices (unnormalized)
icoBase: ((-1.0;F;0.0);(1.0;F;0.0);(-1.0;-F;0.0)
          (1.0;-F;0.0);(0.0;-1.0;F);(0.0;1.0;F)
          (0.0;-1.0;-F);(0.0;1.0;-F);(F;0.0;-1.0)
          (F;0.0;1.0);(-F;0.0;-1.0);(-F;0.0;1.0))

/ 20 base faces
icoBaseF: (
  0 11 5; 0 5 1; 0 1 7; 0 7 10; 0 10 11
  11 10 2; 5 11 4; 1 5 9; 7 1 8; 10 7 6
  3 9 4; 3 4 2; 3 2 6; 3 6 8; 3 8 9
  9 8 1; 4 9 5; 2 4 11; 6 2 10; 8 6 7)

/ Project a 3-vector onto the unit sphere
sphNorm: {[v] v*1.0%sqrt[+/v*v]}

/ Spherical midpoint of two unit-sphere vertices (normalize the Euclidean midpoint)
sphMid: {[a;b] sphNorm[0.5*a+b]}

/ Split one triangle into 4 by inserting spherical edge midpoints
sphSub1: {[t]
  a:t[0]; b:t[1]; c:t[2]
  ab:sphMid[a;b]; bc:sphMid[b;c]; ca:sphMid[c;a]
  ((a;ab;ca);(b;bc;ab);(c;ca;bc);(ab;bc;ca))}

/ One full subdivision pass
sphSubAll: {[ts] ,/ sphSub1' ts}

/ Build initial triangle list, normalizing base vertices onto unit sphere
sphFace: {[f] sphNorm'icoBase f}
icoTris: sphFace' icoBaseF

/ 3 rounds of subdivision: 20 → 80 → 320 → 1280 triangles
icoTris: sphSubAll[icoTris]
icoTris: sphSubAll[icoTris]
icoTris: sphSubAll[icoTris]

/ Material (r g b roughness sun) — smooth blue, fully lit
sphMat: 0.25 0.55 0.9 0.35 1.

/ Flatten to the lib/pbr.k vertex layout (stride 11): pos(3) nor(3) mat(4) lit(1).
/ Position equals normal on the unit sphere, so shading is smooth.
sphVert: {[t] ,/{[v]v,v,sphMat}'t}
icoMesh: ,/ sphVert' icoTris

/ Vertex shader: 45° Y + isometric X tilt; rotates the normal by the same matrix
/ in-shader (no CPU normal pass), then emits the standard wNor;wMat;wLit varyings
/ so lib/pbr.k's PbrFragment shades it.
/ Vertex pulling: geometry (stride 11) lives in a resident buffer, read at 11*vid.
sphereVtx: shader.vertexPull[[wNor:`v3;wMat:`v4;wLit:`f32]; {[vb;vid]
  b:11.*vid
  px:vb[b]; py:vb[b+1.]; pz:vb[b+2.]
  nx:vb[b+3.]; ny:vb[b+4.]; nz:vb[b+5.]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.8
  py0: (c45*px)+(s45*pz)
  py2: (c45*pz)-(s45*px)
  px1: (c30*py)-(s30*py2)
  px2: (s30*py)+(c30*py2)
  ny0: (c45*nx)+(s45*nz)
  ny2: (c45*nz)-(s45*nx)
  nx1: (c30*ny)-(s30*ny2)
  nx2: (s30*ny)+(c30*ny2)
  ((sc*py0; sc*px1; 0.5-px2*sc*0.5; 1.0); (ny0;nx1;nx2); (vb[b+6.];vb[b+7.];vb[b+8.];vb[b+9.]); vb[b+10.])
}]

meshPipe:: 0
meshVB::   0
meshN::    (#icoMesh) div 11
loop: {[props]
  $[meshPipe=0; meshPipe:: mesh.compilePull[sphereVtx; PbrFragment]; 0]
  $[meshVB=0;   meshVB::   gpu.buffer[icoMesh]; 0]
  mesh.drawPull[meshPipe; ,meshVB; meshN]}

window.run[loop; 0]
