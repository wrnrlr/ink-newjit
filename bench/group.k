/ group family throughput: `ink bench/group.k <n> <distinct>`
/ prints total ms for 20 reps, one line per op, in this order:
/   +/d   =d   #'=d   <d   ?d   =L (general-list group over n%100 items)
N: `I$`argv[2]
U: `I$`argv[3]
d: N?!U
L: ,'(N div 100)?!U
\t:20 +/d
\t:20 =d
\t:20 #'=d
\t:20 <d
\t:20 ?d
\t:20 =L
