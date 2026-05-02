#!/usr/bin/env python3
"""
Array-language benchmark runner for the `ink` binary.

Usage:
  python3 tool/bench.py [--ink PATH] [--out bench/results.json] [--open] [--build]

  --build   Compile with ReleaseFast before running (recommended for accurate
            numbers; without this the default Debug build dominates timings).

Methodology: each (benchmark, size) pair runs INNER_REPS copies of the
expression in a *single* subprocess to amortise the ~5-10 ms startup cost.
The reported time is (total_subprocess_ms - baseline_startup_ms) / INNER_REPS.
"""

import argparse
import json
import os
import pathlib
import statistics
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).parent.parent
DEFAULT_INK = ROOT / "zig-out" / "bin" / "ink"
DEFAULT_OUT = ROOT / "bench" / "results.json"
HTML_OUT = ROOT / "bench" / "index.html"

# ------------------------------------------------------------------
# Benchmark definitions
# Each entry: (name, description, k_expr_template, complexity)
# Use {N} as size placeholder — replaced with str.replace, not .format().
# ------------------------------------------------------------------
BENCHMARKS = [
    ("baseline", "Allocate range !N",    "!{N}",              "O(N)"),
    ("sum",      "Fold sum +/",          "+/0.0+!{N}",        "O(N)"),
    ("max",      "Fold max |/",          "|/!{N}",            "O(N)"),
    ("reverse",  "Reverse |",           "||!{N}",            "O(N)"),
    ("sort",     "Sort < (worst-case)", "<|!{N}",            "O(N log N)"),
    ("distinct", "Distinct ?",          "?|!{N}",            "O(N)"),
    # Group 100 buckets: N random draws from 0..99 — tests hash-map scaling
    ("group",    "Group = (100 keys)",  "={N}?!100",         "O(N)"),
]

SIZES      = [1_000, 10_000, 100_000, 1_000_000]
REPS       = 5       # outer subprocess repetitions (for median)
INNER_REPS = 20      # iterations per subprocess — amortises startup cost
TIMEOUT_S  = 30      # skip a (bench, N) pair if a single run takes longer


def build_release(root: pathlib.Path) -> None:
    """Compile ink with ReleaseFast optimisation."""
    print("Building ink with -Doptimize=ReleaseFast …")
    r = subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseFast"],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        sys.exit(f"Build failed:\n{r.stderr}")
    print("Build OK\n")


def make_expr(tmpl: str, N: int, inner: int) -> str:
    """Return an ink expression that runs `tmpl` `inner` times then returns 0.

    Each repetition is separated by '; ' so the result of the previous
    expression is dropped before the next one runs.  The trailing '; 0'
    gives the subprocess a stable exit value regardless of the benchmark
    result type.
    """
    single = tmpl.replace("{N}", str(N))
    return "; ".join([single] * inner) + "; 0"


def run_one(ink: str, expr: str) -> float | None:
    """Return elapsed ms for the whole subprocess, or None on error/timeout."""
    t0 = time.perf_counter()
    try:
        r = subprocess.run(
            [ink],
            input=expr.encode(),
            capture_output=True,
            timeout=TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return None
    t1 = time.perf_counter()
    if r.returncode != 0:
        return None
    return (t1 - t0) * 1000.0


def bench_all(ink: str) -> dict:
    results = {}
    baseline_times: dict[int, float] = {}

    total = len(BENCHMARKS) * len(SIZES)
    done = 0

    for name, desc, tmpl, complexity in BENCHMARKS:
        results[name] = {
            "description": desc,
            "complexity": complexity,
            "sizes": {},
        }
        for N in SIZES:
            expr = make_expr(tmpl, N, INNER_REPS)
            times = []
            for _ in range(REPS):
                ms = run_one(ink, expr)
                if ms is not None:
                    times.append(ms)

            done += 1
            pct = done * 100 // total
            label = f"{name}(N={N:,})"
            if times:
                # Divide by INNER_REPS to get per-iteration time.
                per = [t / INNER_REPS for t in times]
                med = statistics.median(per)
                print(f"  [{pct:3d}%] {label:<30} {med:7.3f} ms/iter")
                results[name]["sizes"][N] = {
                    "median_ms": round(med, 4),
                    "min_ms":    round(min(per), 4),
                    "max_ms":    round(max(per), 4),
                    "reps":      len(times),
                }
                if name == "baseline":
                    baseline_times[N] = med
            else:
                print(f"  [{pct:3d}%] {label:<30}   ERROR")
                results[name]["sizes"][N] = None

    # net = per-iteration time minus baseline allocation cost
    for name, data in results.items():
        if name == "baseline":
            continue
        for N, entry in data["sizes"].items():
            if entry is None:
                continue
            base = baseline_times.get(N, 0.0)
            entry["net_ms"] = round(max(entry["median_ms"] - base, 0.0), 4)

    return results


def emit_json(results: dict, out: pathlib.Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "sizes": SIZES,
        "benchmarks": results,
    }
    out.write_text(json.dumps(payload, indent=2))
    print(f"\nResults written to {out}")


HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ink benchmark results</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Menlo', 'Monaco', monospace;
    background: #0f1117;
    color: #e2e8f0;
    padding: 2rem;
    line-height: 1.5;
  }
  h1 { font-size: 1.4rem; color: #a5b4fc; margin-bottom: 0.25rem; }
  .meta { font-size: 0.75rem; color: #64748b; margin-bottom: 2rem; }
  .charts { display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; margin-bottom: 2.5rem; }
  @media (max-width: 900px) { .charts { grid-template-columns: 1fr; } }
  .card {
    background: #1e2130;
    border: 1px solid #2d3148;
    border-radius: 8px;
    padding: 1.25rem;
  }
  .card h2 { font-size: 0.85rem; color: #94a3b8; margin-bottom: 1rem; }
  .card-full { grid-column: 1 / -1; }
  table { width: 100%; border-collapse: collapse; font-size: 0.78rem; }
  th { color: #64748b; text-align: right; padding: 0.4rem 0.75rem; border-bottom: 1px solid #2d3148; }
  th:first-child { text-align: left; }
  td { padding: 0.35rem 0.75rem; text-align: right; border-bottom: 1px solid #1a1d2e; }
  td:first-child { text-align: left; color: #a5b4fc; }
  tr:hover td { background: #252840; }
  .badge {
    display: inline-block;
    font-size: 0.65rem;
    padding: 1px 6px;
    border-radius: 3px;
    background: #1a2540;
    color: #60a5fa;
    margin-left: 0.4rem;
  }
  .err { color: #f87171; }
  canvas { max-height: 280px; }
</style>
</head>
<body>
<h1>ink &mdash; array language benchmarks</h1>
<div class="meta" id="meta"></div>

<div class="charts">
  <div class="card card-full">
    <h2>Raw median time (ms) vs N &mdash; all benchmarks</h2>
    <canvas id="chartAll"></canvas>
  </div>
  <div class="card card-full">
    <h2>Net time (ms, startup subtracted) vs N &mdash; non-baseline</h2>
    <canvas id="chartNet"></canvas>
  </div>
</div>

<div class="card">
  <h2>Results table (median ms)</h2>
  <table id="table"></table>
</div>

<script>
const DATA = __DATA__;

const COLORS = [
  '#a78bfa','#34d399','#f59e0b','#60a5fa','#f472b6','#4ade80','#fb923c',
];

const sizes = DATA.sizes;
const benchmarks = DATA.benchmarks;
const names = Object.keys(benchmarks);

document.getElementById('meta').textContent =
  `generated: ${DATA.generated}  ·  sizes: ${sizes.map(n => n.toLocaleString()).join(', ')}`;

function makeChart(id, datasets, logY = false) {
  const ctx = document.getElementById(id);
  return new Chart(ctx, {
    type: 'line',
    data: {
      labels: sizes.map(n => n >= 1_000_000 ? (n/1_000_000)+'M' : n >= 1_000 ? (n/1_000)+'k' : String(n)),
      datasets,
    },
    options: {
      responsive: true,
      interaction: { mode: 'index', intersect: false },
      scales: {
        x: { grid: { color: '#1e2130' }, ticks: { color: '#64748b' } },
        y: {
          type: logY ? 'logarithmic' : 'linear',
          grid: { color: '#1e2130' },
          ticks: { color: '#64748b', callback: v => v + ' ms' },
        },
      },
      plugins: {
        legend: { labels: { color: '#94a3b8', boxWidth: 12, font: { size: 11 } } },
        tooltip: { callbacks: {
          label: ctx => ` ${ctx.dataset.label}: ${ctx.parsed.y?.toFixed(2)} ms`,
        }},
      },
    },
  });
}

// Chart 1: raw median
const rawDatasets = names.map((name, i) => ({
  label: `${name} (${benchmarks[name].complexity})`,
  data: sizes.map(n => benchmarks[name].sizes[n]?.median_ms ?? null),
  borderColor: COLORS[i % COLORS.length],
  backgroundColor: COLORS[i % COLORS.length] + '22',
  tension: 0.3,
  pointRadius: 4,
}));
makeChart('chartAll', rawDatasets);

// Chart 2: net time (startup subtracted)
const netDatasets = names
  .filter(n => n !== 'baseline')
  .map((name, i) => ({
    label: `${name} (${benchmarks[name].complexity})`,
    data: sizes.map(n => benchmarks[name].sizes[n]?.net_ms ?? null),
    borderColor: COLORS[(i+1) % COLORS.length],
    backgroundColor: COLORS[(i+1) % COLORS.length] + '22',
    tension: 0.3,
    pointRadius: 4,
  }));
makeChart('chartNet', netDatasets);

// Table
const table = document.getElementById('table');
const hdr = ['benchmark', 'complexity', ...sizes.map(n =>
  n >= 1_000_000 ? (n/1_000_000)+'M' : (n/1_000)+'k'
)];
table.innerHTML = '<thead><tr>' + hdr.map((h,i) => `<th>${h}</th>`).join('') + '</tr></thead>';
const tbody = document.createElement('tbody');
for (const name of names) {
  const b = benchmarks[name];
  const cells = [
    `${name}<span class="badge">${b.complexity}</span>`,
    b.description,
    ...sizes.map(n => {
      const e = b.sizes[n];
      if (!e) return '<span class="err">err</span>';
      const net = e.net_ms !== undefined ? ` <span style="color:#64748b">(${e.net_ms})</span>` : '';
      return `${e.median_ms.toFixed(1)}${net}`;
    }),
  ];
  tbody.innerHTML += '<tr>' + cells.map(c => `<td>${c}</td>`).join('') + '</tr>';
}
table.appendChild(tbody);
</script>
</body>
</html>
"""


def emit_html(results: dict, json_path: pathlib.Path) -> None:
    payload = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "sizes": SIZES,
        "benchmarks": results,
    }
    data_js = json.dumps(payload, separators=(",", ":"))
    html = HTML_TEMPLATE.replace("__DATA__", data_js)
    HTML_OUT.write_text(html)
    print(f"Report written to  {HTML_OUT}")


def main() -> None:
    p = argparse.ArgumentParser(description="ink array-language benchmarks")
    p.add_argument("--ink",   default=str(DEFAULT_INK), help="path to ink binary")
    p.add_argument("--out",   default=str(DEFAULT_OUT), help="JSON output path")
    p.add_argument("--open",  action="store_true", help="open HTML report after run")
    p.add_argument("--build", action="store_true",
                   help="compile with -Doptimize=ReleaseFast before benchmarking "
                        "(strongly recommended for accurate measurements)")
    args = p.parse_args()

    if args.build:
        build_release(ROOT)

    ink = args.ink
    if not os.path.isfile(ink):
        sys.exit(f"ink binary not found: {ink}\nRun `zig build -Doptimize=ReleaseFast` first.")

    print(f"ink:        {ink}")
    print(f"reps:       {REPS} outer × {INNER_REPS} inner = {REPS * INNER_REPS} total iterations")
    print(f"sizes:      {[f'{n:,}' for n in SIZES]}\n")

    results = bench_all(ink)
    emit_json(results, pathlib.Path(args.out))
    emit_html(results, pathlib.Path(args.out))

    if args.open:
        import webbrowser
        webbrowser.open(HTML_OUT.as_uri())


if __name__ == "__main__":
    main()
