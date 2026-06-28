2:"lib/fbx.k"

/ ── helper ──────────────────────────────────────────────────────────────────
pass: 0
fail: 0
chkN: 0
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; {fail::fail+1; `0 0:"FAIL #",($chkN)," ",name}[]]; 0}

/ ── parse plain + zipped fixtures ────────────────────────────────────────────
u: ReadFbx "test/data/cube.fbx"
z: ReadFbx "test/data/cube_zip.fbx"

/ ── structure / scalar property decoding ─────────────────────────────────────
chk["toplevel count"; #u; 1]
o: u@0
chk["root name";   o`name;  `Objects]
chk["root props";  o`props; (42;3.140625;7;1;2.5)]   / I D Y C F  (D/F chosen f32-exact)

g: fbx.get[o;`Geometry]
chk["geom name";   g`name;  `Geometry]
chk["geom props";  g`props; (12345.0;"Cube")]        / L S  (L -> f32)

/ ── array property decoding ──────────────────────────────────────────────────
v: fbx.get[g;`Vertices]
chk["nverts"; #(v`props)@0; 300]                     / d array (float64 -> f32)
i: fbx.get[g;`PolygonVertexIndex]
chk["index array"; (i`props)@0; !150]                / i array (int32, exact)

/ ── tree accessors ───────────────────────────────────────────────────────────
chk["num models"; #fbx.all[o;`Model]; 2]
chk["missing";    #fbx.all[o;`Nope];  0]

/ ── inflate correctness: zipped file decodes identically to plain ────────────
chk["zip == plain"; z; u]

/ ── name helper ──────────────────────────────────────────────────────────────
chk["uname split";   fbx.uname "Cube",(,`c$0),(,`c$1),"Geometry"; "Cube"]
chk["uname no-sep";  fbx.uname "Plain"; "Plain"]

/ ── real Autodesk file (binary, zlib-compressed arrays, v7400) ───────────────
s: ReadFbx "data/FBX/Sword.fbx"
chk["sword toplevel";   {x`name}'s; `FBXHeaderExtension`FileId`CreationTime`Creator`GlobalSettings`Documents`References`Definitions`Objects`Connections`Takes]
sobj: *s@&({$[(x`name)~`Objects;1;0]}'s)
sg: fbx.get[sobj;`Geometry]
chk["sword geom name"; fbx.uname (sg`props)@1; "Cylinder"]
chk["sword nverts"; #(fbx.get[sg;`Vertices]`props)@0; 834]
chk["sword nindex"; #(fbx.get[sg;`PolygonVertexIndex]`props)@0; 1028]
sm: fbx.trimesh sg
chk["sword mesh verts"; #sm@0; 278]
chk["sword mesh tris";  #sm@1; 524]

/ ── summary ─────────────────────────────────────────────────────────────────
`0 0:($pass)," passed, ",($fail)," failed"
