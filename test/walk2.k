/ At the boundry E(x,y) = 0
/ E(x,y) = 1+0.25*(E(x+1,y) + E(x-1,y) + E(x,y+1) + E(x,y-1))
/ 4E(x,y) - E(x+1,y) - E(x-1,y) - E(x,y+1) - E(x,y-1) = 4

N: 10
E: N*N # 0.0
xy: 1+!(N-2;N-2)

xy
xy.(32+4)

show: 8 8 #
show E
(show E).4 4

show xy
