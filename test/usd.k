2:"lib/usd.k"

/ ── helper ──────────────────────────────────────────────────────────────────
pass: 0
fail: 0
chkN: 0
failed: {[name] fail::fail+1; `0 0:"FAIL #",($chkN)," ",name; 0}
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; failed name]; 0}

m: ReadUsdc "test/data/usd/min.usdc"

/ ── cube mesh: structure, paths, specs ───────────────────────────────────────
c: ReadUsdc "test/data/usd/cube.usdc"
chk["cube nspecs";  #c;  8]
chk["cube paths";   c`path;  usd.symof'("/";"/Cube";"/Cube.faceVertexCounts";"/Cube.faceVertexIndices";"/Cube.points";"/Cube.primvars:displayColor";"/Cube.size";"/Cube.subdivisionScheme")]
chk["cube spectypes"; c`spec; `PseudoRoot`Prim`Attribute`Attribute`Attribute`Attribute`Attribute`Attribute]

/ ── layer / prim metadata ────────────────────────────────────────────────────
chk["defaultPrim";  usd.attr[c;"/";`defaultPrim];   `Cube]
chk["upAxis";       usd.attr[c;"/";`upAxis];         `Y]
chk["primChildren"; usd.attr[c;"/";`primChildren];   ,`Cube]
chk["Cube specifier"; usd.attr[c;"/Cube";`specifier]; `def]
chk["Cube typeName";  usd.attr[c;"/Cube";`typeName];  `Mesh]
chk["Cube props";     usd.attr[c;"/Cube";`properties]; usd.symof'("faceVertexCounts";"faceVertexIndices";"points";"primvars:displayColor";"size";"subdivisionScheme")]

/ ── attribute values: uncompressed int array, compressed int array, vec3f, … ──
chk["faceVertexCounts (int[])";   usd.attr[c;"/Cube.faceVertexCounts";`default];   6#4]
chk["faceVertexIndices (cmp int[])"; usd.attr[c;"/Cube.faceVertexIndices";`default]; 0 1 3 2 2 3 5 4 4 5 7 6 6 7 1 0 1 7 5 3 6 0 2 4]
chk["points (point3f[])";  usd.attr[c;"/Cube.points";`default];  (-1.0 -1.0 -1.0;1.0 -1.0 -1.0;-1.0 1.0 -1.0;1.0 1.0 -1.0;-1.0 1.0 1.0;1.0 1.0 1.0;-1.0 -1.0 1.0;1.0 -1.0 1.0)]
chk["displayColor (color3f[])"; usd.attr[c;"/Cube.primvars:displayColor";`default]; ,0.2 0.5 0.8]
chk["size (double)";       usd.attr[c;"/Cube.size";`default];  2.0]
chk["subdivScheme (token)"; usd.attr[c;"/Cube.subdivisionScheme";`default]; `none]
chk["uniform variability"; usd.attr[c;"/Cube.subdivisionScheme";`variability]; `uniform]
chk["varying variability"; usd.attr[c;"/Cube.points";`variability]; `varying]

/ ── min layer scalar round-trip (int / double / string / bool) ───────────────
chk["int a";    usd.attr[m;"/root.a";`default];  7]
chk["double b"; usd.attr[m;"/root.b";`default];  1.5]
chk["string c"; usd.attr[m;"/root.c";`default];  "hello"]
chk["bool d";   usd.attr[m;"/root.d";`default];  1]
chk["layer doc"; usd.attr[m;"/";`documentation]; "hi"]

/ ── usd.kind selector ────────────────────────────────────────────────────────
chk["kind Prim count";      #usd.kind[c;`Prim];      1]
chk["kind Attribute count"; #usd.kind[c;`Attribute]; 6]

/ ── real PBR material (LZ4 tokens, asset paths, vec4f, dictionary) ───────────
g: ReadUsdc "data/ambientcg/Grass005_1K-JPG/Grass005_1K-JPG.usdc"
chk["material nspecs";  #g;  63]
chk["material defaultPrim"; usd.attr[g;"/";`defaultPrim]; `s$"aCG_Grass005_1K_JPG"]
chk["material upAxis";      usd.attr[g;"/";`upAxis];       `Z]
chk["shader id"; usd.attr[g;"/aCG_Grass005_1K_JPG/PBRShader.info:id";`default]; `UsdPreviewSurface]
chk["asset file"; usd.attr[g;"/aCG_Grass005_1K_JPG/occlusion.inputs:file";`default]; "Grass005_1K-JPG_AmbientOcclusion.jpg"]
chk["vec4f fallback"; usd.attr[g;"/aCG_Grass005_1K_JPG/occlusion.inputs:fallback";`default]; 1.0 1.0 1.0 1.0]
cld: usd.attr[g;"/";`customLayerData]
chk["dict title"; (cld`title); "Grass 005"]
chk["dict type";  (cld`type);  "material"]
chk["dict url";   (cld`url);   "https://ambientcg.com/a/Grass005"]

/ ── summary ─────────────────────────────────────────────────────────────────
`0 0:($pass)," passed, ",($fail)," failed"
