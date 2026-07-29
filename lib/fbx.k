/
# fbx

Reads binary FBX scene files, including their DEFLATE-compressed arrays.

ReadFbx "model.fbx" parses a binary Autodesk FBX file into a nested,
array-language-friendly tree.  Each node is a dict
  [name:`NodeType; props:(p0;p1;..); nodes:(child0;child1;..)]
where props is a general list of decoded property values and nodes is a
general list of child node dicts.  The result of ReadFbx is the top-level
list of nodes (the implicit root list of the FBX document).

Limitations (ink is 32-bit int / 32-bit float):

- D / d (float64) properties are decoded to f32 precision.
- L / l (int64) properties are decoded to f32 (exact only to 2^24);
  large 64-bit object UIDs therefore lose precision.
- I / i (int32) and Y (int16) are exact.

See doc/bug.md for the precision caveat and the parser quirks worked around.

Pure k — loads on the first reference to any `fbx.*` name.
\

/ Everything below lives in the `fbx` namespace: a bare `u16` here is `fbx.u16`
/ to the outside world, and the public entry points (fbx.read/all/get/uname/
/ trimesh/mesh) keep their dotted names.  `\d fbx` (all members public) mangles
/ each bare def to `fbx.<name>` at compile time — no runtime cost.
\d fbx

/ Mutable decode state shared across the reader/inflater lambdas (ink lambdas
/ don't capture parent scope, so cursor + buffers + Huffman tables travel as
/ namespace globals).  Declared up front so every helper's bare read binds to the
/ member regardless of definition order (e.g. onesym reads LT before fixed sets it).
b:!0; p:0; ver:0; w:0; nullsz:0; rg:!0                  / file bytes, cursor, header dims, PVI map
zb:!0; zpos:0; out:!0; op:0; target:0; bf:0; eob:0; sbp:0; need:0   / inflate stream + cursors
LT:(); DT:(); CT:()                                     / active Huffman tables (lit/dist/codelen)

/ --- powers of two (float) ---------------------------------------------
pf:{$[x=0;1.0;x<0;1.0%*/(0-x)#2.0;*/x#2.0]}

/ --- little-endian integer decoders (operate on a byte sub-list) -------
u16:{(x@0)+(256*x@1)}
i16:{v:u16 x;$[127<x@1;v-65536;v]}
/ signed 32-bit from 4 LE bytes (also correct for positive offsets/lengths)
u32:{h:$[127<x@3;(x@3)-256;x@3];(x@0)+(256*x@1)+(65536*x@2)+(16777216*h)}
/ approximate signed 64-bit -> f32 (8 LE bytes)
i64:{u:(`f$x@7){(x*256.0)+y}/(x@6;x@5;x@4;x@3;x@2;x@1;x@0);$[127<x@7;u-pf 64;u]}

/ --- IEEE-754 decoders (-> f32) ----------------------------------------
/ single precision, 4 LE bytes
f32:{s:(x@3)div 128;e:(2*((x@3)mod 128))+((x@2)div 128);m:(65536*((x@2)mod 128))+(256*x@1)+(x@0);fr:(`f$m)%8388608.0;mag:(1.0+fr)*pf(e-127);$[e=0;0.0;e=255;0w;$[s;0-mag;mag]]}
/ double precision, 8 LE bytes (decoded to f32)
f64:{s:(x@7)div 128;e:(16*((x@7)mod 128))+((x@6)div 16);h4:(x@6)mod 16;sm:(`f$x@0){y+(x%256.0)}/(x@1;x@2;x@3;x@4;x@5);fr:(h4+(sm%256.0))%16.0;mag:(1.0+fr)*pf(e-1023);$[e=0;0.0;e=2047;0w;$[s;0-mag;mag]]}

/ --- cursor primitives (read & advance p over b) ---------------
byte:{r:b@p;p::p+1;r}
bytes:{r:b@p+!x;p::p+x;r}
field:{u32 4#bytes w}      / EndOffset/NumProperties/... (w bytes)
peekend:{u32 b@p+!4}       / peek next record EndOffset (no advance)

/ --- string / raw -------------------------------------------------------
str:{n:field0[];`c$bytes n}
field0:{u32 bytes 4}           / a 4-byte length (S/R/array headers)

/ --- array properties ---------------------------------------------------
/ type codes (ints): f=102 d=100 l=108 i=105 b=98
esize:{$[x=100;8;x=108;8;x=98;1;4]}    / element byte size for f/d/l/i/b
elem:{[tc;esz;raw;i]
  c:raw@(esz*i)+!esz;
  $[tc=105;u32 c;tc=102;f32 c;tc=100;f64 c;tc=108;i64 c;c@0]}

arr:{[tc]
  n:field0[];
  enc:field0[];
  cl:field0[];
  esz:esize tc;
  raw:$[enc=0;bytes n*esz;inflate[bytes cl;n*esz]];
  p:elem[tc;esz;raw];$[n;p'!n;()]}

/ --- one property -------------------------------------------------------
/ scalar type codes (ints): Y=89 C=67 I=73 F=70 D=68 L=76 S=83 R=82
prop:{tc:byte[];
  $[tc=89;i16 bytes 2;
    tc=67;byte[];
    tc=73;u32 bytes 4;
    tc=70;f32 bytes 4;
    tc=68;f64 bytes 8;
    tc=76;i64 bytes 8;
    tc=83;str[];
    tc=82;str[];
    arr tc]}

/ --- one node record (recursive) ---------------------------------------
node:{
  endoff:field[];
  nprop:field[];
  plen:field[];
  nl:byte[];
  nm:`s$`c$bytes nl;props:$[nprop;(nprop){x,,prop[]}/();()];
  lim:endoff-nullsz;
  kids:$[p<endoff;(({p<(x@0)}){(x@0;(x@1),,node[])}/(lim;()))@1;()];
  p::endoff;
  `name`props`nodes!(nm;props;kids)
}

/ --- top-level implicit list -------------------------------------------
toplevel:{({0<peekend[]}){x,,node[]}/()}

/ --- entry point --------------------------------------------------------
read:{[path]b::`i$1:path;ver::u32 b@23+!4;w::$[ver<7500;4;8];nullsz::(3*w)+1;p::27;toplevel[]}

/ --- tree accessors -----------------------------------------------------
/ all[node;`Name] -> list of child nodes whose name matches
all:{[nd;nm]c:nd`nodes;c@&({x@`name}'c)~\:nm}
/ get[node;`Name] -> first matching child (or () if none)
get:{[nd;nm]m:all[nd;nm];$[#m;*m;()]}

/ FBX packs object names as "Name\x00\x01ClassName" inside S properties.
/ uname[s] -> the clean name (text before the first NUL); whole string
/ if there is no separator.
uname:{ix:&0=`i$x;$[#ix;(*ix)#x;x]}

/ --- geometry -> triangle mesh -----------------------------------------
/ Decode a Geometry node's Vertices + PolygonVertexIndex into a triangle
/ mesh: returns (P;T) where P is the nverts×3 position matrix and T is the
/ ntris×3 list of vertex-index triples.  FBX polygons are variable-length
/ (an entry < 0 marks the last vertex of a polygon, stored as ~index); each
/ polygon is fan-triangulated.
fan:{[s;e]k:(e-s)-1;+((k#s);(s+1+!k);(s+2+!k))}
trimesh:{[g]
  V:(get[g;`Vertices]`props)@0;
  PVI:(get[g;`PolygonVertexIndex]`props)@0;
  P:((#V)div 3;3)#V;
  neg:PVI<0;
  ridx:@[PVI;&neg;:;(0-PVI@&neg)-1];
  ends:&neg;
  starts:0,1+ -1_ends;
  post:,/starts{fan[x;y]}'ends;
  rg::ridx;
  (P;{rg@x}'post)
}

/ --- geometry -> flat-shaded triangle soup with FBX normals/UVs --------
/ mesh[g] decodes a Geometry node into a render-ready triangle SOUP (3
/ vertices per triangle, no shared indices) and returns a dict
/   [pos:Psoup; nor:Nsoup; uv:UVsoup]
/ where Psoup/Nsoup are (3·nTris)×3 and UVsoup is (3·nTris)×2 (or () if the mesh
/ has no UV layer).  Normals come straight from the file's LayerElementNormal —
/ smooth as authored — instead of being recomputed from face winding; if the
/ mesh has no normal layer, flatNorm derives flat per-face normals.

/ Flat per-face normals for a triangle soup (fallback when a mesh ships none).
flatNorm:{[Psoup]
  nt:(#Psoup)div 3
  col:+Psoup; xs:col@0; ys:col@1; zs:col@2
  i0:3*!nt
  ax:xs@i0; ay:ys@i0; az:zs@i0
  bx:xs@(i0+1); by:ys@(i0+1); bz:zs@(i0+1)
  cx:xs@(i0+2); cy:ys@(i0+2); cz:zs@(i0+2)
  e1x:bx-ax; e1y:by-ay; e1z:bz-az
  e2x:cx-ax; e2y:cy-ay; e2z:cz-az
  nx:(e1y*e2z)-(e1z*e2y); ny:(e1z*e2x)-(e1x*e2z); nz:(e1x*e2y)-(e1y*e2x)
  ln:sqrt 1e-9+(nx*nx)+(ny*ny)+(nz*nz)
  Ntri:+((nx%ln);(ny%ln);(nz%ln))
  Ntri@(!3*nt) div 3
}

/ Resolve a LayerElement* node to one value per triangle corner.  pf = flat PVI
/ positions (one per corner), rg = ridx (PVI position -> vertex index), comp =
/ floats per value.  Honours MappingInformationType (ByPolygonVertex / ByVertice
/ / ByVertex / AllSame) and ReferenceInformationType (Direct / IndexToDirect).
layerSoup:{[le;valName;idxName;pf;rg;comp]
  vals:(get[le;valName]`props)@0
  M:((#vals)div comp;comp)#vals
  map:uname (get[le;`MappingInformationType]`props)@0
  ref:uname (get[le;`ReferenceInformationType]`props)@0
  key:$[map~"ByPolygonVertex"; pf; map~"AllSame"; (#pf)#0; rg@pf]   / else per-vertex
  idxArr:$[ref~"IndexToDirect"; (get[le;idxName]`props)@0; !0]
  sel:$[#idxArr; idxArr@key; key]
  M@sel
}

mesh:{[g]
  V:(get[g;`Vertices]`props)@0
  PVI:(get[g;`PolygonVertexIndex]`props)@0
  P:((#V)div 3;3)#V
  neg:PVI<0
  rg:@[PVI;&neg;:;(0-PVI@&neg)-1]
  ends:&neg
  starts:0,1+ -1_ends
  post:,/starts{fan[x;y]}'ends
  pf:,/post
  Psoup:P@rg@pf
  ln:get[g;`LayerElementNormal]
  Nsoup:$[ln~(); flatNorm[Psoup]; layerSoup[ln;`Normals;`NormalsIndex;pf;rg;3]]
  lu:get[g;`LayerElementUV]
  UVsoup:$[lu~(); (); layerSoup[lu;`UV;`UVIndex;pf;rg;2]]
  `pos`nor`uv!(Psoup;Nsoup;UVsoup)
}

/ --- inflate (zlib / RFC1951 DEFLATE) ----------------------------------
/ Decompresses a zlib stream (byte int-list) to a byte int-list.
/ Uses globals: zb (deflate bytes), zpos (bit cursor), out
/ (output bytes), LT/DT/CT (active Huffman tables), need.

pi:{$[x=0;1;*/x#2]}                     / integer power of two
getbit:{p:zpos;zpos::p+1;((zb@(p div 8))div pi(p mod 8))mod 2}
getbits:{r:(x){((x@0)+(getbit[]*x@1);2*x@1)}/(0;1);r@0}

/ length/distance base+extra tables (DEFLATE) for symbols 257.. and dist 0..
lenbase:3 4 5 6 7 8 9 10 11 13 15 17 19 23 27 31 35 43 51 59 67 83 99 115 131 163 195 227 258
lenextra:0 0 0 0 0 0 0 0 1 1 1 1 2 2 2 2 3 3 3 3 4 4 4 4 5 5 5 5 0
distbase:1 2 3 4 5 7 9 13 17 25 33 49 65 97 129 193 257 385 513 769 1025 1537 2049 3073 4097 6145 8193 12289 16385 24577
distextra:0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10 11 11 12 12 13 13
clorder:16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15

/ build a canonical Huffman table from per-symbol code lengths
firstcodes:{[cnt]0,0{(x+y)*2}\-1_cnt}
firstidx:{[cnt]0,-1_+\cnt}
htable:{[L]ml:|/L;$[ml=0;(0#0;0#0;0#0;0#0);htable1[L;ml]]}
htable1:{[L;ml]cnt:0,L{+/x=y}/:1+!ml;(cnt;firstcodes cnt;firstidx cnt;,/L{&x=y}/:1+!ml)}

/ decode one symbol from table T (codes are read MSB-first)
decsym:{[T;code;len]c:(2*code)+getbit[];l:len+1;cnt:T@0;fc:T@1;fi:T@2;syms:T@3;off:c-fc@l;$[(((cnt@l)>0)&(~off<0))&off<cnt@l;syms@(fi@l)+off;decsym[T;c;l]]}

/ output goes to the preallocated out at write cursor op (in-place,
/ O(1) per byte).  emit a literal / copy a back-reference; onesym flags EOB.
emit:{out[op]::x;op::op+1;0}
copy:{[s]li:s-257;len:(lenbase@li)+getbits lenextra@li;ds:decsym[DT;0;0];dist:(distbase@ds)+getbits distextra@ds;(len){out[op]::out@x;op::op+1;x+1}/(op-dist);0}
onesym:{s:decsym[LT;0;0];$[s<256;emit s;s=256;eob::1;copy s]}
runblock:{eob::0;({eob=0}){onesym[];0}/0}

/ stored (uncompressed) block
stored:{r:zpos mod 8;zpos::zpos+$[r;8-r;0];bp:zpos div 8;len:(zb@bp)+(256*zb@bp+1);sbp::bp+4;(len){out[op]::zb@sbp+x;op::op+1;x+1}/0;zpos::8*(bp+4+len)}

/ fixed Huffman block
fixed:{LT::htable (144#8),(112#9),(24#7),(8#8);DT::htable 32#5;runblock[]}

/ dynamic Huffman block
readclcl:{[cl;n]r:(n){c:x@0;i:x@1;(@[c;clorder@i;:;getbits 3];i+1)}/(cl;0);r@0}
clstep:{[acc]s:decsym[CT;0;0];$[s<16;acc,s;s=16;acc,(3+getbits 2)#*|acc;s=17;acc,(3+getbits 3)#0;acc,(11+getbits 7)#0]}
readcodelens:{({(#x)<need}){clstep x}/()}
dynamic:{hlit:257+getbits 5;hdist:1+getbits 5;hclen:4+getbits 4;cl:readclcl[19#0;hclen];CT::htable cl;need::hlit+hdist;all:(hlit+hdist)#readcodelens[];LT::htable hlit#all;DT::htable hlit_all;runblock[]}

/ one block; records BFINAL in bf
doblock:{bf::getbit[];bt:getbits 2;$[bt=0;stored[];bt=1;fixed[];bt=2;dynamic[];'`badblock]}

/ inflate a zlib stream to a byte int-list of known length `target`
inflate:{[bytes;target]
  zb::2_bytes;
  zpos::0;
  out::target#0;
  op::0;
  target::target;
  bf::0;
  ({(bf=0)&op<target}){doblock[];0}/0;
  out}
\d
