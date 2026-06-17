/ test/pbr.k — PBR scene: grass-green ground plane + brown box
/
/ Cook-Torrance BRDF:
/   D = GGX NDF (Trowbridge-Reitz)
/   G = Smith GGX (Schlick approximation)
/   F = Schlick Fresnel (F0=0.04 dielectric)
/   diffuse = Lambert
/
/ Material selected in the fragment shader by world-space Y:
/   wPos[1] > 0.01  →  brown dirt box
/   wPos[1] ≤ 0.01  →  grass green ground
/
/ Run: zig build gpu && ink test/pbr.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ ── Geometry ─────────────────────────────────────────────────────────────────

/ Flat quad strip: 2 triangles (a,b,c) + (a,c,d), 6×[pos,nor] = 36 floats
mkFace: {[a;b;c;d;n] (a,n),(b,n),(c,n),(a,n),(c,n),(d,n)}

/ Ground plane: 4×4 quad at y=0, normal pointing up
nup: (0.;1.;0.)
ground: mkFace[(-2.;0.;-2.); (2.;0.;-2.); (2.;0.;2.); (-2.;0.;2.); nup]

/ Box corners — unit cube from (-.5,0,-.5) to (.5,1,.5)
p000:(-0.5;0.;-0.5); p001:(-0.5;0.;0.5); p010:(-0.5;1.;-0.5); p011:(-0.5;1.;0.5)
p100:(0.5;0.;-0.5);  p101:(0.5;0.;0.5);  p110:(0.5;1.;-0.5);  p111:(0.5;1.;0.5)

/ 5 visible faces (bottom hidden by ground)
f0: mkFace[p010;p110;p111;p011;(0.;1.;0.)]
f1: mkFace[p001;p101;p111;p011;(0.;0.;1.)]
f2: mkFace[p100;p000;p010;p110;(0.;0.;-1.)]
f3: mkFace[p101;p100;p110;p111;(1.;0.;0.)]
f4: mkFace[p000;p001;p011;p010;(-1.;0.;0.)]
box: f0,f1,f2,f3,f4

verts: ground,box

/ ── Vertex shader ────────────────────────────────────────────────────────────
/ Isometric camera: 45° Y-rotation then 35.26° X-tilt (same as planes.k/sphere.k).
/ Passes world-space pos and normal as varyings — fragment shader uses them for
/ lighting and material selection.

pbrVtx: VertexShader[[pos:`v3;nor:`v3]; [wPos:`v3;wNor:`v3]; {[pos;nor]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.3
  py0:(c45*pos[0])+(s45*pos[2])
  py2:(c45*pos[2])-(s45*pos[0])
  px1:(c30*pos[1])-(s30*py2)
  px2:(s30*pos[1])+(c30*py2)
  ((sc*py0; sc*px1; 0.5-px2*sc*0.5; 1.0); pos; nor)
}]

/ ── Fragment shader (Cook-Torrance PBR) ──────────────────────────────────────
/ wPos: world-space position (for material selection)
/ wNor: world-space surface normal
/
/ V = view direction toward camera = normalize(1,1,1) for isometric (1,1,1) camera
/ L = main directional light from upper-right-front
/
/ GGX D term:    D = a2 / (PI * ((NdotH^2*(a2-1)+1))^2)
/ Smith G term:  G = Gl*Gv,  Gx = NdotX / (NdotX*(1-k)+k),  k=(rough+1)^2/8
/ Schlick F:     F = 0.04 + 0.96*(1-VdotH)^5
/ Specular:      spec = D*G*F / (4*NdotL*NdotV)
/ Diffuse:       diff = (1-F)*albedo/PI
/ Final:         (diff+spec)*NdotL*lightStrength + ambient*albedo

pbrFrag: FragmentShader[[wPos:`v3;wNor:`v3; out:`v4]; {[wPos;wNor]
  isBox: wPos[1]>0.01
  ar: $[isBox; 0.50; 0.13]
  ag: $[isBox; 0.28; 0.42]
  ab: $[isBox; 0.08; 0.07]
  rough: $[isBox; 0.65; 0.90]
  V: normalize[(0.5774; 0.5774; 0.5774)]
  L: normalize[(0.5; 1.5; 0.3)]
  H: normalize[V+L]
  NdotL: max[0.0; dot[wNor; L]]
  NdotV: max[0.0001; dot[wNor; V]]
  NdotH: max[0.0; dot[wNor; H]]
  VdotH: max[0.0; dot[V; H]]
  a: rough*rough
  a2: a*a
  dn: (NdotH*NdotH*(a2-1.0))+1.0
  D: a2%(3.14159*dn*dn)
  k: (rough+1.0)*(rough+1.0)%8.0
  Gl: NdotL%((NdotL*(1.0-k))+k)
  Gv: NdotV%((NdotV*(1.0-k))+k)
  G: Gl*Gv
  F: 0.04+(0.96*pow[1.0-VdotH; 5.0])
  dnom: (4.0*NdotL*NdotV)+0.001
  spec: (D*G*F)%dnom
  kd: 1.0-F
  dr: kd*ar%3.14159
  dg: kd*ag%3.14159
  db: kd*ab%3.14159
  nl2: NdotL*2.0
  lr: clamp[(0.04*ar)+((spec+dr)*nl2); 0.0; 1.0]
  lg: clamp[(0.04*ag)+((spec+dg)*nl2); 0.0; 1.0]
  lb: clamp[(0.04*ab)+((spec+db)*nl2); 0.0; 1.0]
  (lr; lg; lb; 1.0)
}]

/ ── Window loop ──────────────────────────────────────────────────────────────

handle:: 0
RunWindow[{[props]
  $[handle=0; handle:: CompileMesh[pbrVtx; pbrFrag]; 0]
  DrawMesh[verts; handle]
}; 0]
