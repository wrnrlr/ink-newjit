/ demo/scene.k — render-from-table: an ECS scene as a relational table.
/
/ Entities live in ONE table `ent` (id + orbit/transform + material columns),
/ built and updated with the natural k table primitives (see demo/recs.k):
/   construct   ent:[[]id:..;col:..;..]        column vectors, one shot
/   system      f:{@[x;`c;:;expr]}             whole-column amend, no per-row loop
/   tick        ent::ent{y x}/(sys1;sys2)      thread the table through systems
/   query       ent@&mask                      sub-table (cull / filter)
/
/ One sphere mesh lives in a RESIDENT storage buffer shared by every entity; the
/ per-entity transform (orbit, bob, scale, spin) and material live in a second
/ resident buffer of 5 vec4 slots per instance.  The vertex shader PULLS both by
/ gl_VertexIndex (shader.vertexPull, kk2 §5): instance = vid div NV, so N
/ entities render in ONE draw with no vertex-input state and no instancing API.
/
/ Controls: WASD pan · scroll zoom · right-drag orbit/tilt (lib/camera.k)
/ Run: zig build gpu && ink demo/scene.k

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/pbr.k"        / PbrFragment (Cook-Torrance)
2: "lib/camera.k"    / orbit camera

PI:: 3.14159265
DT:: 1.%60.

/ ── Shared sphere mesh (icosphere, model space, stride 6: pos,nor=pos) ─────────
F:: 1.618034
icoBase:: ((-1.0;F;0.0);(1.0;F;0.0);(-1.0;-F;0.0);(1.0;-F;0.0);(0.0;-1.0;F);(0.0;1.0;F);(0.0;-1.0;-F);(0.0;1.0;-F);(F;0.0;-1.0);(F;0.0;1.0);(-F;0.0;-1.0);(-F;0.0;1.0))
icoBaseF:: (0 11 5;0 5 1;0 1 7;0 7 10;0 10 11;11 10 2;5 11 4;1 5 9;7 1 8;10 7 6;3 9 4;3 4 2;3 2 6;3 6 8;3 8 9;9 8 1;4 9 5;2 4 11;6 2 10;8 6 7)
sphNorm: {[v] v*1.0%sqrt[+/v*v]}
sphMid:  {[a;b] sphNorm[0.5*a+b]}
sphSub1: {[t] a:t[0]; b:t[1]; c:t[2]; ab:sphMid[a;b]; bc:sphMid[b;c]; ca:sphMid[c;a]; ((a;ab;ca);(b;bc;ab);(c;ca;bc);(ab;bc;ca))}
sphSubAll: {[ts] ,/ sphSub1' ts}
sphFace: {[f] sphNorm' icoBase f}
sphVert: {[t] ,/ {[v] v,v}' t}          / triangle → 3 verts, each (pos , nor=pos)
icoTris0:: sphFace' icoBaseF
icoTris1:: sphSubAll icoTris0           / 20 → 80
icoTris2:: sphSubAll icoTris1           / 80 → 320
icoMesh:: ,/ sphVert' icoTris2          / flat stride-6 (pos , nor=pos)

/ ── Vertex shader: PULLED geometry + instance slots (shader.vertexPull) ────────
/ vb = the shared icosphere (stride 6: pos,nor), ib = 20 floats per instance
/ (5 vec4 slots: uModel=(spinCos;spinSin;scale;lit) uPos=(ex;ey;ez;_)
/ uCam=(ca;sa;xca;xsa) uPan=(zoom;camX;camZ;_) uMat=(r;g;b;rough)).
/ instance = vid div NV (NV = verts per sphere, baked), vertex-in-instance = the
/ remainder.  Position gets model spin+scale+translate then camera; the normal
/ gets model spin + camera rotate/tilt only (uniform scale leaves it intact).
NV:: 960.                                 / 320 tris × 3 verts (baked into the shader)
sceneVtx: shader.vertexPull[(wNor:`v3;wMat:`v4;wLit:`f32); {[vb;ib;vid]
  inst: floor[vid % NV]
  v6:   6.*vid - inst*NV
  p0:vb[v6]; p1:vb[v6+1.]; p2:vb[v6+2.]
  n0:vb[v6+3.]; n1:vb[v6+4.]; n2:vb[v6+5.]
  q: 20.*inst
  myc:ib[q]; mys:ib[q+1.]; scl:ib[q+2.]; lit:ib[q+3.]
  ex:ib[q+4.]; ey:ib[q+5.]; ez:ib[q+6.]
  ca:ib[q+8.]; sa:ib[q+9.]; xca:ib[q+10.]; xsa:ib[q+11.]
  zoom:ib[q+12.]; cx:ib[q+13.]; cz:ib[q+14.]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.3
  mx:(myc*p0)-(mys*p2); mz:(mys*p0)+(myc*p2)
  wx:(scl*mx)+ex; wy:(scl*p1)+ey; wz:(scl*mz)+ez
  x1:(ca*wx)-(sa*wz); z1:(sa*wx)+(ca*wz)
  y2:(xca*wy)-(xsa*z1); z2:(xsa*wy)+(xca*z1)
  X:(zoom*x1)-cx; Y:zoom*y2; Z:(zoom*z2)-cz
  py0:(c45*X)+(s45*Z); py2:(c45*Z)-(s45*X)
  px1:(c30*Y)-(s30*py2); px2:(s30*Y)+(c30*py2)
  mnx:(myc*n0)-(mys*n2); mnz:(mys*n0)+(myc*n2)
  nx1:(ca*mnx)-(sa*mnz); nz1:(sa*mnx)+(ca*mnz)
  ny2:(xca*n1)-(xsa*nz1); nz2:(xsa*n1)+(xca*nz1)
  ((sc*py0; sc*px1; 0.5-px2*0.05; 1.0); (nx1;ny2;nz2); (ib[q+16.];ib[q+17.];ib[q+18.];ib[q+19.]); lit)
}]

/ ── The scene table — one row per entity, built with column vectors ────────────
N:: 8
hue:: (!N)%N                                  / 0 .. 1 around the ring
th0:: (2.*PI)*hue
rad0:: N#2.3
ent:: ([]id:1+!N; theta:th0; orbit:0.5+0.7*hue; rad:rad0; phase:(2.*PI)*hue; px:rad0*cos th0; py:N#0.; pz:rad0*sin th0; scl:N#0.45; r:0.5+0.4*cos (2.*PI)*hue; g:0.5+0.4*cos (2.*PI)*(hue+0.33); b:0.5+0.4*cos (2.*PI)*(hue+0.66); rough:N#0.35)

/ ── Systems (vectorised column amends over the whole table) ────────────────────
/ orbit: advance each entity's angle, recompute its ring position
moveSys: {[x] a:(x`theta)+(x`orbit)*DT; x:@[x;`theta;:;a]; x:@[x;`px;:;(x`rad)*cos a]; x:@[x;`pz;:;(x`rad)*sin a]; x}
/ bob + scale-pulse: vertical bob (phase-offset per entity) and a breathing scale
bobSys:  {[x] th:x`theta; ph:x`phase; x:@[x;`py;:;0.6*sin((2.*th)+ph)]; x:@[x;`scl;:;0.42+0.12*sin(3.*th)]; x}

/ ── Render system: read columns → pack the n×20 instance matrix → ONE draw ─────
/ Each row is one instance's 5 vec4 slots (uModel uPos uCam uPan uMat); camera
/ columns are shared (n copies).  The whole table renders with ONE pulled draw:
/ the instance buffer is a resident storage buffer overwritten each frame, and
/ mesh.drawPull issues N*NV vertices straight from the device buffers.
renderSys: {[e]
  ca:cam`rotCa; sa:cam`rotSa; xca:cam`xCa; xsa:cam`xSa
  zoom:cam`zoom; cx:cam`camX; cz:cam`camZ
  th:e`theta; px:e`px; py:e`py; pz:e`pz; scl:e`scl
  cr:e`r; cg:e`g; cb:e`b; ro:e`rough
  n:#e`id
  c1:+(cos th; sin th; scl; n#1.)               / uModel
  c2:+(px; py; pz; n#0.)                          / uPos
  c3:n#,(ca,sa,xca,xsa)                           / uCam   (shared)
  c4:n#,(zoom,cx,cz,0.)                           / uPan   (shared)
  c5:+(cr; cg; cb; ro)                            / uMat
  unis:c1,'c2,'c3,'c4,'c5                          / n×20
  gpu.write[sceneInst; ,/unis]                    / refresh the instance slots
  mesh.drawPull[scenePipe; (sceneVB;sceneInst); n*`i$NV]   / one draw, N*NV verts
  e}

/ ── Window loop ───────────────────────────────────────────────────────────────
cam:: CamAt[0.92;0.39;0.97;0.26]                 / a 3/4 view
scenePipe:: 0                                     / pulled pipeline (compiled once)
sceneVB::   0                                     / resident icosphere buffer
sceneInst:: 0                                     / resident instance-slot buffer

window.run[{[props]
  $[scenePipe=0; scenePipe:: mesh.compilePull[sceneVtx; PbrFragment]; 0]
  $[sceneVB=0;   sceneVB::   gpu.buffer[icoMesh]; 0]        / upload sphere once
  $[sceneInst=0; sceneInst:: gpu.buffer[(N*20)#0.]; 0]      / instance slots
  cam:: CamUpdate[cam; props]
  ent:: ent{y x}/(moveSys;bobSys)                / tick the simulation systems
  renderSys ent                                  / one pulled draw of the whole table
}; 0]
