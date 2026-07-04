/ regex.k — Pure-k regex engine (Thompson NFA / Pike VM)
/
/ Public API:
/   regex.compile[pat]         compile regex pattern string to NFA program
/   regex.test[prog;str]       1b if full match
/   regex.find[prog;str]       (start;len) of first match, or !0
/   regex.all[prog;str]        list of (start;len) for all non-overlapping matches
/   regex.sub[prog;str;rep]    replace first match
/   regex.suball[prog;str;rep] replace all matches
/
/ Everything else is a private member of the `regex` namespace.
/
/ Supported syntax:
/   . * + ? | ( ) [ ] [^] [a-z] \d \w \s \D \W \S ^ $
/
/ NFA opcodes: 0=CHAR 1=ANY 2=CLASS 3=SPLIT 4=JUMP 5=MATCH 6=SOL 7=EOL
/ All instructions use explicit next-PC in arg2 (no fall-through).
/ Program dict: [ops;a1;a2;cls;start]

\d regex compile test find all sub suball

/ ── forward-declared mutable state ───────────────────────────────────────────
/ These module globals are written only inside lambda bodies via `::`. Declaring
/ them at the top of the namespace makes the compiler's member pre-pass register
/ each as `regex.<name>`, so reads and writes resolve to the same qualified slot
/ (a bare `::` assign always mangles to the namespace; a read only mangles once
/ the qualified global exists). Values here are placeholders — every public entry
/ point resets the state it uses before reading it.
rA1:0; rA2:0; raN:0; raProg:0; raResult:0; raStr:0; rCls:0
rcpTypes:0; rcpVals:0; rePos:0; reSyPrec:0; reSyT:0; reSyV:0
rfN:0; rfProg:0; rFrags:0; rfResult:0; rfStr:0; ricN:0; rict:0
ricTypes:0; ricv:0; ricVals:0; rmA1:0; rmA2:0; rmCls:0; rmOps:0
rmSlen:0; rmStr:0; rOps:0; rpOps:0; rpOutT:0; rpOutV:0; rpSrcT:0
rpSrcV:0; rsaRep:0; rtCls:0; rtCurCls:0; rti:0; rtN:0; rtNeg:0
rtPat:0; rtTypes:0; rtVals:0

/ ── public API ────────────────────────────────────────────────────────────────
findCond: {(~x>rfN)&~#rfResult}
allCond: {~x>raN}
splice: {[str;s;l;rep] (s#str),rep,((s+l)_str)}

matchCond: {(x@2)<rmSlen}

matchAt: {[prog;str;start]
  rmOps::prog`ops; rmA1::prog`a1; rmA2::prog`a2
  rmCls::prog`cls; rmStr::"",str; rmSlen::#rmStr
  initPcs: $[start>rmSlen; !0; rmEpsClosure[,prog`start;start]]
  lm: $[rmHasMatch[initPcs]; start; -1]
  st: (initPcs;lm;start)
  r: matchCond{rmAdvance[x]}/st
  r@1
}


findStep: {[pos]
  r: matchAt[rfProg;rfStr;pos]
  $[~r=-1; rfResult::(pos;r-pos); 0]
  pos+1
}
raAppend: {[pos;endPos]
  raResult::raResult,,(pos;endPos-pos)
  $[endPos>pos; endPos; pos+1]
}

test: {[prog;str] (matchAt[prog;str;0])=#str}

find: {[prog;str]
  rfProg::prog; rfStr::"",str; rfN::#rfStr; rfResult::!0
  findCond{findStep[x]}/0
  rfResult
}

all: {[prog;str]
  raProg::prog; raStr::"",str; raN::#raStr; raResult::()
  allCond{r:matchAt[raProg;raStr;x]; $[~r=-1; raAppend[x;r]; x+1]}/0
  raResult
}

sub: {[prog;str;rep]
  m: find[prog;str]
  $[#m; splice[str;m@0;m@1;rep]; str]
}

suball: {[prog;str;rep]
  ms: all[prog;str]
  rsaRep::rep
  $[#ms; {splice[x;y@0;y@1;rsaRep]}/[str;|ms]; str]
}

/ ── character classes (256-element boolean vectors, indexed by char code) ─────
reDigit: (~(48>!256))&~((!256)>57)
reAlpha: ((~(65>!256))&~((!256)>90))|(~(97>!256))&~((!256)>122)
reWord: reDigit|reAlpha|(!256)=95
reSpace: ((!256)=32)|((!256)=9)|((!256)=10)|((!256)=13)

/ ── tokenizer ─────────────────────────────────────────────────────────────────
/ Token types: 0=CHAR 1=ANY 2=CLASS 3=STAR 4=PLUS 5=QUEST 6=OR 7=LPAREN 8=RPAREN 9=SOL 10=EOL

rtEmitAdv: {[t;v] rtTypes::rtTypes,t; rtVals::rtVals,v; rti::rti+1; 0}
rtEmitCls: {[cls] rtTypes::rtTypes,2; rtVals::rtVals,#rtCls; rtCls::rtCls,,cls; rti::rti+1; 0}
rtEscLit: {[cv] rtTypes::rtTypes,0; rtVals::rtVals,cv; rti::rti+1; 0}

rtEscape: {
  rti::rti+1
  c: `i$(rtPat@rti)
  $[c=100; rtEmitCls[reDigit];
    c=68;  rtEmitCls[~reDigit];
    c=119; rtEmitCls[reWord];
    c=87;  rtEmitCls[~reWord];
    c=115; rtEmitCls[reSpace];
    c=83;  rtEmitCls[~reSpace];
    rtEscLit[c]]
}

/ Character class [...]
rtCcRange: {[lo] hi: `i$(rtPat@(rti+2)); rtCurCls::rtCurCls|(~(lo>!256))&~((!256)>hi); rti::rti+3; 0}
rtCcSingle: {[lo] rtCurCls::@[rtCurCls;lo;:;1b]; rti::rti+1; 0}
rtCcStep: {
  lo: `i$(rtPat@rti)
  $[((rti+2)<rtN)&((`i$(rtPat@(rti+1)))=45)&~((`i$(rtPat@(rti+2)))=93);
    rtCcRange[lo];
    rtCcSingle[lo]]
}
rtCcCond: {~(`i$(rtPat@rti))=93}
rtCharClass: {
  rti::rti+1
  rtNeg:: (`i$(rtPat@rti))=94
  $[rtNeg; rti::rti+1; 0]
  rtCurCls:: 256#(,0b)
  rtCcCond{rtCcStep[]; x+1}/0
  $[rtNeg; rtCurCls::~rtCurCls; 0]
  rtTypes::rtTypes,2
  rtVals::rtVals,#rtCls
  rtCls::rtCls,,rtCurCls
  rti::rti+1
  0
}

rtTokStep: {
  c: `i$(rtPat@rti)
  $[c=92;  rtEscape[];
    c=46;  rtEmitAdv[1;0];
    c=42;  rtEmitAdv[3;0];
    c=43;  rtEmitAdv[4;0];
    c=63;  rtEmitAdv[5;0];
    c=124; rtEmitAdv[6;0];
    c=40;  rtEmitAdv[7;0];
    c=41;  rtEmitAdv[8;0];
    c=94;  rtEmitAdv[9;0];
    c=36;  rtEmitAdv[10;0];
    c=91;  rtCharClass[];
    rtEmitAdv[0;c]]
}

rtTokCond: {rti<rtN}
ReTok: {[pat]
  rtPat::"",pat; rtN::#rtPat; rti::0
  rtTypes::!0; rtVals::!0; rtCls::()
  rtTokCond{rtTokStep[]; x+1}/0
  (rtTypes;rtVals;rtCls)
}

/ ── insert explicit CONCAT (type 12) ─────────────────────────────────────────
ricCanEnd: 0 1 2 3 4 5 8 9 10
ricCanStart: 0 1 2 7 9 10
ricStep: {[i]
  t: ricTypes@i; v: ricVals@i
  prev: *|rict
  nc: (prev in ricCanEnd)&t in ricCanStart
  rict:: rict,$[nc;(12;t);,t]
  ricv:: ricv,$[nc;(0;v);,v]
  0
}
reInsertConcatDo: {[types;vals]
  ricTypes::types; ricVals::vals; ricN::#ricTypes
  rict::,ricTypes@0; ricv::,ricVals@0
  $[ricN>1; ricStep'1+!ricN-1; 0]
  (rict;ricv)
}
reInsertConcat: {[types;vals]
  $[#types; reInsertConcatDo[types;vals]; (types;vals)]
}

/ ── shunting-yard → postfix ───────────────────────────────────────────────────
rePrecedence: {$[x=12; 2; x=6; 1; 0]}

reSyPopToOut: {
  op: *|rpOps; rpOps::(-1)_rpOps
  rpOutT::rpOutT,op; rpOutV::rpOutV,0
  0
}

reSyRparenCond: {(#rpOps)&~(*|rpOps)=7}
reSyRparen: {
  reSyRparenCond{reSyPopToOut[]; x+1}/0
  $[#rpOps; rpOps::(-1)_rpOps; 0]
  0
}

reSyBinopCond: {(#rpOps)&(~(*|rpOps)=7)&~(rePrecedence[*|rpOps])<reSyPrec}
reSyBinop: {
  reSyPrec::$[reSyT=12; 2; 1]
  reSyBinopCond{reSyPopToOut[]; x+1}/0
  rpOps::rpOps,reSyT
  0
}

reSyAtom: {rpOutT::rpOutT,reSyT; rpOutV::rpOutV,reSyV; 0}

reSyStep: {[i]
  reSyT::rpSrcT@i; reSyV::rpSrcV@i
  $[reSyT in 0 1 2 3 4 5 9 10; reSyAtom[];
    reSyT=7; {rpOps::rpOps,7; 0}[];
    reSyT=8; reSyRparen[];
    reSyBinop[]]
}

reToPostfix: {[types;vals]
  rpSrcT::types; rpSrcV::vals
  rpOutT::!0; rpOutV::!0; rpOps::!0
  reSyStep'!#rpSrcT
  rpOutT::rpOutT,|rpOps
  rpOutV::rpOutV,(#rpOps)#0
  rpOps::!0
  (rpOutT;rpOutV)
}

/ ── Thompson NFA compiler (postfix → bytecode) ───────────────────────────────
/ Fragment = (start; patches) where patches encodes patch points.
/ Encoding: pc*2+bit, bit 0=arg1 1=arg2.

rEmitInst: {[op;a1;a2] i:#rOps; rOps::rOps,op; rA1::rA1,a1; rA2::rA2,a2; i}

rPatchAll: {[patches;target]
  idx: patches div 2; ab: patches mod 2
  a1i: idx@&~ab; a2i: idx@&ab
  $[#a1i; rA1::@[rA1;a1i;:;target]; 0]
  $[#a2i; rA2::@[rA2;a2i;:;target]; 0]
  0
}

rPush: {[f] rFrags::rFrags,,f; 0}
rPop: {f:rFrags@(#rFrags)-1; rFrags::(-1)_rFrags; f}

rcpAtom: {[op;v] pc:rEmitInst[op;v;-1]; rPush[(pc; ,(pc*2)+1)]}
rcpConcat: {f2:rPop[]; f1:rPop[]; rPatchAll[f1@1;f2@0]; rPush[(f1@0;f2@1)]}
rcpAlt: {f2:rPop[]; f1:rPop[]; s:rEmitInst[3;f1@0;f2@0]; rPush[(s;(f1@1),(f2@1))]}
rcpStar: {f:rPop[]; s:rEmitInst[3;f@0;-1]; rPatchAll[f@1;s]; rPush[(s;,(s*2)+1)]}
rcpPlus: {f:rPop[]; s:rEmitInst[3;f@0;-1]; rPatchAll[f@1;s]; rPush[(f@0;,(s*2)+1)]}
rcpQuest: {f:rPop[]; s:rEmitInst[3;f@0;-1]; rPush[(s;(f@1),(s*2)+1)]}

rcpCompStep: {[i]
  t: rcpTypes@i; v: rcpVals@i
  $[t=0;  rcpAtom[0;v];
    t=1;  rcpAtom[1;0];
    t=2;  rcpAtom[2;v];
    t=9;  rcpAtom[6;0];
    t=10; rcpAtom[7;0];
    t=3;  rcpStar[];
    t=4;  rcpPlus[];
    t=5;  rcpQuest[];
    t=12; rcpConcat[];
    t=6;  rcpAlt[];
    0]
}

rcpFinish: {
  f: *|rFrags
  m: rEmitInst[5;0;0]
  rPatchAll[f@1;m]
  [ops:rOps;a1:rA1;a2:rA2;cls:rCls;start:f@0]
}
rcpFinishEmpty: {
  m: rEmitInst[5;0;0]
  [ops:rOps;a1:rA1;a2:rA2;cls:rCls;start:m]
}

reCompPost: {[types;vals;cls]
  rOps::!0; rA1::!0; rA2::!0; rCls::cls; rFrags::()
  rcpTypes::types; rcpVals::vals
  rcpCompStep'!#rcpTypes
  $[#rFrags; rcpFinish[]; rcpFinishEmpty[]]
}

/ ── public compile ────────────────────────────────────────────────────────────
compile: {[pat]
  toks: ReTok[pat]
  tv: reInsertConcat[toks@0;toks@1]
  pf: reToPostfix[tv@0;tv@1]
  reCompPost[pf@0;pf@1;toks@2]
}

/ ── NFA execution ─────────────────────────────────────────────────────────────

rmEpsClosure: {[pcs;pos]
  rePos::pos
  expanded: {
    o: rmOps@x
    next: ((rmA1@x)@&o=3),((rmA2@x)@&o=3),((rmA1@x)@&o=4),((rmA2@x)@&(o=6)&rePos=0),((rmA2@x)@&(o=7)&rePos=rmSlen)
    ?x,next
  }/pcs
  o: rmOps@expanded
  expanded@&(o<3)|o=5
}

rmHasMatch: {$[#x; 0<#&(rmOps@x)=5; 0b]}

rmStep: {[pcs;pos]
  o: rmOps@pcs; chCode: `i$(rmStr@pos)
  matchChar: (o=0)&(rmA1@pcs)=chCode
  matchAny: o=1
  matched: $[#rmCls;
    matchChar|matchAny|((o=2)&(+(rmCls@((rmA1@pcs) mod #rmCls)))@chCode);
    matchChar|matchAny]
  nextPcs: (rmA2@pcs)@&matched
  $[#nextPcs; rmEpsClosure[nextPcs;pos+1]; !0]
}

rmStepAndUpdate: {[pcs;pos;prevLm]
  np: rmStep[pcs;pos]
  nm: $[(#np)&rmHasMatch[np]; pos+1; prevLm]
  (np;nm;pos+1)
}

rmAdvance: {[st]
  $[#st@0; rmStepAndUpdate[st@0;st@2;st@1]; (st@0;st@1;rmSlen)]
}
