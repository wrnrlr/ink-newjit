/ test/sword.k — load a binary FBX model (lib/fbx.k) and render just the mesh.
/
/ The mesh comes from data/FBX/Sword.fbx: ReadFbx → fbx.trimesh gives a
/ (positions; triangles) pair, which is centred, scaled and flat-shaded into
/ the pbr vertex layout (stride 11: x y z  nx ny nz  r g b rough  lit).
/ All per-frame work (rotation, zoom, pan, normal recompute) is vectorised
/ over the whole mesh — no per-vertex loop.
/
/ Controls:
/   WASD           — pan camera
/   Scroll         — zoom in/out
/   Right-drag X   — rotate scene (Y-axis)
/   Right-drag Y   — tilt scene (X-axis)
/
/ Run: zig build gpu && ink test/sword.k

2: "lib/spirv.k"
2: "lib/gpu.k"
2: "lib/fbx.k"
2: "lib/pbr.k"      / shared PBR renderer: pbrVtx + PbrFragment
2: "lib/camera.k"  / orbit camera (WASD pan, scroll zoom, right-drag rotate)

/ ── Material (r g b roughness) ────────────────────────────────────────────────
steel:: 0.62 0.64 0.68 0.35

/ ── Load the FBX mesh once and bake it into model space ───────────────────────
fbxMesh: {[path]
  t: ReadFbx path
  obj: *t@&({$[(x`name)~`Objects;1;0]}'t)
  geo: fbx.get[obj;`Geometry]
  `0 0:"loaded ",(fbx.uname (geo`props)@1)
  m: fbx.trimesh geo
  soup: (m@0)@,/m@1                 / triangle-soup positions (3 per triangle)
  col: +soup; xs: col@0; ys: col@1; zs: col@2
  cx: 0.5*(&/xs)+(|/xs); cy: 0.5*(&/ys)+(|/ys); cz: 0.5*(&/zs)+(|/zs)   / centre
  sca: 2.4%|/(((|/xs)-(&/xs));((|/ys)-(&/ys));((|/zs)-(&/zs)))
  +((sca*xs-cx); (sca*ys-cy); (sca*zs-cz))                              / centred/scaled soup×3
}
swBase:: fbxMesh "data/FBX/Sword.fbx"
swNT::   (#swBase) div 3                                   / triangle count
swMrep:: (#swBase) # ,steel,1.0                            / per-vertex (mat;lit)

/ ── Static mesh, built once in MODEL space ────────────────────────────────────
/ Flat per-triangle normals are computed in model space; the vertex shader rotates
/ both position and normal each frame, so the mesh uploads once and never changes.
swModelMesh: {[]
  i0: 3*!swNT
  pa: +swBase@i0; pb: +swBase@(i0+1); pc: +swBase@(i0+2)
  e1x: (pb@0)-(pa@0); e1y: (pb@1)-(pa@1); e1z: (pb@2)-(pa@2)
  e2x: (pc@0)-(pa@0); e2y: (pc@1)-(pa@1); e2z: (pc@2)-(pa@2)
  nx: (e1y*e2z)-(e1z*e2y); ny: (e1z*e2x)-(e1x*e2z); nz: (e1x*e2y)-(e1y*e2x)
  ln: sqrt 1e-9+(nx*nx)+(ny*ny)+(nz*nz)
  Ntri: +((nx%ln); (ny%ln); (nz%ln))
  Nsoup: Ntri@(!3*swNT) div 3                              / flat per-triangle normal
  ,/swBase,'Nsoup,'swMrep
}
swStatic:: swModelMesh[]

/ ── Vertex shader: rotate (Y then X) + zoom + pan + iso projection, all on GPU ─
/ Camera pose arrives as uniforms: uCam = (ca;sa;xca;xsa), uPan = (zoom;cx;cz;_).
/ The position gets zoom+pan; the normal gets the same rotation only (lit in the
/ rotated camera space, matching lib/pbr.k's fixed light directions).
swVtx: VertexShaderU[[pos:`v3;nor:`v3;mat:`v4;lit:`f32]; [wNor:`v3;wMat:`v4;wLit:`f32]; `uCam`uPan; {[pos;nor;mat;lit]
  ca:uCam[0]; sa:uCam[1]; xca:uCam[2]; xsa:uCam[3]
  zoom:uPan[0]; cx:uPan[1]; cz:uPan[2]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.3
  x1:(ca*pos[0])-(sa*pos[2]); z1:(sa*pos[0])+(ca*pos[2])   / rotate Y
  y2:(xca*pos[1])-(xsa*z1); z2:(xsa*pos[1])+(xca*z1)       / tilt X
  X:(zoom*x1)-cx; Y:zoom*y2; Z:(zoom*z2)-cz                / zoom + pan
  py0:(c45*X)+(s45*Z); py2:(c45*Z)-(s45*X)
  px1:(c30*Y)-(s30*py2); px2:(s30*Y)+(c30*py2)
  nx1:(ca*nor[0])-(sa*nor[2]); nz1:(sa*nor[0])+(ca*nor[2]) / rotate normal Y
  ny2:(xca*nor[1])-(xsa*nz1); nz2:(xsa*nor[1])+(xca*nz1)   / tilt normal X
  ((sc*py0; sc*px1; 0.5-px2*0.001; 1.0); (nx1;ny2;nz2); mat; lit)
}]

/ ── Global state ──────────────────────────────────────────────────────────────
cam:: CamAt[0.92;0.39;0.97;0.26]                          / start at a 3/4 view
swHandle:: 0

/ ── Window loop ───────────────────────────────────────────────────────────────
RunWindow[{[props]
  $[swHandle=0; swHandle:: CompileMesh[swVtx; PbrFragment]; 0]

  / Fold one frame of input into the orbit camera, then pack its pose as uniforms
  cam:: CamUpdate[cam; props]
  ca: cam`rotCa; sa: cam`rotSa; xca: cam`xCa; xsa: cam`xSa
  zoom: cam`zoom; cx: cam`camX; cz: cam`camZ
  uni: ca,sa,xca,xsa,zoom,cx,cz,0.

  / Static mesh uploads once; the GPU rotates it via the uniform camera pose
  DrawMeshU[swStatic; swHandle; uni]
}; 0]
