/ Shared data loader for the trading-strategy benchmarks.
/ Loads strats/HistDataAPPLE.csv → `prc` (float vector of ~1255 closes).
/ Uses bracket-column-select `a[;1]` instead of `+a` to avoid the
/ ragged-string transpose bug in ink.
a:(","\'a:0:<`"../../strats/HistDataAPPLE.csv")
prc:|0,{[k]. 1_ k}'1_a[;1]
