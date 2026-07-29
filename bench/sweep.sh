#!/bin/sh
# Sweep the MAX_ARGS cap and report min-of-N for the call-path benchmarks.
# Usage: sh bench/sweep.sh 8 16 32     (rebuilds ReleaseFast for each value)
set -e
SRC=src/noun/operator.zig
ORIG=$(grep -n '^pub const MAX_ARGS' $SRC | head -1 | cut -d: -f2-)
for M in "$@"; do
  sed -i '' "s/^pub const MAX_ARGS = .*/pub const MAX_ARGS = $M;/" $SRC
  zig build -Doptimize=ReleaseFast >/dev/null 2>&1
  echo "=== MAX_ARGS=$M ==="
  for i in 1 2 3 4 5; do ./zig-out/bin/ink bench/call.k; done | paste - - |
    awk '{ if (!($1 in m) || $2 < m[$1]) m[$1]=$2 } END { for (k in m) printf "%-9s %s\n", k, m[k] }' | sort
  for b in "fibonacci.k 20000" "powerset.k 15" "catalan.k 100"; do
    # shellcheck disable=SC2086
    printf '%-9s %s\n' "$(echo $b | cut -d. -f1)" \
      "$(for i in 1 2 3 4 5; do ./zig-out/bin/ink bench/$b | tail -1; done | sort -n | head -1)"
  done
done
sed -i '' "s/^pub const MAX_ARGS = .*/${ORIG}/" $SRC
echo "restored: $ORIG"
