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

/ ── Per-frame: rotate + zoom + pan, recompute flat normals, interleave ────────
swFrame: {[ca;sa;xca;xsa;zoom;cx;cz]
  col: +swBase; xs: col@0; ys: col@1; zs: col@2
  x1: (ca*xs)-(sa*zs); z1: (sa*xs)+(ca*zs)                 / rotate Y
  y2: (xca*ys)-(xsa*z1); z2: (xsa*ys)+(xca*z1)             / tilt X
  Pv: +((zoom*x1-cx); (zoom*y2); (zoom*z2-cz))             / zoom + pan  (soup×3)
  i0: 3*!swNT
  pa: +Pv@i0; pb: +Pv@i0+1; pc: +Pv@i0+2
  e1x: (pb@0)-(pa@0); e1y: (pb@1)-(pa@1); e1z: (pb@2)-(pa@2)
  e2x: (pc@0)-(pa@0); e2y: (pc@1)-(pa@1); e2z: (pc@2)-(pa@2)
  nx: (e1y*e2z)-(e1z*e2y); ny: (e1z*e2x)-(e1x*e2z); nz: (e1x*e2y)-(e1y*e2x)
  ln: sqrt 1e-9+(nx*nx)+(ny*ny)+(nz*nz)
  Ntri: +((nx%ln); (ny%ln); (nz%ln))
  Nsoup: Ntri@(!3*swNT) div 3                              / flat per-triangle normal
  ,/Pv,'Nsoup,'swMrep
}

/ ── Global state ──────────────────────────────────────────────────────────────
cam:: CamAt[0.92;0.39;0.97;0.26]                          / start at a 3/4 view
swHandle:: 0

/ ── Window loop ───────────────────────────────────────────────────────────────
RunWindow[{[props]
  $[swHandle=0; swHandle:: CompileMesh[pbrVtx; PbrFragment]; 0]

  / Fold one frame of input into the orbit camera, then read its pose
  cam:: CamUpdate[cam; props]
  ca: cam`rotCa; sa: cam`rotSa; xca: cam`xCa; xsa: cam`xSa
  zoom: cam`zoom; camX: cam`camX; camZ: cam`camZ

  / Sword mesh (all per-vertex work vectorised in swFrame)
  tvs: swFrame[ca;sa;xca;xsa;zoom;camX;camZ]
  DrawMesh[tvs; swHandle]
}; 0]
