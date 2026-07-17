/ test/vpulltri.k — vertex pulling smoke test (kk2 §5): a single triangle whose
/ clip-space positions live in a RESIDENT storage buffer, read by the vertex shader
/ at gl_VertexIndex — no vertex buffer, no per-frame upload. Snapshot to verify.
/ Run:  ink test/vpulltri.k   (INK_SNAP=1 writes vpulltri-snap.png)

2: "lib/dye.k"
2: "lib/gpu.k"

/ vertex-pull: pos[3*vid .. +2] → gl_Position (clip space, w=1), plus a per-vertex
/ colour varying (here derived from vid so the three corners differ).
vpull:: shader.vertexPull[[wc:`v3]; {[pos; vid] i:3.*vid
  ((pos[i]; pos[i+1.]; pos[i+2.]; 1.); (0.9; 0.5*vid; 0.2))}]
/ fragment reads the interpolated colour varying
fsolid:: shader.fragment[[wc:`v3; out:`v4]; {[wc] (wc[0]; wc[1]; wc[2]; 1.)}]

/ one triangle, 3 verts × (x;y;z) in clip space (z=0)
tri:: 0. 0.6 0.  -0.6 -0.5 0.  0.6 -0.5 0.

gPipe::0; gBuf::0
loop::{[props]
  $[gPipe=0; gPipe::mesh.compilePull[vpull; fsolid]; 0]
  $[gBuf=0;  gBuf::gpu.buffer[tri]; 0]
  mesh.drawPull[gPipe; ,gBuf; 3]}
window.run[loop; 0]
