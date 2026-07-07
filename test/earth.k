/ test/earth.k — a texture-mapped 3D Earth (PBR-ish, equirectangular UV)
/
/ An icosphere (icosahedron subdivided 4× → 5120 triangles) sampled from an
/ equirectangular Earth day-map. Each vertex carries a UV computed from its
/ position — longitude = `atan2@(z;x), latitude = `asin@y — and the fragment
/ shader samples the map at that UV per pixel, so continents stay sharp no matter
/ how coarse the mesh is (the geometry only has to be round).
/
/ This needs the SPIR-V texture path: gpuTexture uploads the image (lib/gpu.k
/ Texture), FragmentShaderTex declares a sampled texture and reads it with
/ sample[uv] (lib/spirv.k), and DrawMeshT binds it at @group(1).
/
/ `atan2 / `asin are inverse-trig helpers on the `sym@x call path
/ (src/runtime/syms.zig); they map over F vectors, so the per-vertex UV is one
/ vectorised pass, no loop.
/
/ Controls (lib/camera.k):
/   Right-drag  — spin / tilt the globe      Scroll — zoom      WASD — pan
/
/ Run: zig build gpu && ink test/earth.k
/ Snapshot: INK_SNAP=0.5 ink test/earth.k

2: "lib/spirv.k"
2: "lib/gpu.k"
2: "lib/camera.k"   / orbit camera (right-drag rotate, scroll zoom, WASD pan)

PI: 3.14159265

/ ── Icosphere geometry (see test/sphere.k) ───────────────────────────────────
F: 1.618034                              / golden ratio
icoBase: ((-1.0;F;0.0);(1.0;F;0.0);(-1.0;-F;0.0)
          (1.0;-F;0.0);(0.0;-1.0;F);(0.0;1.0;F)
          (0.0;-1.0;-F);(0.0;1.0;-F);(F;0.0;-1.0)
          (F;0.0;1.0);(-F;0.0;-1.0);(-F;0.0;1.0))
icoBaseF: (
  0 11 5; 0 5 1; 0 1 7; 0 7 10; 0 10 11
  11 10 2; 5 11 4; 1 5 9; 7 1 8; 10 7 6
  3 9 4; 3 4 2; 3 2 6; 3 6 8; 3 8 9
  9 8 1; 4 9 5; 2 4 11; 6 2 10; 8 6 7)

sphNorm: {[v] v*1.0%sqrt[+/v*v]}                / project onto the unit sphere
sphMid:  {[a;b] sphNorm[0.5*a+b]}               / spherical edge midpoint
sphSub1: {[t]                                   / split a triangle into 4
  a:t[0]; b:t[1]; c:t[2]
  ab:sphMid[a;b]; bc:sphMid[b;c]; ca:sphMid[c;a]
  ((a;ab;ca);(b;bc;ab);(c;ca;bc);(ab;bc;ca))}
sphSubAll: {[ts] ,/ sphSub1' ts}
sphFace:   {[f] sphNorm'icoBase f}

icoTris: sphFace' icoBaseF
icoTris: sphSubAll[icoTris]                     / 20 → 80
icoTris: sphSubAll[icoTris]                     / 80 → 320
icoTris: sphSubAll[icoTris]                     / 320 → 1280
icoTris: sphSubAll[icoTris]                     / 1280 → 5120

/ ── Per-vertex UV (equirectangular), one vectorised pass ──────────────────────
/ P = (X;Y;Z) columns over every triangle corner.  Longitude → u, latitude → v.
img: image.read "test/data/2k_earth_daymap.jpg"
P: +,/icoTris
X: P[0]; Y: P[1]; Z: P[2]
Yc: -1.0|1.0&Y                                  / clamp for asin (avoid pole NaN)
u:  0.5-(`atan2@(Z;X))%(2.*PI)                  / longitude → u (0..1)
v:  0.5-(`asin@Yc)%PI                           / latitude  → v (north at top)

/ Fix the ±180° seam: a triangle straddling u=0/1 would interpolate its UV across
/ the whole map backwards (a zig-zag scar down the Pacific).  Detect such
/ triangles (corner-u range > 0.5) and push their low-u corners past 1 so the UV
/ stays continuous — the sampler's u-repeat wrap then samples the right pixels.
n:   (#u)%3
idx: 3*!n                                        / corner-0 index of each triangle
c0:  u@idx; c1: u@idx+1; c2: u@idx+2
seam: 0.5 < (c0|c1|c2)-(c0&c1&c2)               / does this triangle cross the seam?
c0f: c0+(seam&(c0<0.5)); c1f: c1+(seam&(c1<0.5)); c2f: c2+(seam&(c2<0.5))
us:  ,/+(c0f;c1f;c2f)                            / re-interleave to per-corner order

/ Interleave into the vertex layout: pos(3) nor(3) uv(2), stride 8.
/ Position equals normal on the unit sphere, so shading stays smooth.
earthMesh: ,/ +(X;Y;Z;X;Y;Z;us;v)

/ ── Vertex shader: rotate by the camera (in-shader), project isometric ────────
/ Uniform slots (vec4): uCam=(ca;sa;xca;xsa)  uPan=(zoom;camX;camZ;aspect).
/ aspect = height/width squeezes clip-x so the globe stays round on any window.
earthVtx: VertexShaderU[[pos:`v3;nor:`v3;uv:`v2]; [wNor:`v3;wUv:`v2]; `uCam`uPan; {[pos;nor;uv]
  ca:uCam[0]; sa:uCam[1]; xca:uCam[2]; xsa:uCam[3]
  zoom:uPan[0]; cx:uPan[1]; cz:uPan[2]; asp:uPan[3]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.85
  x1:(ca*pos[0])-(sa*pos[2]); z1:(sa*pos[0])+(ca*pos[2])
  y2:(xca*pos[1])-(xsa*z1);   z2:(xsa*pos[1])+(xca*z1)
  Xc:(zoom*x1)-cx; Yc:zoom*y2; Zc:(zoom*z2)-cz
  py0:(c45*Xc)+(s45*Zc); py2:(c45*Zc)-(s45*Xc)
  px1:(c30*Yc)-(s30*py2); px2:(s30*Yc)+(c30*py2)
  nx1:(ca*nor[0])-(sa*nor[2]); nz1:(sa*nor[0])+(ca*nor[2])
  ny2:(xca*nor[1])-(xsa*nz1);  nz2:(xsa*nor[1])+(xca*nz1)
  ((asp*sc*py0; sc*px1; 0.5-px2*sc*0.5; 1.0); (nx1;ny2;nz2); uv)
}]

/ ── Fragment shader: sample the map, apply soft day/night lighting ────────────
/ Texture colour is sRGB already, so light it directly (no gamma) and keep a lit
/ floor so the night side stays visible instead of a hard terminator.
earthFrag: FragmentShaderTex[[wNor:`v3; wUv:`v2; out:`v4]; {[wNor;wUv]
  base: sample[wUv]
  N: normalize wNor
  L: normalize 0.6 0.5 0.55
  Vd: normalize 0.2 0.25 1.0
  H: normalize L+Vd
  nl: max[0.05; dot[N;L]]
  lit: 0.28+0.9*nl
  / Oceans (blue-dominant texels) get a sharp sun glint; land reads matte. The
  / nl factor kills the highlight on the night side (no glint without sunlight).
  ocean: clamp[(base[2]-base[0])*3.0; 0.0; 1.0]
  spc: pow[max[0.0; dot[N;H]]; 60.0]*(0.05+0.5*ocean)*nl
  (base[0]*lit+spc; base[1]*lit+spc; base[2]*lit+spc; 1.0)
}]

/ ── Window loop ──────────────────────────────────────────────────────────────
/ Start tilted a little so the globe reads as 3-D from the first frame.
cam::         CamAt[0.92; 0.39; 0.97; 0.24]
earthHandle:: 0
earthTex::    0

window.run[{[props]
  $[earthHandle=0; earthHandle:: CompileMesh[earthVtx; earthFrag]; 0]
  $[earthTex=0;    earthTex::    Texture[img];                    0]
  cam:: CamUpdate[cam; props]
  ca: cam`rotCa; sa: cam`rotSa; xca: cam`xCa; xsa: cam`xSa
  zoom: cam`zoom; camX: cam`camX; camZ: cam`camZ
  asp: (props`height)%props`width
  uni: (ca;sa;xca;xsa; zoom;camX;camZ;asp)
  DrawMeshT[earthMesh; earthHandle; uni; earthTex]
}; 0]
