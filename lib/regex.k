/ regex.k — Pure-k regex engine (Thompson NFA / Pike VM)
/
/ Public API:
/   ReCompile[pat]           compile regex pattern string to NFA program
/   ReTest[prog;str]         1b if full match
/   ReFind[prog;str]         (start;len) of first match, or !0
/   ReAll[prog;str]          list of (start;len) for all non-overlapping matches
/   ReSub[prog;str;rep]      replace first match
/   ReSubAll[prog;str;rep]   replace all matches
/
/ Supported syntax:
/   . * + ? | ( ) [ ] [^] [a-z] \d \w \s \D \W \S ^ $
/
/ NFA opcodes: 0=CHAR 1=ANY 2=CLASS 3=SPLIT 4=JUMP 5=MATCH 6=SOL 7=EOL
/ All instructions use explicit next-PC in arg2 (no fall-through).
/ Program dict: [ops;a1;a2;cls;start]

/ ── public API ────────────────────────────────────────────────────────────────
reFindCond: {(~x>rfN)&~#rfResult}
raAllCond: {~x>raN}
reSplice: {[str;s;l;rep] (s#str),rep,((s+l)_str)}

reFindStep: {[pos]
  r: ReMatchAt[rfProg;rfStr;pos]
  $[~r=-1; rfResult::(pos;r-pos); 0]
  pos+1
}
raAppend: {[pos;endPos]
  raResult::raResult,,(pos;endPos-pos)
  $[endPos>pos; endPos; pos+1]
}

ReTest: {[prog;str] (ReMatchAt[prog;str;0])=#str}

ReFind: {[prog;str]
  rfProg::prog; rfStr::"",str; rfN::#rfStr; rfResult::!0
  reFindCond{reFindStep[x]}/0
  rfResult
}

ReAll: {[prog;str]
  raProg::prog; raStr::"",str; raN::#raStr; raResult::()
  raAllCond{r:ReMatchAt[raProg;raStr;x]; $[~r=-1; raAppend[x;r]; x+1]}/0
  raResult
}

ReSub: {[prog;str;rep]
  m: ReFind[prog;str]
  $[#m; reSplice[str;m@0;m@1;rep]; str]
}

ReSubAll: {[prog;str;rep]
  ms: ReAll[prog;str]
  rsaRep::rep
  $[#ms; {reSplice[x;y@0;y@1;rsaRep]}/[str;|ms]; str]
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
ReCompile: {[pat]
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

rmMatchCond: {(x@2)<rmSlen}
ReMatchAt: {[prog;str;start]
  rmOps::prog`ops; rmA1::prog`a1; rmA2::prog`a2
  rmCls::prog`cls; rmStr::"",str; rmSlen::#rmStr
  initPcs: $[start>rmSlen; !0; rmEpsClosure[,prog`start;start]]
  lm: $[rmHasMatch[initPcs]; start; -1]
  st: (initPcs;lm;start)
  r: rmMatchCond{rmAdvance[x]}/st
  r@1
}
