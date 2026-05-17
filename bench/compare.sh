#!/usr/bin/env bash
# bench/compare.sh — diff two measurement CSVs and report deltas.
#
# Usage:
#   bash bench/compare.sh BASELINE.csv NEW.csv
#
# For each (kind, bench, runtime, N) the script computes the median of
# bench_ms / rss_b across reps, then prints:
#   - delta in ms (positive = slower than baseline)
#   - speedup factor (>1 = faster)
#   - delta in peak RSS bytes
#   - whether either run crashed (exit != 0)

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 BASELINE.csv NEW.csv" >&2
  exit 2
fi

BASE="$1"; NEW="$2"

awk -F, -v base="$BASE" -v new="$NEW" '
  BEGIN {
    # Load baseline into b[key] = list of bench_ms; same for rss.
  }
  function key(line, F, _) {
    return F[1] "|" F[2] "|" F[3] "|" F[4]
  }
  function median(arr, n,   i, j, tmp) {
    for (i = 1; i < n; i++)
      for (j = i+1; j <= n; j++)
        if (arr[i]+0 > arr[j]+0) { tmp=arr[i]; arr[i]=arr[j]; arr[j]=tmp }
    if (n % 2) return arr[(n+1)/2]+0
    return (arr[n/2]+0 + arr[n/2+1]+0) / 2
  }
  FNR == 1 && FILENAME == base { which="b"; next }
  FNR <= 3 && FILENAME == base { next }   # header lines start with # or column header
  FNR == 1 && FILENAME == new  { which="n"; next }
  FNR <= 3 && FILENAME == new  { next }
  /^#/ { next }
  /^kind,/ { next }
  {
    k = $1 "|" $2 "|" $3 "|" $4
    if (which == "b") {
      keys_b[k] = 1
      n_b[k]++; ms_b[k, n_b[k]] = $7+0; rss_b[k, n_b[k]] = $11+0; ex_b[k] = (ex_b[k] || $6+0)
    } else {
      keys_n[k] = 1
      n_n[k]++; ms_n[k, n_n[k]] = $7+0; rss_n[k, n_n[k]] = $11+0; ex_n[k] = (ex_n[k] || $6+0)
    }
  }
  END {
    printf "%-7s %-12s %-10s %-9s | %10s %10s %10s | %s\n",
      "kind","bench","runtime","N","base_ms","new_ms","speedup","note"
    for (k in keys_b) {
      split(k, a, "|")
      if (!(k in keys_n)) { note = "(missing in new)"; continue }
      delete tmp_b; delete tmp_n
      for (i=1;i<=n_b[k];i++) tmp_b[i] = ms_b[k,i]
      for (i=1;i<=n_n[k];i++) tmp_n[i] = ms_n[k,i]
      mb = median(tmp_b, n_b[k]); mn = median(tmp_n, n_n[k])
      speedup = (mn > 0) ? mb / mn : 0
      note = ""
      if (ex_b[k]) note = note "BASE_CRASH(" ex_b[k] ") "
      if (ex_n[k]) note = note "NEW_CRASH(" ex_n[k] ") "
      printf "%-7s %-12s %-10s %-9s | %10.2f %10.2f %10.2fx | %s\n",
        a[1], a[2], a[3], a[4], mb, mn, speedup, note
    }
  }
' "$BASE" "$NEW" | sort -k1,1 -k2,2 -k3,3 -k4,4n
