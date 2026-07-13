
text:1:"./test/data/shakespear.txt"
chars:{x@<x}@!=text;
N:#chars;
encode:chars!!N;
decode:(!N)!chars;
data:encode text
n:_0.9*#data
(td;vd):(0,n)_data
cs:!8 / context size
ctx:td cs
next:td 1+cs
{ctx[!t+1];target[t]}'cs

bs:4 / batch size
batch:{[split]
  d:$[split;td;vd];l:#d
  ix: / 4 numbers
  }

offsets
