/ Section 2: Z-Score Mean Reversion. Windows 1..99, threshold 2.
a:","\'0:<`"../../strats/HistDataAPPLE.csv"
prc:|0.0,.'1_'1_-1_a@\:1

zma:{[w;x]s:0.0,+\x;n:1+(#x)-w;((w-1)#0.0),(s[w+!n]-s[!n])%w}
zstrat:{[w;tr;p]m:zma[w;p];sd:sqrt zma[w;p*p]-m*m;z:((p-m)%(sd+1e-5))*(m>0.0)
  s:-1_ 0.0,((-tr)>z);c:0.0,0.0005*1_1=+':s;r:0.0,1_-':log p
  t:((r*s)-c);100*(exp(+/-1_t))-1}

\t *a[>a:{(zstrat[x;2;prc];x)}'1_!100]
