/
# prelude

The CPU builtins every VM gets at startup — math names and monadic verbs.
\

sqrt:{`sqrt x};sqr:{`sqr x};cbrt:{`cbrt x};
exp:{`exp x};log:{`log x};abs:{`abs x};
sin:{`sin x};cos:{`cos x};tan:{`tan x};
asin:{`asin x};acos:{`acos x};
atan:{`atan x};atan2:{`atan2(x;y)};

first:{*x};last:{*|x};count:{#x};
parse:{`parse x};exec:{`exec x};
depth:{`depth x};epoch:{`epoch x};

sort:{x@<x};

sum:+/;sums:+\;
