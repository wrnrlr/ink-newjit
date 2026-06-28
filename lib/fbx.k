/ fbx.k — binary FBX reader (pure k)
/
/ ReadFbx "model.fbx" parses a binary Autodesk FBX file into a nested,
/ array-language-friendly tree.  Each node is a dict
/   [name:`NodeType; props:(p0;p1;..); nodes:(child0;child1;..)]
/ where props is a general list of decoded property values and nodes is a
/ general list of child node dicts.  The result of ReadFbx is the top-level
/ list of nodes (the implicit root list of the FBX document).
/
/ Limitations (ink is 32-bit int / 32-bit float):
/   - D / d (float64) properties are decoded to f32 precision.
/   - L / l (int64) properties are decoded to f32 (exact only to 2^24);
/     large 64-bit object UIDs therefore lose precision.
/   - I / i (int32) and Y (int16) are exact.
/ See doc/bug.md for the precision caveat and the parser quirks worked around.

/ --- powers of two (float) ---------------------------------------------
fbx.pf:{$[x=0;1.0;x<0;1.0%*/(0-x)#2.0;*/x#2.0]}

/ --- little-endian integer decoders (operate on a byte sub-list) -------
fbx.u16:{(x@0)+(256*x@1)}
fbx.i16:{v:fbx.u16 x;$[127<x@1;v-65536;v]}
/ signed 32-bit from 4 LE bytes (also correct for positive offsets/lengths)
fbx.u32:{h:$[127<x@3;(x@3)-256;x@3];(x@0)+(256*x@1)+(65536*x@2)+(16777216*h)}
/ approximate signed 64-bit -> f32 (8 LE bytes)
fbx.i64:{u:(`f$x@7){(x*256.0)+y}/(x@6;x@5;x@4;x@3;x@2;x@1;x@0);$[127<x@7;u-fbx.pf 64;u]}

/ --- IEEE-754 decoders (-> f32) ----------------------------------------
/ single precision, 4 LE bytes
fbx.f32:{s:(x@3)div 128;e:(2*((x@3)mod 128))+((x@2)div 128);m:(65536*((x@2)mod 128))+(256*x@1)+(x@0);fr:(`f$m)%8388608.0;mag:(1.0+fr)*fbx.pf(e-127);$[e=0;0.0;e=255;0w;$[s;0-mag;mag]]}
/ double precision, 8 LE bytes (decoded to f32)
fbx.f64:{s:(x@7)div 128;e:(16*((x@7)mod 128))+((x@6)div 16);h4:(x@6)mod 16;sm:(`f$x@0){y+(x%256.0)}/(x@1;x@2;x@3;x@4;x@5);fr:(h4+(sm%256.0))%16.0;mag:(1.0+fr)*fbx.pf(e-1023);$[e=0;0.0;e=2047;0w;$[s;0-mag;mag]]}

/ --- cursor primitives (read & advance fbx.p over fbx.b) ---------------
fbx.byte:{r:fbx.b@fbx.p;fbx.p::fbx.p+1;r}
fbx.bytes:{r:fbx.b@fbx.p+!x;fbx.p::fbx.p+x;r}
fbx.field:{fbx.u32 4#fbx.bytes fbx.w}      / EndOffset/NumProperties/... (w bytes)
fbx.peekend:{fbx.u32 fbx.b@fbx.p+!4}       / peek next record EndOffset (no advance)

/ --- string / raw -------------------------------------------------------
fbx.str:{n:fbx.field0[];`c$fbx.bytes n}
fbx.field0:{fbx.u32 fbx.bytes 4}           / a 4-byte length (S/R/array headers)

/ --- array properties ---------------------------------------------------
/ type codes (ints): f=102 d=100 l=108 i=105 b=98
fbx.esize:{$[x=100;8;x=108;8;x=98;1;4]}    / element byte size for f/d/l/i/b
fbx.elem:{[tc;esz;raw;i]
  c:raw@(esz*i)+!esz;
  $[tc=105;fbx.u32 c;tc=102;fbx.f32 c;tc=100;fbx.f64 c;tc=108;fbx.i64 c;c@0]}

fbx.arr:{[tc]
  n:fbx.field0[];
  enc:fbx.field0[];
  cl:fbx.field0[];
  esz:fbx.esize tc;
  raw:$[enc=0;fbx.bytes n*esz;fbx.inflate[fbx.bytes cl;n*esz]];
  p:fbx.elem[tc;esz;raw];$[n;p'!n;()]}

/ --- one property -------------------------------------------------------
/ scalar type codes (ints): Y=89 C=67 I=73 F=70 D=68 L=76 S=83 R=82
fbx.prop:{tc:fbx.byte[];
  $[tc=89;fbx.i16 fbx.bytes 2;
    tc=67;fbx.byte[];
    tc=73;fbx.u32 fbx.bytes 4;
    tc=70;fbx.f32 fbx.bytes 4;
    tc=68;fbx.f64 fbx.bytes 8;
    tc=76;fbx.i64 fbx.bytes 8;
    tc=83;fbx.str[];
    tc=82;fbx.str[];
    fbx.arr tc]}

/ --- one node record (recursive) ---------------------------------------
fbx.node:{
  endoff:fbx.field[];
  nprop:fbx.field[];
  plen:fbx.field[];
  nl:fbx.byte[];
  nm:`s$`c$fbx.bytes nl;props:$[nprop;(nprop){x,,fbx.prop[]}/();()];
  lim:endoff-fbx.nullsz;
  kids:$[fbx.p<endoff;(({fbx.p<(x@0)}){(x@0;(x@1),,fbx.node[])}/(lim;()))@1;()];
  fbx.p::endoff;
  `name`props`nodes!(nm;props;kids)
}

/ --- top-level implicit list -------------------------------------------
fbx.toplevel:{({0<fbx.peekend[]}){x,,fbx.node[]}/()}

/ --- entry point --------------------------------------------------------
ReadFbx:{[path]fbx.b::`i$1:path;fbx.ver::fbx.u32 fbx.b@23+!4;fbx.w::$[fbx.ver<7500;4;8];fbx.nullsz::(3*fbx.w)+1;fbx.p::27;fbx.toplevel[]}

/ --- tree accessors -----------------------------------------------------
/ Symbol `=` and eachleft `\:`/`~\:` are unreliable here (see doc/bug.md);
/ build the match mask with plain each `'` and thread the query via fbx.q.
/ fbx.all[node;`Name] -> list of child nodes whose name matches
fbx.all:{[nd;nm]fbx.q::nm;c:nd`nodes;c@&({$[(x@`name)~fbx.q;1;0]}'c)}
/ fbx.get[node;`Name] -> first matching child (or () if none)
fbx.get:{[nd;nm]m:fbx.all[nd;nm];$[#m;*m;()]}

/ FBX packs object names as "Name\x00\x01ClassName" inside S properties.
/ fbx.uname[s] -> the clean name (text before the first NUL); whole string
/ if there is no separator.
fbx.uname:{ix:&0=`i$x;$[#ix;(*ix)#x;x]}

/ --- geometry -> triangle mesh -----------------------------------------
/ Decode a Geometry node's Vertices + PolygonVertexIndex into a triangle
/ mesh: returns (P;T) where P is the nverts×3 position matrix and T is the
/ ntris×3 list of vertex-index triples.  FBX polygons are variable-length
/ (an entry < 0 marks the last vertex of a polygon, stored as ~index); each
/ polygon is fan-triangulated.
fbx.fan:{[s;e]k:(e-s)-1;+((k#s);(s+1+!k);(s+2+!k))}
fbx.trimesh:{[g]
  V:(fbx.get[g;`Vertices]`props)@0;
  PVI:(fbx.get[g;`PolygonVertexIndex]`props)@0;
  P:((#V)div 3;3)#V;
  neg:PVI<0;
  ridx:@[PVI;&neg;:;(0-PVI@&neg)-1];
  ends:&neg;
  starts:0,1+ -1_ends;
  post:,/starts{fbx.fan[x;y]}'ends;
  fbx.rg::ridx;
  (P;{fbx.rg@x}'post)
}

/ --- inflate (zlib / RFC1951 DEFLATE) ----------------------------------
/ Decompresses a zlib stream (byte int-list) to a byte int-list.
/ Uses globals: fbx.zb (deflate bytes), fbx.zpos (bit cursor), fbx.out
/ (output bytes), fbx.LT/fbx.DT/fbx.CT (active Huffman tables), fbx.need.

fbx.pi:{$[x=0;1;*/x#2]}                     / integer power of two
fbx.getbit:{p:fbx.zpos;fbx.zpos::p+1;((fbx.zb@(p div 8))div fbx.pi(p mod 8))mod 2}
fbx.getbits:{r:(x){((x@0)+(fbx.getbit[]*x@1);2*x@1)}/(0;1);r@0}

/ length/distance base+extra tables (DEFLATE) for symbols 257.. and dist 0..
fbx.lenbase:3 4 5 6 7 8 9 10 11 13 15 17 19 23 27 31 35 43 51 59 67 83 99 115 131 163 195 227 258
fbx.lenextra:0 0 0 0 0 0 0 0 1 1 1 1 2 2 2 2 3 3 3 3 4 4 4 4 5 5 5 5 0
fbx.distbase:1 2 3 4 5 7 9 13 17 25 33 49 65 97 129 193 257 385 513 769 1025 1537 2049 3073 4097 6145 8193 12289 16385 24577
fbx.distextra:0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10 11 11 12 12 13 13
fbx.clorder:16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15

/ build a canonical Huffman table from per-symbol code lengths
fbx.firstcodes:{[cnt]0,0{(x+y)*2}\-1_cnt}
fbx.firstidx:{[cnt]0,-1_+\cnt}
fbx.htable:{[L]ml:|/L;$[ml=0;(0#0;0#0;0#0;0#0);fbx.htable1[L;ml]]}
fbx.htable1:{[L;ml]cnt:0,L{+/x=y}/:1+!ml;(cnt;fbx.firstcodes cnt;fbx.firstidx cnt;,/L{&x=y}/:1+!ml)}

/ decode one symbol from table T (codes are read MSB-first)
fbx.decsym:{[T;code;len]c:(2*code)+fbx.getbit[];l:len+1;cnt:T@0;fc:T@1;fi:T@2;syms:T@3;off:c-fc@l;$[(((cnt@l)>0)&(~off<0))&off<cnt@l;syms@(fi@l)+off;fbx.decsym[T;c;l]]}

/ output goes to the preallocated fbx.out at write cursor fbx.op (in-place,
/ O(1) per byte).  emit a literal / copy a back-reference; onesym flags EOB.
fbx.emit:{fbx.out[fbx.op]::x;fbx.op::fbx.op+1;0}
fbx.copy:{[s]li:s-257;len:(fbx.lenbase@li)+fbx.getbits fbx.lenextra@li;ds:fbx.decsym[fbx.DT;0;0];dist:(fbx.distbase@ds)+fbx.getbits fbx.distextra@ds;(len){fbx.out[fbx.op]::fbx.out@x;fbx.op::fbx.op+1;x+1}/(fbx.op-dist);0}
fbx.onesym:{s:fbx.decsym[fbx.LT;0;0];$[s<256;fbx.emit s;s=256;fbx.eob::1;fbx.copy s]}
/ loop bodies must reference x (ink while only iterates when the threaded
/ value is used); x is just a step counter, the real state is global.
fbx.runblock:{fbx.eob::0;({fbx.eob=0}){fbx.onesym[];x+1}/0}

/ stored (uncompressed) block
fbx.stored:{r:fbx.zpos mod 8;fbx.zpos::fbx.zpos+$[r;8-r;0];bp:fbx.zpos div 8;len:(fbx.zb@bp)+(256*fbx.zb@bp+1);fbx.sbp::bp+4;(len){fbx.out[fbx.op]::fbx.zb@fbx.sbp+x;fbx.op::fbx.op+1;x+1}/0;fbx.zpos::8*(bp+4+len)}

/ fixed Huffman block
fbx.fixed:{fbx.LT::fbx.htable (144#8),(112#9),(24#7),(8#8);fbx.DT::fbx.htable 32#5;fbx.runblock[]}

/ dynamic Huffman block
fbx.readclcl:{[cl;n]r:(n){c:x@0;i:x@1;(@[c;fbx.clorder@i;:;fbx.getbits 3];i+1)}/(cl;0);r@0}
fbx.clstep:{[acc]s:fbx.decsym[fbx.CT;0;0];$[s<16;acc,s;s=16;acc,(3+fbx.getbits 2)#*|acc;s=17;acc,(3+fbx.getbits 3)#0;acc,(11+fbx.getbits 7)#0]}
fbx.readcodelens:{({(#x)<fbx.need}){fbx.clstep x}/()}
fbx.dynamic:{hlit:257+fbx.getbits 5;hdist:1+fbx.getbits 5;hclen:4+fbx.getbits 4;cl:fbx.readclcl[19#0;hclen];fbx.CT::fbx.htable cl;fbx.need::hlit+hdist;all:(hlit+hdist)#fbx.readcodelens[];fbx.LT::fbx.htable hlit#all;fbx.DT::fbx.htable hlit_all;fbx.runblock[]}

/ one block; records BFINAL in fbx.bf
fbx.doblock:{fbx.bf::fbx.getbit[];bt:fbx.getbits 2;$[bt=0;fbx.stored[];bt=1;fbx.fixed[];bt=2;fbx.dynamic[];'`badblock]}

/ inflate a zlib stream to a byte int-list of known length `target`
fbx.inflate:{[bytes;target]fbx.zb::2_bytes;fbx.zpos::0;fbx.out::target#0;fbx.op::0;fbx.target::target;fbx.bf::0;({(fbx.bf=0)&fbx.op<fbx.target}){fbx.doblock[];x+1}/0;fbx.out}
