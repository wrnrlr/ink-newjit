#!/usr/bin/env bash
# bench/run.sh — build ink variants and run micro-benchmarks
#
# Builds three ink binaries, then runs every .k file in bench/ with each
# binary at several input sizes.  Results land in bench/report.csv.
#
# Usage:
#   bash bench/run.sh [options]
#
# Options:
#   --no-build      skip compilation; reuse bench/ink-* binaries
#   --no-gpu        skip the JIT+GPU variant (needs Dawn / -Dgpu=true build)
#   --out FILE      write CSV to FILE   (default: bench/report.csv)
#   --sizes N,...   comma-separated N values  (default: 1000,10000,100000,1000000)
#   --reps R        outer repetitions per (bench,runtime,N) triple (default: 3)
#
# CSV columns:
#   name           benchmark file name without .k extension
#   runtime        ink | ink-jit | ink-jit-gpu
#   argument       N (passed as argv[2] to each .k file)
#   reps           inner repetitions baked into the .k file (see comment header)
#   measurement_ms total elapsed ms for <reps> inner iterations (integer)
#
# Per-iteration time:  per_iter_ms = measurement_ms / reps
# Throughput:          see each .k file header for the bytes/iteration formula

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INK_BASE="$SCRIPT_DIR/ink"
INK_JIT="$SCRIPT_DIR/ink-jit"
INK_JIT_GPU="$SCRIPT_DIR/ink-jit-gpu"

OUT_CSV="$SCRIPT_DIR/report.csv"
SIZES_STR="1000,10000,100000,1000000"
OUTER_REPS=3
NO_BUILD=0
NO_GPU=0

for arg in "$@"; do
  case "$arg" in
    --no-build)   NO_BUILD=1 ;;
    --no-gpu)     NO_GPU=1 ;;
    --out=*)      OUT_CSV="${arg#--out=}" ;;
    --sizes=*)    SIZES_STR="${arg#--sizes=}" ;;
    --reps=*)     OUTER_REPS="${arg#--reps=}" ;;
  esac
done

IFS=',' read -ra SIZES <<< "$SIZES_STR"

# ── inner-reps per benchmark (must match the reps: comment in each .k file) ──
# Used only to populate the CSV column so downstream analysis can compute
# per-iteration time as measurement_ms / reps.
declare -A BENCH_REPS
BENCH_REPS=(
  [alloc]=10
  [sum]=10
  [max]=10
  [reverse]=10
  [scan]=10
  [sort]=5
  [sqrt_vec]=10
  [exp_vec]=10
  [inner_sq]=10
  [each_sq]=1
  [group]=5
)
DEFAULT_REPS=10

# ── build ─────────────────────────────────────────────────────────────────────
build_variant() {
  local label="$1"; shift
  local dest="$1"; shift
  local extra_flags=("$@")
  echo "  zig build -Doptimize=ReleaseFast ${extra_flags[*]}"
  if (cd "$ROOT" && zig build -Doptimize=ReleaseFast "${extra_flags[@]}"); then
    cp "$ROOT/zig-out/bin/ink" "$dest"
    echo "  → $dest"
    return 0
  else
    echo "  BUILD FAILED for $label" >&2
    return 1
  fi
}

if [[ $NO_BUILD -eq 0 ]]; then
  echo "=== Building baseline (no JIT, no GPU) ==="
  build_variant "baseline" "$INK_BASE"

  echo "=== Building JIT ==="
  build_variant "jit" "$INK_JIT" "-Djit=true"

  if [[ $NO_GPU -eq 0 ]]; then
    echo "=== Building JIT+GPU ==="
    if build_variant "jit-gpu" "$INK_JIT_GPU" "-Djit=true" "-Dgpu=true"; then
      : # success
    else
      echo "  Skipping GPU benchmarks." >&2
      NO_GPU=1
    fi
  fi
else
  echo "=== Skipping build (--no-build) ==="
fi

# ── collect active runtimes ────────────────────────────────────────────────────
declare -a RUNTIMES=()
declare -A RUNTIME_BIN

try_runtime() {
  local name="$1" bin="$2"
  if [[ -x "$bin" ]]; then
    RUNTIMES+=("$name")
    RUNTIME_BIN["$name"]="$bin"
    echo "  runtime: $name  ($bin)"
  else
    echo "  MISSING: $bin" >&2
  fi
}

echo ""
echo "=== Runtimes ==="
try_runtime "ink"         "$INK_BASE"
try_runtime "ink-jit"     "$INK_JIT"
[[ $NO_GPU -eq 0 ]] && try_runtime "ink-jit-gpu" "$INK_JIT_GPU"

if [[ ${#RUNTIMES[@]} -eq 0 ]]; then
  echo "No ink binaries found. Run without --no-build first." >&2
  exit 1
fi

# ── discover benchmark files ───────────────────────────────────────────────────
mapfile -t BENCH_FILES < <(ls "$SCRIPT_DIR"/*.k 2>/dev/null | sort)

if [[ ${#BENCH_FILES[@]} -eq 0 ]]; then
  echo "No .k files found in $SCRIPT_DIR" >&2
  exit 1
fi

# ── run ───────────────────────────────────────────────────────────────────────
echo ""
echo "=== Running ==="
echo "  benchmarks : ${#BENCH_FILES[@]}"
echo "  runtimes   : ${RUNTIMES[*]}"
echo "  N sizes    : ${SIZES[*]}"
echo "  outer reps : $OUTER_REPS"
echo ""

printf 'name,runtime,argument,reps,measurement_ms\n' > "$OUT_CSV"

TOTAL=$(( ${#BENCH_FILES[@]} * ${#SIZES[@]} * ${#RUNTIMES[@]} * OUTER_REPS ))
DONE=0

for bench_file in "${BENCH_FILES[@]}"; do
  name="$(basename "$bench_file" .k)"
  inner_reps="${BENCH_REPS[$name]:-$DEFAULT_REPS}"

  for N in "${SIZES[@]}"; do
    for runtime in "${RUNTIMES[@]}"; do
      binary="${RUNTIME_BIN[$runtime]}"

      for ((rep=1; rep<=OUTER_REPS; rep++)); do
        ms="$("$binary" "$bench_file" "$N" 2>/dev/null)" || ms="-1"
        printf '%s,%s,%d,%d,%s\n' "$name" "$runtime" "$N" "$inner_reps" "$ms" >> "$OUT_CSV"
        DONE=$(( DONE + 1 ))
        PCT=$(( DONE * 100 / TOTAL ))
        printf '\r  [%3d%%] %-14s %-12s N=%-9d rep=%d    ' \
          "$PCT" "$name" "$runtime" "$N" "$rep" >&2
      done
    done
  done
done

printf '\r%80s\r' '' >&2   # clear the progress line
echo "=== Done ==="
echo "  CSV:  $OUT_CSV"
echo "  Rows: $(( $(wc -l < "$OUT_CSV") - 1 ))"
echo ""
echo "Load in ink for analysis:"
echo "  d:\`csv 0:\"$OUT_CSV\""
echo "  per_iter: (0.0+d[\`measurement_ms])%d[\`reps]"
