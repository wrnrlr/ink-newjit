/ Section 3: Relative Strength Index. Windows 2..39, threshold 30.
a:","\'0:<`"../../strats/HistDataAPPLE.csv"
prc:|0.0,.'1_'1_-1_a@\:1

rsima:{[w;x]s:0.0,+\x;n:1+(#x)-w;((w-1)#0.0),(s[w+!n]-s[!n])%w}
rsistrat:{[w;tr;p]d:p--1_ (*p),p;u:d*(d>0.0);dw:(0.0-d)*(0.0>d)
  au:rsima[w;u];ad:rsima[w;dw];rs:au%(ad+10e-4);rsi:100.0-(100.0%(1.0+rs))
  s:-1_ 0.0,((tr>rsi)*((au+ad)>0.0));c:0.0,0.0005*1_1=+':s;r:0.0,1_-':log p
  t:(r*s)-c;100*(exp(+/-1_t))-1}

\t *a[>a:{[x](rsistrat[x;30;prc];x)}'2_!40]
