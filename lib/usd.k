/
# usd

Reads binary USDC (Pixar 'crate') scene files in pure k.

ReadUsdc "model.usdc" parses a binary USD crate file into an array-language
friendly table.  Each row is one Sdf "spec" (a prim, attribute, relationship,
…) with columns:

```k
path   `s  the spec's scene path, e.g. `/Cube`/Cube.points
spec   `s  the spec type, e.g. `Prim`Attribute`PseudoRoot
fields `m  a dict of field-name -> decoded value (specifier, typeName,
           default value, custom metadata, …)
```

The result is a `M` table; filter / index it with ordinary verbs.

Crate layout (handled): bootstrap header -> table-of-contents -> the six
structural sections TOKENS STRINGS FIELDS FIELDSETS PATHS SPECS.  TOKENS and
value-rep buffers are LZ4-compressed; FIELDS/FIELDSETS/PATHS/SPECS index
arrays use USD's 2-bit "integer compression"; integral arrays additionally
LZ4 their integer-compressed payload.  Supported file versions: >= 0.4.0
(compressed structural sections), which covers all current writers.

Limitations (ink is 32-bit int / 32-bit float):

```k
- D (float64) and L (int64) decode to f32 precision (large UIDs lose bits).
- 64-bit file offsets/counts are read from their low 32 bits (fine for any
  file under 2 GiB).
- Inline scalars/vectors, uncompressed arrays, integer-compressed integral
  arrays, and token/path vectors are fully decoded.  Dictionaries, list-ops,
  time-samples and compressed float arrays are returned tagged but not
  expanded: (`usdc.ref;type;payload) / (`usdc.arr;type;count).
```

ink note: lambdas do NOT capture enclosing locals, so per-element callbacks
are global helpers (usd.*at) reading shared globals, or fixed-arg projections.

Pure k — loads on the first reference to any `usd.*` name.
\

/ --- powers of two -----------------------------------------------------------
usd.pi:{$[x=0;1;*/x#2]}                          / integer 2^x  (x>=0)
usd.pf:{$[x=0;1.0;x<0;1.0%*/(0-x)#2.0;*/x#2.0]}  / float   2^x

/ --- little-endian integer decoders (operate on a byte sub-list) -------------
usd.u16:{(x@0)+256*x@1}
usd.i16:{v:usd.u16 x;$[127<x@1;v-65536;v]}
usd.u32:{h:$[127<x@3;(x@3)-256;x@3];(x@0)+(256*x@1)+(65536*x@2)+(16777216*h)}
usd.i32:usd.u32                                  / our u32 already sign-extends
usd.i8:{$[x>127;x-256;x]}                        / signed byte (scalar)

/ --- IEEE-754 decoders (-> f32) ----------------------------------------------
usd.f32:{s:(x@3)div 128;e:(2*((x@3)mod 128))+((x@2)div 128);m:(65536*((x@2)mod 128))+(256*x@1)+(x@0);fr:(`f$m)%8388608.0;mag:(1.0+fr)*usd.pf(e-127);$[e=0;0.0;e=255;0w;$[s;0-mag;mag]]}
usd.f64:{s:(x@7)div 128;e:(16*((x@7)mod 128))+((x@6)div 16);h4:(x@6)mod 16;sm:(`f$x@0){y+(x%256.0)}/(x@1;x@2;x@3;x@4;x@5);fr:(h4+(sm%256.0))%16.0;mag:(1.0+fr)*usd.pf(e-1023);$[e=0;0.0;e=2047;0w;$[s;0-mag;mag]]}
/ half precision, 2 bytes (lo;hi) -> f32
usd.half:{[lo;hi]s:hi div 128;e:(hi mod 128)div 4;m:(256*(hi mod 4))+lo;mag:(1.0+(`f$m)%1024.0)*usd.pf(e-15);$[e=0;$[m=0;0.0;(`f$m)*usd.pf(0-24)];e=31;0w;$[s;0-mag;mag]]}

/ --- cursor primitives (read & advance usd.p over usd.b) ---------------------
usd.bytes:{r:usd.b@usd.p+!x;usd.p::usd.p+x;r}
usd.rdu32:{r:usd.u32 usd.b@usd.p+!4;usd.p::usd.p+4;r}
usd.rdu64:{r:usd.u32 usd.b@usd.p+!4;usd.p::usd.p+8;r}   / low 32 bits of a u64

/ --- LZ4 block decompression (TfFastCompression wrapper) ---------------------
/ wrapper byte 0 == single chunk; the rest is one raw LZ4 block.  Globals:
/   usd.s/usd.sp/usd.sn (source bytes,cursor,len), usd.o/usd.op (output,cursor)
usd.lz4ext:{[init](({(x@1)=255}){b:usd.s@usd.sp;usd.sp::usd.sp+1;((x@0)+b;b)}/(init;255))@0}
usd.lz4match:{[tok]
  off:(usd.s@usd.sp)+256*usd.s@usd.sp+1;usd.sp::usd.sp+2;
  ml:tok mod 16;ml:4+$[ml=15;usd.lz4ext 15;ml];
  (ml){usd.o[usd.op]::usd.o@x;usd.op::usd.op+1;x+1}/(usd.op-off);0}
usd.lz4seq:{
  tok:usd.s@usd.sp;usd.sp::usd.sp+1;
  ll:tok div 16;ll:$[ll=15;usd.lz4ext 15;ll];
  (ll){usd.o[usd.op]::usd.s@usd.sp;usd.sp::usd.sp+1;usd.op::usd.op+1;x+1}/0;
  $[usd.sp<usd.sn;usd.lz4match tok;0];0}
usd.lz4blk:{[src;outlen]
  usd.s::src;usd.sp::0;usd.sn::#src;usd.o::outlen#0;usd.op::0;
  ({usd.sp<usd.sn}){usd.lz4seq[];0}/0;usd.o}
usd.lz4:{[buf;outlen]$[(buf@0)=0;usd.lz4blk[1_buf;outlen];'`lz4multichunk]}

/ --- USD integer compression (2-bit codes + delta) ---------------------------
/ comp = LZ4-wrapped working buffer; returns n decoded ints.  Globals carry the
/ working buffer (usd.idwb) and common value (usd.idcv) across the over-loop.
usd.ival:{[b;p;w]$[w=1;usd.i8 b@p;w=2;usd.i16 b@(p+!2);usd.i32 b@(p+!4)]}
usd.idstep:{[x]
  i:x@0;prev:x@1;vp:x@2;
  code:((usd.idwb@(4+(i div 4)))div usd.pi(2*(i mod 4)))mod 4;
  w:$[code=0;0;code=1;1;code=2;2;4];
  d:$[code=0;usd.idcv;usd.ival[usd.idwb;vp;w]];
  usd.idacc::usd.idacc,(prev+d);
  ((i+1);(prev+d);(vp+w);x@3)}
usd.intdec:{[comp;n]
  ws:4+(((n*2)+7)div 8)+n*4;
  usd.idwb::usd.lz4[comp;ws];
  usd.idcv::usd.i32 usd.idwb@!4;
  usd.idacc::!0;
  ({(x@0)<(x@3)}){usd.idstep x}/(0;0;(4+((n*2)+7)div 8);n);
  usd.idacc}

/ read a length-prefixed integer-compression block of n ints (advances usd.p)
usd.rdintblk:{[n]csz:usd.rdu64[];comp:usd.bytes csz;usd.intdec[comp;n]}

/ --- structural sections -----------------------------------------------------
usd.cstr:{i:&x=0;`c$$[#i;(*i)#x;x]}              / NUL-terminated -> char string

/ tokens are interned to symbols immediately: ink gather returns a *view* into
/ the (recyclable) LZ4 scratch buffer, so char-string copies would dangle; a
/ symbol vector is interned and stable.  Use `$sym` to recover the chars.
usd.tokat:{[i]`s$`c$usd.traw@(usd.tst@i)+!((usd.tz@i)-(usd.tst@i))}
usd.rdtokens:{[start]
  usd.p::start;n:usd.rdu64[];usz:usd.rdu64[];csz:usd.rdu64[];
  usd.traw::usd.lz4[usd.bytes csz;usz];
  usd.tz::&0=usd.traw;usd.tst::0,1+usd.tz;
  usd.tok::usd.tokat'!n}

usd.strat:{[i]usd.u32 usd.sraw@(4*i)+!4}
usd.rdstrings:{[start]usd.p::start;n:usd.rdu64[];usd.sraw::usd.bytes 4*n;usd.strs::usd.strat'!n}

/ reps live in another LZ4 scratch buffer; force a fresh copy per field (0+…)
/ so later array/dict value decodes (which reuse the scratch) can't clobber it.
usd.repcopy:{[i]0+usd.reps@(8*i)+!8}
usd.rdfields:{[start]
  usd.p::start;nf:usd.rdu64[];
  usd.fldtok::usd.rdintblk nf;
  rsz:usd.rdu64[];usd.reps::usd.lz4[usd.bytes rsz;nf*8];
  usd.repl::usd.repcopy'!nf}

usd.rdfsets:{[start]usd.p::start;n:usd.rdu64[];usd.fset::usd.rdintblk n}

usd.rdpaths:{[start]
  usd.p::start;np:usd.rdu64[];np2:usd.rdu64[];
  pidx:usd.rdintblk np;etok:usd.rdintblk np;jmp:usd.rdintblk np;
  usd.buildpaths[pidx;etok;jmp]}

usd.rdspecs:{[start]
  usd.p::start;ns:usd.rdu64[];
  usd.spidx::usd.rdintblk ns;usd.sfset::usd.rdintblk ns;usd.stype::usd.rdintblk ns}

/ --- path tree reconstruction ------------------------------------------------
usd.sstr:{1_$x}                                  / symbol -> char string (drop `)
usd.appendelem:{[parent;e]
  prop:e<0;t:usd.sstr usd.tok@$[prop;0-e;e];
  $[prop;parent,".",t;
    (*t)~"{";parent,t;
    (*t)~"[";parent,t;
    parent~"/";"/",t;
    parent,"/",t]}
usd.pathrec:{[cur;parent]
  pth:$[(#parent)=0;"/";usd.appendelem[parent;usd.etok@cur]];
  usd.pth[usd.pidx@cur]::pth;
  j:usd.jmp@cur;haschild:$[j>0;1;j=-1;1;0];hassib:$[j<0;0;1];
  $[haschild;
    $[hassib;usd.pathrec[cur+j;parent];0];
    $[hassib;usd.pathrec[cur+1;parent];0]];
  $[haschild;usd.pathrec[cur+1;pth];0];0}
usd.symof:{`s$$[`c~@x;,x;x]}                      / char-string -> interned symbol
usd.buildpaths:{[pidx;etok;jmp]
  np:#pidx;usd.pth::np#,"";
  usd.pidx::pidx;usd.etok::etok;usd.jmp::jmp;
  usd.pathrec[0;""];
  usd.pth::usd.symof'usd.pth}                     / intern before scratch is reused

/ --- value decoding ----------------------------------------------------------
usd.spec:{(`def;`over;`class)@x}
usd.varia:{(`varying;`uniform)@x}
usd.stypename:{(`;`Attribute;`Connection;`Expression;`Mapper;`MapperArg;`Prim;`PseudoRoot;`Relationship;`RelationshipTarget;`Variant;`VariantSet)@x}

/ inline vectors: components stored as signed bytes
usd.ivecf:{[b;n]`f$usd.i8'b@!n}
usd.iveci:{[b;n]usd.i8'b@!n}

usd.inl:{[t;b]
  $[t=1;b@0;
    t=2;b@0;
    t=3;usd.i32 b@!4;
    t=4;usd.u32 b@!4;
    t=7;usd.half[b@0;b@1];
    t=8;usd.f32 b@!4;
    t=9;usd.f32 b@!4;
    t=10;usd.sstr usd.tok@usd.strs@usd.u32 b@!4;
    t=11;usd.tok@usd.u32 b@!4;
    t=12;usd.sstr usd.tok@usd.u32 b@!4;
    t=42;usd.spec b@0;
    t=43;b@0;
    t=44;usd.varia b@0;
    t=20;usd.ivecf[b;2];t=24;usd.ivecf[b;3];t=28;usd.ivecf[b;4];
    t=19;usd.ivecf[b;2];t=23;usd.ivecf[b;3];t=27;usd.ivecf[b;4];
    t=21;usd.ivecf[b;2];t=25;usd.ivecf[b;3];t=29;usd.ivecf[b;4];
    t=22;usd.iveci[b;2];t=26;usd.iveci[b;3];t=30;usd.iveci[b;4];
    (`usdc.inl;t;usd.u32 b@!4)]}

/ uncompressed-array element descriptor: (components;elembytes;kind)
/ kind: 0 int32  1 float32  2 float64  3 token  -1 unsupported
usd.compinfo:{[t]
  $[t=3;(1;4;0);t=4;(1;4;0);
    t=8;(1;4;1);t=9;(1;8;2);t=11;(1;4;3);
    t=20;(2;4;1);t=24;(3;4;1);t=28;(4;4;1);
    t=22;(2;4;0);t=26;(3;4;0);t=30;(4;4;0);
    t=19;(2;8;2);t=23;(3;8;2);t=27;(4;8;2);
    (0;0;-1)]}
usd.elem:{[k;eb;raw;i]c:raw@(eb*i)+!eb;$[k=0;usd.i32 c;k=1;usd.f32 c;k=2;usd.f64 c;usd.tok@usd.u32 c]}

usd.uarray2:{[n;c;eb;k]tot:n*c;raw:usd.bytes tot*eb;flat:usd.elem[k;eb;raw;]'!tot;$[c=1;flat;(n;c)#flat]}
usd.uarray:{[t;n]ci:usd.compinfo t;c:ci@0;eb:ci@1;k:ci@2;$[k<0;(`usdc.arr;t;n);usd.uarray2[n;c;eb;k]]}

usd.carray:{[t;n]csz:usd.rdu64[];comp:usd.bytes csz;$[$[t=3;1;t=4;1;0];usd.intdec[comp;n];(`usdc.carr;t;n)]}
usd.array:{[t;cmp;pay]usd.p::pay;n:usd.rdu64[];$[cmp;usd.carray[t;n];usd.uarray[t;n]]}

/ token / path vector (non-array container of tokens)
usd.tvat:{[i]usd.tok@usd.u32 usd.tvraw@(4*i)+!4}
usd.tokvec:{[pay]usd.p::pay;n:usd.rdu64[];usd.tvraw::usd.bytes 4*n;usd.tvat'!n}
usd.svat:{[i]usd.f32 usd.svraw@(4*i)+!4}
usd.scalvecf:{[pay;n]usd.p::pay;usd.svraw::usd.bytes 4*n;usd.svat'!n}
usd.rdf64at:{usd.p::x;usd.f64 usd.bytes 8}

/ dictionary (VtDictionary): numPairs, then per pair
/   uint32 keyStringIndex | uint64 valueSize | <valueSize bytes>
/ valueSize==8 is a single ValueRep; inline scalar values are decoded, while
/ out-of-line reps and nested buffers (arrays / sub-dicts) are tagged.
usd.ddstep:{[x]
  k:usd.tok@usd.strs@usd.rdu32[];
  vsz:usd.rdu64[];rep:usd.bytes vsz;
  v:$[vsz=8;$[0<(((rep@7)div 64)mod 2);usd.inl[rep@6;rep];(`usdc.dval;rep@6)];(`usdc.dbuf;vsz)];
  usd.ddk::usd.ddk,k;usd.ddv::usd.ddv,(,v);
  ((x@0)+1;x@1)}
usd.rddict:{[off]
  usd.p::off;n:usd.rdu64[];usd.ddk::`s$();usd.ddv::();
  ({(x@0)<(x@1)}){usd.ddstep x}/(0;n);
  $[n;(,/usd.ddk)!usd.ddv;(`s$())!()]}            / raze keys -> S vector

usd.ref:{[t;arr;cmp;pay]
  $[arr;usd.array[t;cmp;pay];
    t=31;usd.rddict pay;
    t=41;usd.tokvec pay;
    t=9;usd.rdf64at pay;
    t=24;usd.scalvecf[pay;3];
    t=28;usd.scalvecf[pay;4];
    t=20;usd.scalvecf[pay;2];
    (`usdc.ref;t;pay)]}

usd.value:{[b]
  t:b@6;fl:b@7;
  inl:0<(fl div 64)mod 2;
  arr:0<fl div 128;
  cmp:0<(fl div 32)mod 2;
  pay:usd.u32 b@!4;
  $[inl;usd.inl[t;b];usd.ref[t;arr;cmp;pay]]}

/ --- spec assembly -----------------------------------------------------------
usd.fsrun:{[fsi]usd.fsacc::!0;({~(usd.fset@x)=-1}){usd.fsacc::usd.fsacc,usd.fset@x;x+1}/fsi;usd.fsacc}
usd.fldname:{[id]usd.tok@usd.fldtok@id}
usd.fldval:{[id]usd.value usd.repl@id}
usd.specfields:{[i]ids:usd.fsrun usd.sfset@i;$[#ids;(usd.fldname'ids)!(usd.fldval'ids);(`s$())!()]}

/ --- entry point -------------------------------------------------------------
usd.secname:{[i]`s$usd.cstr usd.b@(usd.toc0+8+32*i)+!16}
usd.secstart:{[i]usd.u32 usd.b@(usd.toc0+8+(32*i)+16)+!4}
usd.rdtoc:{ns:usd.u32 usd.b@usd.toc0+!4;(usd.secname'!ns)!(usd.secstart'!ns)}

usd.pathof:{usd.pth@x}                            / usd.pth is already a symbol vector
ReadUsdc:{[path]
  usd.b::`i$1:path;
  usd.toc0::usd.u32 usd.b@16+!4;
  sec:usd.rdtoc[];
  usd.rdtokens sec@`TOKENS;
  usd.rdstrings sec@`STRINGS;
  usd.rdfields sec@`FIELDS;
  usd.rdfsets sec@`FIELDSETS;
  usd.rdpaths sec@`PATHS;
  usd.rdspecs sec@`SPECS;
  np:#usd.spidx;
  paths:usd.pathof'usd.spidx;
  types:usd.stypename'usd.stype;
  flds:usd.specfields'!np;
  +`path`spec`fields!(paths;types;flds)}

/ --- table accessors ---------------------------------------------------------
/ usd.find[t;"/some/path"] -> the fields dict for that spec (or () if missing)
/ (paths contain "/" so pass them as strings; they are matched against `path)
usd.find:{[t;p]s:`s$$[`c~@p;,p;p];m:&(t`path)~\:s;$[#m;(t`fields)@*m;()]}
/ usd.attr[t;"/p";`field] -> a single field value
usd.attr:{[t;p;f](usd.find[t;p])@f}
/ usd.kind[t;`Prim] -> sub-table of rows of that spec type
usd.kind:{[t;k]t@&(t`spec)~\:k}
