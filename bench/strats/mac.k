/ Section 1: Moving Average Crossover. 190 (h1,h2) pairs over ~1255 closes.
/ Adapted from strats/ink.k:
/   - drop trailing empty line (-1_ before @\:)
/   - use 0.0 instead of 0 where joining onto float arrays (ink doesn't
/     auto-promote int→float on concat)
a:","\'0:<`"../../strats/HistDataAPPLE.csv"
prc:|0.0,.'1_'1_-1_a@\:1

ma:{[w;x]s:0.0,+\x;n:1+(#x)-w;((w-1)#0.0),-1_(s[w+!n]-s[!n])%w}
mastr:{[h1;h2;p]s:-1_ 0.0,((ma[h1;p])>ma[h2;p]);r:0.0,1_-':log -1_ p
  c:0.0,0.0005*1_1=+':s;t:((r*s)-c)
  100*(exp(+/t))-1}

\t *v[>v:{[j](mastr[j[0];j[1];prc];j[0];j[1])}',/{[x]x,'1_!x}'1_!20]
