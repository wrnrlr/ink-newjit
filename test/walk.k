/ https://www.youtube.com/shorts/c8lDKs2vb6A
/ Given a 10 by 10 grid, start at the center, every second you flip a coin twice,
/ for HH you move north, with TT you move south, for HT you move east, with TH you move west
/ How long in avarage does it take to get to the boundry of the grid.

direction: (0 1;0 -1;1 0;-1 0)
bounds: {&/(0<x)&x<9}
brownian: {x+*1?direction}
steps: {# bounds brownian\5 5}@
avg: {(+/x)%#x}
avg[steps'!100000]
