seq::0;ID:{seq+::1;seq};
particle:[[]id:!0;x:!0.;y:!0.;vx:!0.;vy:!0.]
particle,:particle!(ID[];0.;0.;1.;0.)
/ particle,:particle!((Id();5.;5.;0.;0.)
/                      (Id();9.;0.;-1.;0.));
query:{x@&y[x]}
move:{@[x;`x`y;:;(x`x`y)+x`vx`vy]}
groundfloor:{@[x;`y;:;0.|x`y]}
particle:particle{y x}/(move;groundfloor)
/(particle{y x}/)::(move;groundfloor)
` 0: "after Tick (move;groundfloor):\n",$particle
` 0: "Particles moving right:\n",$query[particle;{`vx>0}]
` 0: "Get entity 2:\n",$query[particle;{x`id=2}]
particle[{~x`id=1}]:;
particle:query[particle;{x`id=1}]
` 0: "after Despawn 1:\n",$particle

/ sparse component via native LEFT JOIN - a Boost on just entities 0 and 2 — a keyed table; the join 0-fills entities without it
boost:: [[id:0 2]boost:100. 50.]
J:: particle,boost
` 0: "Particle left-joined with sparse Boost (0 where absent):"
` 0: $J
` 0: "apply the boost to px in one column op:"
` 0: $@[J;`px;:;(J`px)+J`boost]
