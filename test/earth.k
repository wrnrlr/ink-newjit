/ A texture-mapped 3D Earth (PBR-ish, equirectangular UV)
/ Textures from https://www.solarsystemscope.com/textures/
/
/ An icosphere (icosahedron subdivided 4× → 5120 triangles) sampled from five
/ equirectangular maps: day, night lights, clouds, a specular (ocean) mask and a
/ tangent-space normal map.  Each vertex carries a UV computed from its position
/ (longitude = `atan2@(z;x), latitude = `asin@y) and the fragment shader samples
/ the maps per pixel, so continents stay sharp however coarse the mesh is.
/
/ Uses the SPIR-V texture path: gpuTexture uploads each image (lib/gpu.k texture.upload),
/ shader.fragmentTexN samples them with sample[k;uv] (lib/spirv.k), mesh.drawGeomT binds
/ them at @group(1).  The mesh + textures upload ONCE; each frame ships only a
/ 12-float uniform (orientation + zoom + cloud toggle).
/
/ Controls (self-contained — no camera module):
/   Left-drag   — spin the globe (it follows the cursor); pitch is clamped so it
/                 never flips over the poles
/   Scroll      — zoom (orthographic; the globe never clips out)
/   1           — toggle the cloud layer
/
/ The sun is fixed in view space, so the hemisphere facing you is always the lit
/ one; rotating spins the geography under it.
/
/ Run: zig build gpu && ink test/earth.k

2: "lib/dye.k"
2: "lib/gpu.k"

PI: 3.14159265

/ texture.upload resolution: "2k" (fast start) or "8k" (sharp when zoomed in, heavier).
TEXRES: "2k"

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
icoTris: sphSubAll[icoTris]                     / 5120 → 20480 (smooth limb; raze is O(n) now)

/ ── Textures: day, night, clouds, specular mask, normal map ───────────────────
pfx:       "test/data/",TEXRES,"_earth_"
imgDay:    image.read pfx,"daymap.jpg"
imgNight:  image.read pfx,"nightmap.jpg"
imgClouds: image.read pfx,"clouds.jpg"
imgSpec:   image.read pfx,"specular_map.tif"   / ocean=white, land=black
imgNorm:   image.read pfx,"normal_map.tif"     / tangent-space bumps
imgStars:  image.read "test/data/",TEXRES,"_stars_milky_way.jpg"   / celestial sky

/ ── Per-vertex UV (equirectangular), one vectorised pass ──────────────────────
P: +,/icoTris
X: P[0]; Y: P[1]; Z: P[2]
Yc: -1.0|1.0&Y                                  / clamp for asin (avoid pole NaN)
u:  0.5-(`atan2@(Z;X))%(2.*PI)                  / longitude → u (0..1)
v:  0.5-(`asin@Yc)%PI                           / latitude  → v (north at top)

/ Fix the ±180° seam: a triangle straddling u=0/1 would interpolate its UV across
/ the whole map backwards (a zig-zag scar down the Pacific).  Push each such
/ triangle's low-u corners past 1 so the UV stays continuous (sampler u-repeat).
n:   (#u)%3
idx: 3*!n
c0:  u@idx; c1: u@idx+1; c2: u@idx+2
seam: 0.5 < (c0|c1|c2)-(c0&c1&c2)
c0f: c0+(seam&(c0<0.5)); c1f: c1+(seam&(c1<0.5)); c2f: c2+(seam&(c2<0.5))
us:  ,/+(c0f;c1f;c2f)

/ Vertex layout: pos(3) nor(3) uv(2), stride 8. Position = normal on the sphere.
earthMesh: ,/ +(X;Y;Z;X;Y;Z;us;v)

/ ── Vertex shader: orbit (yaw+pitch) then orthographic ────────────────────────
/ Uniforms: uRot=(cosYaw;sinYaw;cosPitch;sinPitch)  uView=(zoom;_;_;aspect)
/ uFlag=(cloudsOn;_;_;_)  uSun=(Lx;Ly;Lz;_) view-space sun direction.  The globe
/ is rotated yaw-about-Y then pitch-about-X; the camera looks down -Z ortho so
/ depth is independent of zoom (the globe never clips out).  Normal + east tangent
/ get the same rotation for a consistent lighting/bump frame.  The sun rides
/ through unrotated (it lives in view space, set by the arrow keys → arrows move
/ the day, camera moves the view).  Varyings: wNor, wTan, wUvF=(u;v;cloudsOn), wSun.
earthVtx: shader.vertexU[[pos:`v3;nor:`v3;uv:`v2]; [wNor:`v3;wTan:`v3;wUvF:`v3;wSun:`v3]; `uRot`uView`uFlag`uSun; {[pos;nor;uv]
  yc:uRot[0]; ys:uRot[1]; pc:uRot[2]; ps:uRot[3]
  zoom:uView[0]; asp:uView[3]
  / rotate position: yaw about Y, then pitch about X
  rx:(yc*pos[0])+(ys*pos[2]); rz:(yc*pos[2])-(ys*pos[0])
  wx:rx; wy:(pc*pos[1])-(ps*rz); wz:(ps*pos[1])+(pc*rz)
  / rotate normal the same way
  mrx:(yc*nor[0])+(ys*nor[2]); mrz:(yc*nor[2])-(ys*nor[0])
  nwx:mrx; nwy:(pc*nor[1])-(ps*mrz); nwz:(ps*nor[1])+(pc*mrz)
  / east tangent = normalize(cross(nor,(0,1,0))) = (nor.z;0;-nor.x), then rotated
  t0x:nor[2]; t0z:0.0-nor[0]
  til:1.0%sqrt[(t0x*t0x)+(t0z*t0z)+0.0001]
  Tx:t0x*til; Tz:t0z*til
  trx:(yc*Tx)+(ys*Tz); trz:(yc*Tz)-(ys*Tx)
  twx:trx; twy:0.0-(ps*trz); twz:pc*trz
  / orthographic: zoom scales screen XY; depth from wz only → no zoom clipping
  ((asp*zoom*wx; zoom*wy; 0.5-0.45*wz; 1.0); (nwx;nwy;nwz); (twx;twy;twz); (uv[0];uv[1];uFlag[0]); (uSun[0];uSun[1];uSun[2]))
}]

/ ── Fragment shader: PBR-ish earth — bump + specular + day/night + clouds ──────
/ Textures: 0 day, 1 night lights, 2 clouds, 3 specular mask, 4 normal map.
/ The normal map perturbs the surface normal in tangent space (T=wTan, B=N×T) so
/ relief catches light near the terminator.  Sun L is fixed toward the viewer, so
/ the facing hemisphere is lit; N·L drives a soft terminator (shaded day over
/ night city lights); the specular mask gates an ocean sun-glint; clouds (white)
/ overlay both, lit by the sun and toggled by wUvF.z.  Output is clamped so the
/ glint/lights can't blow out to a white seam.
earthFrag: shader.fragmentTexN[[wNor:`v3; wTan:`v3; wUvF:`v3; wSun:`v3; out:`v4]; 5; {[wNor;wTan;wUvF;wSun]
  uv:    (wUvF[0]; wUvF[1])
  flag:  wUvF[2]
  day:   sample[0; uv]
  night: sample[1; uv]
  cloud: sample[2; uv]
  specM: sample[3; uv]
  nmap:  sample[4; uv]
  / bump: decode tangent-space normal, transform to world with the T,B,N frame
  N0: normalize wNor
  T:  normalize wTan
  B:  cross[N0; T]
  nx: 2.0*nmap[0]-1.0; ny: 1.0-2.0*nmap[1]; nz: 2.0*nmap[2]-1.0
  N:  normalize[(nz*N0)+(0.85*((nx*T)+(ny*B)))]
  L: normalize wSun                                / arrow-key sun (view space)
  Vd: 0.0 0.0 1.0
  H: normalize L+Vd
  lit:  dot[N;L]
  glit: dot[N0;L]                                  / geometric N·L (terminator, clouds)
  dayF: clamp[3.0*glit+0.4; 0.0; 1.0]
  sh:   0.32+0.85*max[0.0; lit]                    / day-side shading (ambient+diffuse)
  / ocean sun-glint from the specular mask (bright over water)
  spc: pow[max[0.0; dot[N;H]]; 50.0]*(0.04+0.7*specM[0])*max[0.0;glit]
  r0: spc+mix[night[0]; day[0]*sh; dayF]
  g0: spc+mix[night[1]; day[1]*sh; dayF]
  b0: spc+mix[night[2]; day[2]*sh; dayF]
  / clouds (grayscale in red): white, lit by the sun, gated by the toggle
  cl: cloud[0]*flag*(0.12+0.88*max[0.0;glit])
  (clamp[mix[r0;1.0;cl];0.;1.]; clamp[mix[g0;1.0;cl];0.;1.]; clamp[mix[b0;1.0;cl];0.;1.]; 1.0)
}]

/ ── Star / Milky-Way skybox ───────────────────────────────────────────────────
/ A full-screen quad at far depth: each pixel is a view ray, rotated by the same
/ yaw/pitch as the globe, converted to equirectangular UV and sampled from the sky
/ map.  So the stars turn with the earth and sit at infinity (zoom doesn't move
/ them).  Drawn before the earth, which then depth-tests in front.
starQuad: -1. -1.  1. -1.  1. 1.  -1. -1.  1. 1.  -1. 1.
STARFOV:  0.85                                   / how much sky fills the view

starVtx: shader.vertexU[[pos:`v2]; [wRay:`v2;wRot:`v4]; `uRot`uView; {[pos]
  cy:uRot[0]; sy:uRot[1]; cp:uRot[2]; sp:uRot[3]
  asp:uView[0]; fov:uView[1]
  ((pos[0]; pos[1]; 0.9999; 1.0); (pos[0]*fov%asp; pos[1]*fov); (cy;sy;cp;sp))
}]

starFrag: shader.fragmentTexN[[wRay:`v2; wRot:`v4; out:`v4]; 1; {[wRay;wRot]
  cy:wRot[0]; sy:wRot[1]; cp:wRot[2]; sp:wRot[3]
  dx:wRay[0]; dy:wRay[1]; dz:0.0-1.0
  / rotate the view ray by yaw-about-Y then pitch-about-X (same as the globe)
  rx:(cy*dx)+(sy*dz); rz:(cy*dz)-(sy*dx)
  wx:rx; wy:(cp*dy)-(sp*rz); wz:(sp*dy)+(cp*rz)
  il:1.0%sqrt[(wx*wx)+(wy*wy)+(wz*wz)]
  nx:wx*il; ny:wy*il; nz:wz*il
  u:  0.5+(atan2[nz;nx])%6.2831853
  vv: 0.5-(asin[ny])%3.14159265
  s: sample[0; (u;vv)]
  b: 1.6                                           / lift the (very dark) sky map
  (b*s[0]; b*s[1]; b*s[2]; 1.0)
}]

/ ── Controls + window loop ────────────────────────────────────────────────────
/ All state is local (no camera module):
/   Left-drag   spin the globe WITH the cursor — rotation speed = screen-pixels /
/               (window · zoom), so a point tracks the mouse at any zoom
/   Scroll      zoom (0.55 .. 30, orthographic → never clips)
/   ← →         rotate the sun (move the day / terminator; independent of the view)
/   1           toggle clouds
/ Pitch is clamped to ±80° so the globe can't flip.
PLIM:   1.40                                     / pitch clamp (~80°)
ZMIN:   0.55; ZMAX: 30.0
SUNSPD: 0.02                                     / sun radians per held frame
SUNEL:  0.40                                     / sun elevation above the view horizon

yaw::    0.6
pitch::  0.35
zoom::   0.9
sunAz::  0.6                                      / sun azimuth (arrow keys)
lastMx:: 0.; lastMy:: 0.
held:: 0; hL:: 0; hR:: 0                          / held: left-mouse, ←, →
cloudsOn:: 1.

earthHandle:: 0
earthGeom::   0
earthTex::    0
starHandle::  0
starGeom::    0
starTex::     0

window.run[{[props]
  $[earthHandle=0; earthHandle:: mesh.compile[earthVtx; earthFrag];  0]
  $[earthGeom=0;   earthGeom::   mesh.upload[earthMesh; earthHandle]; 0]
  $[0~earthTex;    earthTex::    {texture.upload x}'(imgDay;imgNight;imgClouds;imgSpec;imgNorm); 0]
  $[starHandle=0;  starHandle::  mesh.compile[starVtx; starFrag];     0]
  $[starGeom=0;    starGeom::    mesh.upload[starQuad; starHandle];   0]
  $[0~starTex;     starTex::     ,texture.upload[imgStars];                 0]

  E: props`events
  w: props`width; h: props`height
  mx: props`mx; my: props`my
  / held keys/buttons across frames (last matching down-event wins, else keep)
  mb:  (E`down)@&(`mouse=E`kind)&(0=E`code);   held:: $[#mb;  *|mb;  held]
  lk:  (E`down)@&(`key=E`kind)&(263=E`code);   hL::   $[#lk;  *|lk;  hL]
  rk:  (E`down)@&(`key=E`kind)&(262=E`code);   hR::   $[#rk;  *|rk;  hR]
  / drag → spin with the cursor (angle/pixel = ndc/pixel ÷ zoom); clamp pitch
  dx: $[held; mx-lastMx; 0.]; dy: $[held; my-lastMy; 0.]
  yaw::   yaw + (2.0*dx)%(w*zoom)
  pitch:: (0.0-PLIM)|PLIM&(pitch + (2.0*dy)%(h*zoom))
  lastMx:: mx; lastMy:: my
  / sun azimuth: arrows move the day (→ ahead, ← back)
  sunAz:: sunAz + SUNSPD*(hR-hL)
  / scroll zoom (clamped)
  sc: (E`amt)@&`scroll=E`kind
  zoom:: ZMIN|ZMAX&(zoom*(1.+0.1*$[#sc;+/sc;0.]))
  / '1' toggles clouds
  dn: (E`code)@&(`key=E`kind)&(1=E`down)
  $[#dn; $[|/49=dn; cloudsOn:: 1.-cloudsOn; 0]; 0]

  / view-space sun direction from azimuth + fixed elevation
  ce: cos SUNEL
  Lx: (sin sunAz)*ce; Ly: sin SUNEL; Lz: (cos sunAz)*ce
  asp: h%w
  / stars first (behind), then the earth depth-tests in front
  starUni: (cos yaw; sin yaw; cos pitch; sin pitch; asp;STARFOV;0.;0.)
  mesh.drawGeomT[starGeom; starUni; starTex]
  uni: (cos yaw; sin yaw; cos pitch; sin pitch; zoom;0.;0.;asp; cloudsOn;0.;0.;0.; Lx;Ly;Lz;0.)
  mesh.drawGeomT[earthGeom; uni; earthTex]
}; 0]
