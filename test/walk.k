/ https://www.youtube.com/shorts/c8lDKs2vb6A
/ Start at the center of a 10 by 10 grid, every second you flip a coin twice,
/ for HH move north, TT move south, HT move east, TH move west.
/ How long on avarage does it take to get to the boundry of the grid?

direction: (0 1;0 -1;1 0;-1 0)
bounds: {&/(0<x)&x<9}
brownian: {x+*1?direction}
steps: {# bounds brownian\5 5}
avg: {(+/x)%#x}
avg[steps@'!100000]
