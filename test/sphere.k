/ test/sphere.k — icosahedron sphere with Phong shading via vertex+fragment SPIR-V
/
/ An icosahedron tesselated to approximate a sphere, rendered with Phong shading.
/ Each vertex carries a position and a normal (normalised position for a unit sphere).
/
/ TODO: requires vertex shader support in spirv.k (not yet implemented).
/ See test/planes.k for the planned API.
/
/ Run: zig build gpu && ink test/sphere.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ Golden ratio and icosahedron vertex coordinates (unit sphere).
phi: (1.0+sqrt[5.0])*0.5
invLen: 1.0%sqrt[1.0+(phi*phi)]

/ 12 icosahedron vertices, normalised (= normals for a smooth sphere).
icoVerts: (
   0.        invLen      phi*invLen    / 0
   0.        invLen  0-  phi*invLen    / 1
   0.    0-  invLen      phi*invLen    / 2
   0.    0-  invLen  0-  phi*invLen    / 3
   invLen      phi*invLen  0.          / 4
   invLen  0-  phi*invLen  0.          / 5
  0-invLen      phi*invLen  0.         / 6
  0-invLen  0-  phi*invLen  0.         / 7
   phi*invLen  0.      invLen          / 8
   phi*invLen  0.  0-  invLen          / 9
  0-phi*invLen  0.      invLen         / 10
  0-phi*invLen  0.  0-  invLen)        / 11

/ 20 faces (each a triple of vertex indices into icoVerts).
icoFaces: (
  0 2  8;  0  8 4;  0  4  6;  0  6 10;  0 10  2;
  3 1  9;  3  9 5;  3  5 11;  3 11  7;  3  7  1;
  2 10  7; 10  6 11;  6  4  1;  4  8  9;  8  2  5;
  7 11  1; 11  5  9;  5  1  4;  9  4  8;  2  7  5)

/ Build flat [x y z nx ny nz ...] vertex array (position = normal for unit sphere).
/ icoVerts is flat [x0 y0 z0 x1 y1 z1 ...] — extract 3 floats per vertex with (3*i)+!3.
icoMesh: ,/ {[f] v0:icoVerts[(3*f[0])+!3]; v1:icoVerts[(3*f[1])+!3]; v2:icoVerts[(3*f[2])+!3]; (v0,v0),(v1,v1),(v2,v2)}' icoFaces

/ Phong fragment shader — same as planes.k, normals from vertex stage.
phongFrag: FragmentShader[`nor`out!`v3`v4; {[nor]
  amb: 0.1
  ld: normalize[(0.5; 1.0; 0.3)]
  spec: normalize[(0.5; 1.0; 0.8)]
  diff: smoothstep[0.0; 0.05; dot[nor; ld]]
  hi: smoothstep[0.92; 0.98; dot[normalize[nor+spec]; nor]]
  base: (0.2; 0.5; 0.9)
  col: (base[0]*(amb+diff)+hi; base[1]*(amb+diff)+hi; base[2]*(amb+diff)+hi; 1.0)
  col}]

/ TODO: VertexShader + DrawMesh once vertex stage is supported.
`0 0: $#phongFrag
