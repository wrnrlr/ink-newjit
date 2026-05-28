direction: (0 1;0 -1;1 0;-1 0)
bounds: {&/(0<x)&x<9}
wander: {x+*1?direction}
steps: {# bounds wander\5 5}
avg: {(+/x)%#x}
\t avg[steps@'!100000]
