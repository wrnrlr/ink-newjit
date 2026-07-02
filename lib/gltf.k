/ gltf.k — glTF 2.0 / GLB reader (pure k, on top of the JSON extension)
/
/ Build first:  zig build json
/ Use:          gltf.read "model.gltf"  /  gltf.readGlb "model.glb"
/ (auto-loads this file; json.parse pulls in the JSON extension transitively)
/
/ gltf.read    "model.gltf"  parses a textual glTF asset (a JSON scene description
/ plus binary buffers referenced by URI / base64 data: URI), and
/ gltf.readGlb "model.glb"   parses the binary GLB container (12-byte header + a
/ JSON chunk + an optional BIN chunk).  Both return the same wrapper dict
/   [json: <parsed glTF document>; bin: <list of resolved buffers>]
/ where `json` is the glTF JSON exactly as the extension decodes it (top-level
/ arrays such as nodes / meshes / accessors become tables when uniform or
/ general lists of dicts otherwise) and `bin` is a general list with one entry
/ per glTF buffer, each an int byte-vector (0..255) ready for accessor decoding.
/
/ The geometry helpers turn the index-and-buffer indirection of glTF into plain
/ arrays / dicts / tables:
/   gltf.accessor[g;i]        -> a decoded accessor: an I/F vector for SCALAR,
/                                or a count*ncomp matrix for VEC*/MAT*.
/   gltf.prim[g;mesh;prim]    -> one mesh primitive as a dict of decoded vertex
/                                attributes (POSITION/NORMAL/TEXCOORD_0/...) plus
/                                `indices and `mode.
/   gltf.mesh[g;mesh]         -> the list of decoded primitives of a mesh.
/   gltf.nodes[g]             -> the node array; gltf.trs[node] composes a node's
/                                local 4x4 (column-major) from its matrix or TRS.
/
/ Limitations (ink is 32-bit int / 32-bit float):
/   - 5125 UNSIGNED_INT components decode through f32-exact range; index buffers
/     (their only legal use) are always well within it.
/   - Sparse accessors are decoded as their dense base only (the sparse override
/     is reported via gltf.f but not applied).
/   - Image pixel data (PNG/JPEG) is returned as raw bytes, not decoded.

/ --- powers of two (float) ---------------------------------------------------
gltf.pf:{$[x=0;1.0;x<0;1.0%*/(0-x)#2.0;*/x#2.0]}

/ --- little-endian integer decoders (operate on a byte sub-list) -------------
gltf.i8:{$[x>127;x-256;x]}                         / signed byte (scalar)
gltf.u16:{(x@0)+256*x@1}
gltf.i16:{v:gltf.u16 x;$[127<x@1;v-65536;v]}
gltf.u32:{(x@0)+(256*x@1)+(65536*x@2)+(16777216*x@3)}

/ --- IEEE-754 single precision (4 LE bytes) -> f32 ---------------------------
gltf.f32:{s:(x@3)div 128;e:(2*((x@3)mod 128))+((x@2)div 128);m:(65536*((x@2)mod 128))+(256*x@1)+(x@0);fr:(`f$m)%8388608.0;mag:(1.0+fr)*gltf.pf(e-127);$[e=0;0.0;e=255;0w;$[s;0-mag;mag]]}

/ --- base64 (RFC 4648) decode: char string -> int byte-vector ----------------
gltf.b64a:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
gltf.b64dec:{[s]
  s:s@&~s in "=",(`c$10),(`c$13)," ",(`c$9);       / drop padding + whitespace
  n:#s;
  nb:(n*6)div 8;                                    / output byte count
  v:gltf.b64a?s;                                    / 6-bit value per char
  v:v,((4-n mod 4)mod 4)#0;                         / pad to a multiple of 4
  g:+((#v)div 4;4)#v;                               / 4 columns of 6-bit values
  w:(262144*g@0)+(4096*g@1)+(64*g@2)+(g@3);         / 24-bit words
  nb#,/+((w div 65536)mod 256;(w div 256)mod 256;w mod 256)}

/ --- generic array-of-objects access (table or list of dicts) ----------------
gltf.row:{[a;i]$[(@a)~`m;(+a)@i;a@i]}                / -> i-th row dict
gltf.cnt:{[a]$[(@a)~`m;#*. a;#a]}                    / number of rows
gltf.rows:{[a]r:gltf.row[a;];r'!gltf.cnt a}          / -> plain list of row dicts
gltf.f:{[d;k;v]$[k in!d;d@k;v]}                      / d@k or default v if absent
gltf.sym:{`s$$[`c~@x;,x;x]}                          / char-string -> interned symbol
gltf.at:{[d;s]gltf.f[d;gltf.sym s;()]}               / look up a key by its string
                                                     / name, e.g. gltf.at[p;"TEXCOORD_0"]
                                                     / (`TEXCOORD_0 is unwritable: _ lexes as Drop)

/ --- buffer resolution -------------------------------------------------------
gltf.dirof:{[p]i:&p~\:"/";$[#i;(1+*|i)#p;""]}        / directory part of a path
gltf.isdata:{[u]$[5>#u;0;"data:"~5#u]}               / data: URI ?
gltf.afterComma:{[u](1+u?",")_u}                     / payload after the first ,
gltf.resolveuri:{[dir;u]$[gltf.isdata u;gltf.b64dec gltf.afterComma u;`i$1:dir,u]}
gltf.resolvebuf:{[dir;bin;b]$[`uri in!b;gltf.resolveuri[dir;b`uri];bin]}  / no uri -> GLB BIN
gltf.resolveall:{[doc;dir;bin]
  bs:gltf.f[doc;`buffers;()];
  $[gltf.cnt bs;(gltf.resolvebuf[dir;bin])'gltf.rows bs;()]}

/ --- entry points ------------------------------------------------------------
gltf.read:{[path]
  txt:1:path;                                        / 1: already yields chars
  doc:json.parse txt;
  `json`bin!(doc;gltf.resolveall[doc;gltf.dirof path;()])}

gltf.readGlb:{[path]
  b:`i$1:path;
  jlen:gltf.u32 b@12+!4;                             / chunk 0 length (JSON)
  json:`c$b@20+!jlen;
  p:20+jlen;
  bin:$[p<#b;b@(p+8)+!gltf.u32 b@p+!4;()];           / chunk 1 (BIN), if present
  doc:json.parse json;
  `json`bin!(doc;gltf.resolveall[doc;gltf.dirof path;bin])}

/ --- accessor decoding -------------------------------------------------------
gltf.ctsize:{[ct]$[ct=5120;1;ct=5121;1;ct=5122;2;ct=5123;2;4]}        / bytes
gltf.ncomp:{[ty]$["SCALAR"~ty;1;"VEC2"~ty;2;"VEC3"~ty;3;"VEC4"~ty;4;"MAT2"~ty;4;"MAT3"~ty;9;16]}
gltf.decval:{[ct;cs;buf;off]
  b:buf@off+!cs;
  $[ct=5126;gltf.f32 b;ct=5125;gltf.u32 b;ct=5123;gltf.u16 b;ct=5122;gltf.i16 b;ct=5121;b@0;ct=5120;gltf.i8 b@0;b@0]}

gltf.accessor:{[g;ai]
  doc:g`json;
  acc:gltf.row[doc`accessors;ai];
  ct:acc`componentType;ty:acc`type;cnt:acc`count;
  nc:gltf.ncomp ty;cs:gltf.ctsize ct;
  bvi:gltf.f[acc;`bufferView;-1];
  aoff:gltf.f[acc;`byteOffset;0];
  $[bvi<0;:$[nc=1;cnt#0.0;(cnt;nc)#0.0];0];          / no bufferView -> zeros
  bv:gltf.row[doc`bufferViews;bvi];
  buf:(g`bin)@bv`buffer;
  base:aoff+gltf.f[bv;`byteOffset;0];
  stride:gltf.f[bv;`byteStride;nc*cs];
  offs:,/(base+stride*!cnt)+\:cs*!nc;                / byte offset of each value
  dec:gltf.decval[ct;cs;buf];
  vals:dec'offs;
  $[nc=1;vals;(cnt;nc)#vals]}

/ --- mesh primitives ---------------------------------------------------------
/ Decode every attribute accessor of a primitive plus its indices into a dict.
gltf.prim:{[g;mi;pi]
  doc:g`json;
  m:gltf.row[doc`meshes;mi];
  prim:gltf.row[m`primitives;pi];
  at:prim`attributes;
  hi:`indices in!prim;
  ks:!at;vs:(gltf.accessor[g;])'. at;                / decode each attribute
  ki:$[hi;ks,`indices;ks];
  vi:$[hi;vs,,gltf.accessor[g;prim`indices];vs];
  (ki,`mode)!vi,,gltf.f[prim;`mode;4]}               / build the dict in one shot

gltf.mesh:{[g;mi]
  doc:g`json;
  m:gltf.row[doc`meshes;mi];
  np:gltf.cnt m`primitives;
  (gltf.prim[g;mi;])'!np}

/ --- node transforms ---------------------------------------------------------
/ Quaternion (x,y,z,w) -> 3x3 rotation matrix.
gltf.quat2mat:{[q]
  x:q@0;y:q@1;z:q@2;w:q@3;
  ((1.0-2.0*(y*y)+(z*z);2.0*(x*y)-(z*w);2.0*(x*z)+(y*w))
   (2.0*(x*y)+(z*w);1.0-2.0*(x*x)+(z*z);2.0*(y*z)-(x*w))
   (2.0*(x*z)-(y*w);2.0*(y*z)+(x*w);1.0-2.0*(x*x)+(y*y)))}

/ Compose a node's local 4x4 (column-major flattened, glTF convention) from
/ either its `matrix or its TRS properties: M = T * R * S, so column j (<3) is
/ R's column j scaled by s[j], and column 3 is the translation.
gltf.trsRS:{[t;s;R]
  C:+R;tf:`f$t;sf:`f$s;                              / columns of R; force float
  ((sf@0)*(C@0),0.0),((sf@1)*(C@1),0.0),((sf@2)*(C@2),0.0),tf,1.0}
gltf.trs:{[nd]
  $[`matrix in!nd;`f$nd`matrix;
    gltf.trsRS[gltf.f[nd;`translation;0.0 0.0 0.0];gltf.f[nd;`scale;1.0 1.0 1.0];gltf.quat2mat gltf.f[nd;`rotation;0.0 0.0 0.0 1.0]]]}

/ --- convenience accessors ---------------------------------------------------
gltf.asset:{[g](g`json)`asset}
gltf.scenes:{[g]gltf.f[g`json;`scenes;()]}
gltf.nodes:{[g]gltf.f[g`json;`nodes;()]}
gltf.materials:{[g]gltf.f[g`json;`materials;()]}
