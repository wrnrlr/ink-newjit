/ gltf.read / gltf.readGlb auto-load lib/gltf.k (which pulls in json.parse).

/ ── helper ──────────────────────────────────────────────────────────────────
pass: 0
fail: 0
chkN: 0
failed: {[name] fail::fail+1; `0 0:"FAIL #",($chkN)," ",name; 0}
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; failed name]; 0}

/ ── the same triangle delivered three ways: GLB, embedded data: URI, .bin ────
/ positions (0,0,0)(1,0,0)(0,1,0), ushort indices 0 1 2
P3: (0.0 0.0 0.0;1.0 0.0 0.0;0.0 1.0 0.0)
gb: gltf.readGlb  "test/data/gltf/tri.glb"
ge: gltf.read "test/data/gltf/tri_embed.gltf"
gx: gltf.read "test/data/gltf/tri_ext.gltf"
chk["glb wrapper keys";   !gb;  `json`bin]
chk["glb one buffer";     #gb`bin;  1]
chk["glb pos";            gltf.accessor[gb;0];  P3]
chk["glb idx (ushort)";   gltf.accessor[gb;1];  0 1 2]
chk["embed pos";          gltf.accessor[ge;0];  P3]
chk["embed idx";          gltf.accessor[ge;1];  0 1 2]
chk["external .bin pos";  gltf.accessor[gx;0];  P3]
chk["external .bin idx";  gltf.accessor[gx;1];  0 1 2]

/ ── base64 sanity ────────────────────────────────────────────────────────────
chk["b64 Man";  gltf.b64dec "TWFu";  77 97 110]
chk["b64 Ma";   gltf.b64dec "TWE=";  77 97]
chk["b64 M";    gltf.b64dec "TQ==";  ,77]

/ ── mesh primitive helper (GLB) ──────────────────────────────────────────────
p: gltf.prim[gb;0;0]
chk["prim keys";   !p;  `POSITION`indices`mode]
chk["prim POS";    p`POSITION;  P3]
chk["prim idx";    p`indices;   0 1 2]
chk["prim mode (default triangles)";  p`mode;  4]
chk["mesh nprims"; #gltf.mesh[gb;0];  1]

/ ── interleaved byteStride, VEC2/VEC3, float attributes (quad) ───────────────
q:  gltf.read "test/data/gltf/quad.gltf"
qp: gltf.prim[q;0;0]
chk["quad POSITION";   qp`POSITION;  (-1.0 -1.0 0.0;1.0 -1.0 0.0;1.0 1.0 0.0;-1.0 1.0 0.0)]
chk["quad NORMAL";     gltf.at[qp;"NORMAL"];  (0.0 0.0 1.0;0.0 0.0 1.0;0.0 0.0 1.0;0.0 0.0 1.0)]
chk["quad TEXCOORD_0"; gltf.at[qp;"TEXCOORD_0"];  (0.0 0.0;1.0 0.0;1.0 1.0;0.0 1.0)]
chk["quad indices";    qp`indices;  0 1 2 0 2 3]
chk["at on missing key"; gltf.at[qp;"NOPE"];  ()]

/ ── node transforms: TRS compose and explicit matrix ────────────────────────
nds: gltf.nodes q
chk["node0 T*R*S col-major"; gltf.trs gltf.row[nds;0];  2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 0.0 0.0 2.0 0.0 5.0 0.0 0.0 1.0]
chk["material name"; (gltf.row[gltf.materials q;0])`name;  "red"]

/ ── non-indexed primitive + 5125 UNSIGNED_INT indices ───────────────────────
e:  gltf.read "test/data/gltf/edge.gltf"
em: gltf.mesh[e;0]
chk["edge nprims";          #em;  2]
chk["non-indexed has no idx"; `indices in!em@0;  0b]
chk["non-indexed mode";     (em@0)`mode;  4]
chk["uint32 indices";       (em@1)`indices;  0 1 2]

/ ── a real Khronos asset (embedded Box.gltf): unit cube, 24 verts, 36 idx ────
b: gltf.read "test/data/gltf/Box.gltf"
bp: gltf.prim[b;0;0]
chk["box vert count";  #bp`POSITION;  24]
chk["box pos row0";    (bp`POSITION)@0;  -0.5 -0.5 0.5]
chk["box idx count";   #bp`indices;  36]
chk["box idx head";    6#bp`indices;  0 1 2 3 2 1]
chk["box node has matrix"; `matrix in!gltf.row[gltf.nodes b;0];  1b]

/ ── summary ─────────────────────────────────────────────────────────────────
`0 0:($pass)," passed, ",($fail)," failed"
