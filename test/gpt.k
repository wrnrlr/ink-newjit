text:1:"./test/data/shakespear.txt"

tokenize: {?x@<x}
chars:tokenize text
N:#chars
`0:"Unique chars: ",$N

encode:chars!!N
decode:(!N)!chars
data:encode text
/ `0:"Data length: ",$#data

n:_0.9*#data
(td;vd):(0,n)_data
cs:!8 / context size
ctx:td cs
next:td 1+cs

/ `0:"cs ",$c
/ `0:"td ",$td
`0:"ctx ",$ctx

{(ctx[!x+1];next[x])}'cs

bs:4 / batch size
batch:{[split]
  d:$[split;td;vd];l:#d
  ix: / 4 numbers
}

/ offsets
