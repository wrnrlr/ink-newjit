#!/usr/bin/env bash
# bench/measure.sh — capture a full performance baseline.
#
# Runs every bench/*.k micro-benchmark AND bench/strats/*.k strategy file
# through each available runtime, wrapping with /usr/bin/time -l to capture:
#   - wall-clock real time
#   - user / system CPU
#   - peak resident set size (bytes)
#   - peak memory footprint (bytes)
#   - instructions retired
#   - cycles elapsed
#   - voluntary / involuntary context switches
# Plus the runtime's own stdout (last numeric line = the benchmark's measurement,
# typically milliseconds from a `\t` operator).
#
# Output: a CSV row per (benchmark, runtime, N, rep) tuple with all columns.
#
# Usage:
#   bash bench/measure.sh [--no-build] [--out CSV] [--sizes a,b,c] [--reps N]
#                        [--micro-only | --strats-only] [--tag NAME]
#
# Records git rev in the output filename and a header row.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GIT_REV="$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
(cd "$ROOT" && git diff-index --quiet HEAD --) 2>/dev/null || GIT_DIRTY="-dirty"

TAG=""
OUT_CSV=""
SIZES_STR="10000,100000,1000000"
OUTER_REPS=3
NO_BUILD=0
MODE="all"   # all | micro | strats

for arg in "$@"; do
  case "$arg" in
    --no-build)    NO_BUILD=1 ;;
    --out=*)       OUT_CSV="${arg#--out=}" ;;
    --sizes=*)     SIZES_STR="${arg#--sizes=}" ;;
    --reps=*)      OUTER_REPS="${arg#--reps=}" ;;
    --tag=*)       TAG="${arg#--tag=}" ;;
    --micro-only)  MODE="micro" ;;
    --strats-only) MODE="strats" ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
    *) echo "unknown arg: $arg" >&2 ; exit 2 ;;
  esac
done

if [[ -z "$OUT_CSV" ]]; then
  TAG_PART="${TAG:+-$TAG}"
  OUT_CSV="$SCRIPT_DIR/results-$GIT_REV$GIT_DIRTY$TAG_PART.csv"
fi

IFS=',' read -ra SIZES <<< "$SIZES_STR"

INK_BASE="$SCRIPT_DIR/ink-baseline-current"
INK_JIT="$SCRIPT_DIR/ink-jit-current"

build_variant() {
  local label="$1" dest="$2"; shift 2
  echo "  zig build -Doptimize=ReleaseFast $*" >&2
  (cd "$ROOT" && zig build -Doptimize=ReleaseFast "$@" >&2) || return 1
  cp "$ROOT/zig-out/bin/ink" "$dest"
}

if [[ $NO_BUILD -eq 0 ]]; then
  echo "=== Building runtimes ===" >&2
  build_variant "baseline" "$INK_BASE"               || { echo "baseline build failed" >&2; exit 1; }
  build_variant "jit"      "$INK_JIT" "-Djit=true"   || echo "jit build failed (continuing without JIT runtime)" >&2
fi

RUNTIMES=()
[[ -x "$INK_BASE" ]] && RUNTIMES+=("baseline:$INK_BASE")
[[ -x "$INK_JIT"  ]] && RUNTIMES+=("jit:$INK_JIT")

if [[ ${#RUNTIMES[@]} -eq 0 ]]; then
  echo "No runtimes available." >&2; exit 1
fi

# ── Parse /usr/bin/time -l output ─────────────────────────────────────────────
# Outputs key=value pairs for downstream CSV.
extract_time_metrics() {
  local f="$1"
  # macOS /usr/bin/time -l layout:
  #   "        0.24 real         0.00 user         0.00 sys"
  #   "            21118976  maximum resident set size"
  #   "            51576689  instructions retired"
  #   "            26002484  cycles elapsed"
  #   "            20333312  peak memory footprint"
  awk '
    /real .* user .* sys/      { real=$1; user=$3; sys=$5 }
    /maximum resident set size/{ rss=$1 }
    /peak memory footprint/    { peak=$1 }
    /instructions retired/     { ins=$1 }
    /cycles elapsed/           { cyc=$1 }
    /voluntary context switches/{ vcs=$1 }
    /involuntary context switches/{ ics=$1 }
    END {
      printf "real=%s user=%s sys=%s rss=%s peak=%s ins=%s cyc=%s vcs=%s ics=%s\n",
        real, user, sys, rss, peak, ins, cyc, vcs, ics
    }
  ' "$f"
}

# ── Run a single (bench, runtime, N) measurement ──────────────────────────────
# Writes one CSV row to $OUT_CSV.
run_one() {
  local kind="$1" bench_file="$2" runtime="$3" binary="$4" N="$5" rep="$6"
  local name="$(basename "$bench_file" .k)"

  local stdout_f stderr_f time_f
  stdout_f=$(mktemp); stderr_f=$(mktemp); time_f=$(mktemp)

  local exit_code=0
  if [[ "$kind" == "micro" ]]; then
    /usr/bin/time -l "$binary" "$bench_file" "$N" >"$stdout_f" 2>"$time_f" || exit_code=$?
  else
    ( cd "$(dirname "$bench_file")" && /usr/bin/time -l "$binary" "$(basename "$bench_file")" ) \
      >"$stdout_f" 2>"$time_f" || exit_code=$?
  fi

  # Benchmark's own ms value is the last numeric line of stdout.
  local bench_ms
  bench_ms=$(tac "$stdout_f" 2>/dev/null | awk '/^[[:space:]]*-?[0-9]+[[:space:]]*$/{print $1; exit}' || true)
  : "${bench_ms:=}"

  local metrics; metrics=$(extract_time_metrics "$time_f")
  # shellcheck disable=SC2046
  eval $metrics

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$kind" "$name" "$runtime" "$N" "$rep" "$exit_code" "$bench_ms" \
    "${real:-}" "${user:-}" "${sys:-}" "${rss:-}" "${peak:-}" "${ins:-}" "${cyc:-}" \
    >> "$OUT_CSV"

  rm -f "$stdout_f" "$stderr_f" "$time_f"

  printf '\r  [%-6s] %-14s %-9s N=%-8s rep=%d exit=%d bench_ms=%-6s rss=%s' \
    "$kind" "$name" "$runtime" "$N" "$rep" "$exit_code" "${bench_ms:-?}" "${rss:-?}" >&2
}

# ── Header ────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$OUT_CSV")"
{
  echo "# git=$GIT_REV$GIT_DIRTY  tag=$TAG  date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# sizes=$SIZES_STR  reps=$OUTER_REPS  mode=$MODE"
  echo "kind,bench,runtime,N,rep,exit,bench_ms,real_s,user_s,sys_s,rss_b,peak_b,instructions,cycles"
} > "$OUT_CSV"

# ── Micro benchmarks ──────────────────────────────────────────────────────────
if [[ "$MODE" == "all" || "$MODE" == "micro" ]]; then
  echo "" >&2; echo "=== Micro benchmarks ===" >&2
  for bench_file in "$SCRIPT_DIR"/*.k; do
    [[ -f "$bench_file" ]] || continue
    for N in "${SIZES[@]}"; do
      for rt_entry in "${RUNTIMES[@]}"; do
        rt_name="${rt_entry%%:*}"; rt_bin="${rt_entry#*:}"
        for rep in $(seq 1 "$OUTER_REPS"); do
          run_one "micro" "$bench_file" "$rt_name" "$rt_bin" "$N" "$rep"
        done
      done
    done
  done
fi

# ── Strategy benchmarks ───────────────────────────────────────────────────────
if [[ "$MODE" == "all" || "$MODE" == "strats" ]]; then
  echo "" >&2; echo "=== Strategy benchmarks ===" >&2
  for bench_file in "$SCRIPT_DIR"/strats/*.k; do
    [[ -f "$bench_file" ]] || continue
    name="$(basename "$bench_file" .k)"
    # data.k is shared loader, not a runnable strat.
    [[ "$name" == "data" ]] && continue
    [[ "$name" == "check_data" ]] && continue
    for rt_entry in "${RUNTIMES[@]}"; do
      rt_name="${rt_entry%%:*}"; rt_bin="${rt_entry#*:}"
      for rep in $(seq 1 "$OUTER_REPS"); do
        run_one "strat" "$bench_file" "$rt_name" "$rt_bin" "0" "$rep"
      done
    done
  done
fi

echo "" >&2
echo "=== Done ===" >&2
echo "  CSV: $OUT_CSV" >&2
echo "  Rows: $(( $(wc -l < "$OUT_CSV") - 3 ))" >&2
