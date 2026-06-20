/ test/planes.k — three intersecting coordinate planes, combinatorially generated
/
/ Each axis-aligned plane is generated from its unit normal by cyclic tangent
/ rotation: for n=(a,b,c), tangents are t1=(b,c,a) and t2=(c,a,b).  The four
/ corners of each unit square are ±t1 ± t2.
/
/ Camera: 45° Y-rotation then isometric X-tilt (arctan 1/√2 ≈ 35.26°) so all
/ three planes appear as equal rhombuses forming a 6-pointed star.
/
/ Run: zig build gpu && ink test/planes.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ Generate a unit square for a plane with given unit normal n=(n0;n1;n2).
/ Corners are ±t1 ± t2, each vertex = [px py pz nx ny nz].
/ Returns 36-element float list (6 vertices × 6 floats, two triangles).
mkPlane: {[n]
  t1x:n 1; t1y:n 2; t1z:n 0
  t2x:n 2; t2y:n 0; t2z:n 1
  v0:(t1x+t2x;t1y+t2y;t1z+t2z),n
  v1:(t2x-t1x;t2y-t1y;t2z-t1z),n
  v2:((-t1x)-t2x;(-t1y)-t2y;(-t1z)-t2z),n
  v3:(t1x-t2x;t1y-t2y;t1z-t2z),n
  (v0,v1,v2),(v0,v2,v3)
}

verts: ,/ mkPlane'1.0*=3

/ Fragment shader: color by world-space normal (R=YZ, G=XZ, B=XY).
frag: FragmentShader[[nor:`v3; out:`v4]; {[nor]
  amb: 0.15
  ld: normalize[(0.6; 0.8; 0.4)]
  br: amb+smoothstep[0.0;0.1;dot[nor;ld]]
  (nor[0]*br; nor[1]*br; nor[2]*br; 1.0)
}]

/ Vertex shader: 45° Y-rotation then isometric X-tilt, scale by 0.5.
/ c30=cos(35.26°)=√(2/3), s30=sin(35.26°)=1/√3 — equal rhombuses for all planes.
vert: VertexShader[[pos:`v3;nor:`v3]; [vNor:`v3]; {[pos;nor]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.5
  py0: (c45*pos[0])+(s45*pos[2])
  py2: (c45*pos[2])-(s45*pos[0])
  px1: (c30*pos[1])-(s30*py2)
  px2: (s30*pos[1])+(c30*py2)
  ((sc*py0; sc*px1; 0.5-px2*sc*0.5; 1.0); nor)
}]

handle:: 0
RunWindow[{[props]
  $[handle=0; handle:: CompileMesh[vert; frag]; 0]
  DrawMesh[verts; handle]
}; 0]
