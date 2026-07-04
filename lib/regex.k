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
/ The pipeline is split into private sub-namespaces:
/   regex.token    pattern string → token stream
/   regex.postfix  token stream → postfix (concat insertion + shunting yard)
/   regex.nfa      postfix → NFA program (Thompson construction)
/   regex.vm       run an NFA program against a string (Pike VM)
/
/ Supported syntax:
/   . * + ? | ( ) [ ] [^] [a-z] \d \w \s \D \W \S ^ $
/
/ NFA opcodes: 0=CHAR 1=ANY 2=CLASS 3=SPLIT 4=JUMP 5=MATCH 6=SOL 7=EOL
/ All instructions use explicit next-PC in arg2 (no fall-through).
/ Program dict: [ops;a1;a2;cls;start]

/ ── public API ────────────────────────────────────────────────────────────────
\d regex compile test find all sub suball

fProg:()!(); fStr:""; fN:0; fRes:!0
aProg:()!(); aStr:""; aN:0; aRes:()
subRep:""

splice: {[str;s;l;rep] (s#str),rep,((s+l)_str)}

findCond: {(~x>fN)&~#fRes}
findStep: {[pos]
  r: vm.matchAt[fProg;fStr;pos]
  $[~r=-1; fRes::(pos;r-pos); 0]
  pos+1
}

allCond: {~x>aN}
allAppend: {[pos;endPos]
  aRes::aRes,,(pos;endPos-pos)
  $[endPos>pos; endPos; pos+1]
}

compile: {[pat]
  toks: token.scan[pat]
  pf: postfix.build[toks@0;toks@1]
  nfa.build[pf@0;pf@1;toks@2]
}

test: {[prog;str] (vm.matchAt[prog;str;0])=#str}

find: {[prog;str]
  fProg::prog; fStr::"",str; fN::#fStr; fRes::!0
  findCond{findStep[x]}/0
  fRes
}

all: {[prog;str]
  aProg::prog; aStr::"",str; aN::#aStr; aRes::()
  allCond{r:vm.matchAt[aProg;aStr;x]; $[~r=-1; allAppend[x;r]; x+1]}/0
  aRes
}

sub: {[prog;str;rep]
  m: find[prog;str]
  $[#m; splice[str;m@0;m@1;rep]; str]
}

suball: {[prog;str;rep]
  ms: all[prog;str]
  subRep::rep
  $[#ms; {splice[x;y@0;y@1;subRep]}/[str;|ms]; str]
}

/ ── tokenizer ─────────────────────────────────────────────────────────────────
/ Token types: 0=CHAR 1=ANY 2=CLASS 3=STAR 4=PLUS 5=QUEST 6=OR 7=LPAREN 8=RPAREN 9=SOL 10=EOL
\d regex.token scan

pat:""; n:0; pos:0; types:!0; vals:!0; cls:(); curCls:256#,0b; neg:0b

/ character classes (256-element boolean vectors, indexed by char code)
digit: (~(48>!256))&~((!256)>57)
alpha: ((~(65>!256))&~((!256)>90))|(~(97>!256))&~((!256)>122)
word:  digit|alpha|(!256)=95
space: ((!256)=32)|((!256)=9)|((!256)=10)|((!256)=13)

emitAdv: {[t;v] types::types,t; vals::vals,v; pos::pos+1; 0}
emitCls: {[c] types::types,2; vals::vals,#cls; cls::cls,,c; pos::pos+1; 0}
escLit:  {[cv] types::types,0; vals::vals,cv; pos::pos+1; 0}

escape: {
  pos::pos+1
  c: `i$(pat@pos)
  $[c=100; emitCls[digit];
    c=68;  emitCls[~digit];
    c=119; emitCls[word];
    c=87;  emitCls[~word];
    c=115; emitCls[space];
    c=83;  emitCls[~space];
    escLit[c]]
}

/ Character class [...]
ccRange:  {[lo] hi: `i$(pat@(pos+2)); curCls::curCls|(~(lo>!256))&~((!256)>hi); pos::pos+3; 0}
ccSingle: {[lo] curCls::@[curCls;lo;:;1b]; pos::pos+1; 0}
ccStep: {
  lo: `i$(pat@pos)
  $[((pos+2)<n)&((`i$(pat@(pos+1)))=45)&~((`i$(pat@(pos+2)))=93);
    ccRange[lo];
    ccSingle[lo]]
}
ccCond: {~(`i$(pat@pos))=93}
charClass: {
  pos::pos+1
  neg:: (`i$(pat@pos))=94
  $[neg; pos::pos+1; 0]
  curCls:: 256#,0b
  ccCond{ccStep[]; x+1}/0
  $[neg; curCls::~curCls; 0]
  types::types,2
  vals::vals,#cls
  cls::cls,,curCls
  pos::pos+1
  0
}

tokStep: {
  c: `i$(pat@pos)
  $[c=92;  escape[];
    c=46;  emitAdv[1;0];
    c=42;  emitAdv[3;0];
    c=43;  emitAdv[4;0];
    c=63;  emitAdv[5;0];
    c=124; emitAdv[6;0];
    c=40;  emitAdv[7;0];
    c=41;  emitAdv[8;0];
    c=94;  emitAdv[9;0];
    c=36;  emitAdv[10;0];
    c=91;  charClass[];
    emitAdv[0;c]]
}

tokCond: {pos<n}
scan: {[p]
  pat::"",p; n::#pat; pos::0
  types::!0; vals::!0; cls::()
  tokCond{tokStep[]; x+1}/0
  (types;vals;cls)
}

/ ── token stream → postfix ───────────────────────────────────────────────────
/ First insert explicit CONCAT (type 12), then run the shunting-yard.
\d regex.postfix build

cTypes:!0; cVals:!0; cN:0; ct:!0; cv:!0
srcT:!0; srcV:!0; outT:!0; outV:!0; opStk:!0; prec:0; syT:0; syV:0

/ insert explicit CONCAT (type 12)
canEnd:   0 1 2 3 4 5 8 9 10
canStart: 0 1 2 7 9 10
concatStep: {[i]
  t: cTypes@i; v: cVals@i
  prev: *|ct
  nc: (prev in canEnd)&t in canStart
  ct:: ct,$[nc;(12;t);,t]
  cv:: cv,$[nc;(0;v);,v]
  0
}
insertConcatDo: {[types;vals]
  cTypes::types; cVals::vals; cN::#cTypes
  ct::,cTypes@0; cv::,cVals@0
  $[cN>1; concatStep'1+!cN-1; 0]
  (ct;cv)
}
insertConcat: {[types;vals]
  $[#types; insertConcatDo[types;vals]; (types;vals)]
}

/ shunting-yard → postfix
precedence: {$[x=12; 2; x=6; 1; 0]}

popToOut: {
  op: *|opStk; opStk::(-1)_opStk
  outT::outT,op; outV::outV,0
  0
}

rparenCond: {(#opStk)&~(*|opStk)=7}
rparen: {
  rparenCond{popToOut[]; x+1}/0
  $[#opStk; opStk::(-1)_opStk; 0]
  0
}

binopCond: {(#opStk)&(~(*|opStk)=7)&~(precedence[*|opStk])<prec}
binop: {
  prec::$[syT=12; 2; 1]
  binopCond{popToOut[]; x+1}/0
  opStk::opStk,syT
  0
}

atom: {outT::outT,syT; outV::outV,syV; 0}

syStep: {[i]
  syT::srcT@i; syV::srcV@i
  $[syT in 0 1 2 3 4 5 9 10; atom[];
    syT=7; {opStk::opStk,7; 0}[];
    syT=8; rparen[];
    binop[]]
}

toPostfix: {[types;vals]
  srcT::types; srcV::vals
  outT::!0; outV::!0; opStk::!0
  syStep'!#srcT
  outT::outT,|opStk
  outV::outV,(#opStk)#0
  opStk::!0
  (outT;outV)
}

build: {[types;vals]
  tv: insertConcat[types;vals]
  toPostfix[tv@0;tv@1]
}

/ ── Thompson NFA compiler (postfix → bytecode) ───────────────────────────────
/ Fragment = (start; patches) where patches encodes patch points.
/ Encoding: pc*2+bit, bit 0=arg1 1=arg2.
\d regex.nfa build

ops:!0; arg1:!0; arg2:!0; clsTab:(); frags:(); pTypes:!0; pVals:!0

emit: {[op;a1;a2] i:#ops; ops::ops,op; arg1::arg1,a1; arg2::arg2,a2; i}

patchAll: {[patches;target]
  idx: patches div 2; ab: patches mod 2
  a1i: idx@&~ab; a2i: idx@&ab
  $[#a1i; arg1::@[arg1;a1i;:;target]; 0]
  $[#a2i; arg2::@[arg2;a2i;:;target]; 0]
  0
}

push: {[f] frags::frags,,f; 0}
pop:  {f:frags@(#frags)-1; frags::(-1)_frags; f}

atom:   {[op;v] pc:emit[op;v;-1]; push[(pc; ,(pc*2)+1)]}
concat: {f2:pop[]; f1:pop[]; patchAll[f1@1;f2@0]; push[(f1@0;f2@1)]}
alt:    {f2:pop[]; f1:pop[]; s:emit[3;f1@0;f2@0]; push[(s;(f1@1),(f2@1))]}
star:   {f:pop[]; s:emit[3;f@0;-1]; patchAll[f@1;s]; push[(s;,(s*2)+1)]}
plus:   {f:pop[]; s:emit[3;f@0;-1]; patchAll[f@1;s]; push[(f@0;,(s*2)+1)]}
quest:  {f:pop[]; s:emit[3;f@0;-1]; push[(s;(f@1),(s*2)+1)]}

compStep: {[i]
  t: pTypes@i; v: pVals@i
  $[t=0;  atom[0;v];
    t=1;  atom[1;0];
    t=2;  atom[2;v];
    t=9;  atom[6;0];
    t=10; atom[7;0];
    t=3;  star[];
    t=4;  plus[];
    t=5;  quest[];
    t=12; concat[];
    t=6;  alt[];
    0]
}

finish: {
  f: *|frags
  m: emit[5;0;0]
  patchAll[f@1;m]
  [ops:ops;a1:arg1;a2:arg2;cls:clsTab;start:f@0]
}
finishEmpty: {
  m: emit[5;0;0]
  [ops:ops;a1:arg1;a2:arg2;cls:clsTab;start:m]
}

build: {[types;vals;cls]
  ops::!0; arg1::!0; arg2::!0; clsTab::cls; frags::()
  pTypes::types; pVals::vals
  compStep'!#pTypes
  $[#frags; finish[]; finishEmpty[]]
}

/ ── NFA execution (Pike VM) ──────────────────────────────────────────────────
\d regex.vm matchAt

ops:!0; a1:!0; a2:!0; cls:(); s:""; slen:0; epos:0

matchCond: {(x@2)<slen}

epsClosure: {[pcs;pos]
  epos::pos
  expanded: {
    o: ops@x
    next: ((a1@x)@&o=3),((a2@x)@&o=3),((a1@x)@&o=4),((a2@x)@&(o=6)&epos=0),((a2@x)@&(o=7)&epos=slen)
    ?x,next
  }/pcs
  o: ops@expanded
  expanded@&(o<3)|o=5
}

hasMatch: {$[#x; 0<#&(ops@x)=5; 0b]}

step: {[pcs;pos]
  o: ops@pcs; chCode: `i$(s@pos)
  matchChar: (o=0)&(a1@pcs)=chCode
  matchAny: o=1
  matched: $[#cls;
    matchChar|matchAny|((o=2)&(+(cls@((a1@pcs) mod #cls)))@chCode);
    matchChar|matchAny]
  nextPcs: (a2@pcs)@&matched
  $[#nextPcs; epsClosure[nextPcs;pos+1]; !0]
}

stepUpdate: {[pcs;pos;prevLm]
  np: step[pcs;pos]
  nm: $[(#np)&hasMatch[np]; pos+1; prevLm]
  (np;nm;pos+1)
}

advance: {[st]
  $[#st 0; stepUpdate[st 0;st 2;st 1]; (st 0;st 1;slen)]
}

matchAt: {[prog;str;start]
  ops::prog`ops; a1::prog`a1; a2::prog`a2
  cls::prog`cls; s::"",str; slen::#s
  initPcs: $[start>slen; !0; epsClosure[,prog`start;start]]
  lm: $[hasMatch[initPcs]; start; -1]
  st: (initPcs;lm;start)
  r: matchCond{advance[x]}/st
  r@1
}
