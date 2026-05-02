#!/usr/bin/env python3
"""
Multi-language array benchmark: ink vs ngn/k vs goal vs q/kdb+

Usage:
  python3 tool/bench_multi.py [--out bench/multi.json] [--open]
"""

import argparse
import json
import os
import pathlib
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).parent.parent
CSV_PATH = ROOT / "test" / "KStrategies" / "HistDataAPPLE.csv"

BACKENDS = {
    "ink": {
        "cmd": [str(ROOT / "zig-out" / "bin" / "ink")],
        "mode": "stdin",
        "terminator": "",
    },
    "ngn/k": {
        "cmd": [os.path.expanduser("~/.k/k")],
        "mode": "stdin",
        "terminator": "",
    },
    "goal": {
        "cmd": [os.path.expanduser("~/Code/goal/goal")],
        "mode": "stdin",
        "terminator": "",
    },
    "q": {
        "cmd": [os.path.expanduser("~/.kx/bin/q"), "-q"],
        "mode": "stdin",
        "terminator": "\n\\",
    },
}

# ─── N-parameterised micro-benchmarks ─────────────────────────────────────────
# Each "exprs" key maps backend name → expression (use {N} as size placeholder).
# For goal (REPL mode via stdin) the result is printed but we don't care.
# For q use trailing ";" to suppress large output + "\n\" to exit.

BENCHMARKS = [
    # ── Basic verbs ──────────────────────────────────────────────────────────
    {
        "name": "baseline",
        "desc": "Allocate range !N / til N",
        "group": "basic",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "!{N}",
            "ngn/k": "!{N}",
            "goal":  "!{N}",
            "q":     "til {N};",
        },
    },
    {
        "name": "sum",
        "desc": "Sum fold +/",
        "group": "basic",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "+/0.0+!{N}",
            "ngn/k": "+/0.0+!{N}",
            "goal":  "+/0.0+!{N}",
            "q":     "sum 0.0+til {N};",
        },
    },
    {
        "name": "max",
        "desc": "Max fold |/",
        "group": "basic",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "|/!{N}",
            "ngn/k": "|/!{N}",
            "goal":  "|/!{N}",
            "q":     "max til {N};",
        },
    },
    {
        "name": "reverse",
        "desc": "Double-reverse (round-trip)",
        "group": "basic",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "||!{N}",
            "ngn/k": "||!{N}",
            "goal":  "||!{N}",
            "q":     "reverse reverse til {N};",
        },
    },
    {
        "name": "grade",
        "desc": "Grade-up of reversed range (sort-indices)",
        "group": "basic",
        "complexity": "O(N log N)",
        "exprs": {
            "ink":   "<|!{N}",
            "ngn/k": "<|!{N}",
            "goal":  "<|!{N}",
            "q":     "iasc neg til {N};",
        },
    },
    {
        "name": "distinct",
        "desc": "Distinct ? (N random draws from 0..99)",
        "group": "basic",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "?{N}?!100",
            "ngn/k": "?{N}?!100",
            "goal":  "?{N}?!100",
            "q":     "distinct {N}?100i;",
        },
    },
    {
        "name": "group",
        "desc": "Group = (100 buckets, N elements)",
        "group": "basic",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "={N}?!100",
            "ngn/k": "={N}?!100",
            "goal":  "={N}?!100",
            "q":     "group {N}?100i;",
        },
    },
    # ── Math / reduce ────────────────────────────────────────────────────────
    {
        "name": "sqrt",
        "desc": "Element-wise sqrt",
        "group": "math",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "sqrt 0.0+!{N}",
            "ngn/k": "%0.0+!{N}",           # % is sqrt in ngn/k
            "goal":  "sqrt 0.0+!{N}",
            "q":     "sqrt 0.0+til {N};",
        },
    },
    {
        "name": "exp",
        "desc": "Element-wise exp",
        "group": "math",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "exp 0.0+!{N}",
            "ngn/k": "`exp 0.0+!{N}",
            "goal":  "exp 0.0+!{N}",
            "q":     "exp 0.0+til {N};",
        },
    },
    {
        "name": "log",
        "desc": "Element-wise log",
        "group": "math",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "log 1.0+!{N}",
            "ngn/k": "`ln 1.0+!{N}",
            "goal":  "log 1.0+!{N}",
            "q":     "log 1.0+til {N};",
        },
    },
    {
        "name": "scan_sum",
        "desc": "Prefix sum scan +\\",
        "group": "math",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "+\\0.0+!{N}",
            "ngn/k": "+\\0.0+!{N}",
            "goal":  "+\\0.0+!{N}",
            "q":     "sums 0.0+til {N};",
        },
    },
    {
        "name": "inner_product",
        "desc": "Sum-of-squares inner product",
        "group": "math",
        "complexity": "O(N)",
        "exprs": {
            "ink":   "x:0.0+!{N}; +/x*x",
            "ngn/k": "x:0.0+!{N}; +/x*x",
            "goal":  "x:0.0+!{N}; +/x*x",
            "q":     "x:0.0+til {N}; sum x*x;",
        },
    },
]

# ─── Script-based strategy benchmarks ─────────────────────────────────────────
# Run whole script files; time from process start to exit.

STRATEGY_BENCHMARKS = [
    {
        "name": "ma_crossover",
        "desc": "MA Crossover: 2D param sweep (190 backtests, 1249-day AAPL)",
        "scripts": {
            "ink":   str(ROOT / "test" / "KStrategies" / "ink_ma.k"),
            "ngn/k": str(ROOT / "test" / "KStrategies" / "ngnk_ma.k"),
        },
    },
    {
        "name": "zscore_arb",
        "desc": "Z-Score Arb: 1D sweep (99 windows, 1249-day AAPL)",
        "scripts": {
            "ink":   str(ROOT / "test" / "KStrategies" / "ink_zscore.k"),
            "ngn/k": str(ROOT / "test" / "KStrategies" / "ngnk_zscore.k"),
        },
    },
    {
        "name": "rsi_momentum",
        "desc": "RSI Momentum: 1D sweep (38 windows, fixed threshold)",
        "scripts": {
            "ink":   str(ROOT / "test" / "KStrategies" / "ink_rsi.k"),
            "ngn/k": str(ROOT / "test" / "KStrategies" / "ngnk_rsi.k"),
        },
    },
]

SIZES   = [1_000, 10_000, 100_000, 1_000_000]
REPS    = 5
TIMEOUT = 15


def run_expr(backend: str, expr: str) -> float | None:
    cfg = BACKENDS[backend]
    src = expr + cfg["terminator"]
    t0 = time.perf_counter()
    try:
        r = subprocess.run(
            cfg["cmd"],
            input=src.encode(),
            capture_output=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return None
    t1 = time.perf_counter()
    if r.returncode != 0:
        return None
    return (t1 - t0) * 1000.0


def run_script(backend: str, path: str) -> float | None:
    cfg = BACKENDS[backend]
    if not os.path.exists(path):
        return None
    # For script-based: pass the file path as argument (all backends support this)
    cmd = cfg["cmd"] + [path]
    t0 = time.perf_counter()
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return None
    t1 = time.perf_counter()
    if r.returncode != 0:
        return None
    return (t1 - t0) * 1000.0


def bench_micro(backends: list[str]) -> dict:
    results = {}
    baseline: dict[str, dict[int, float]] = {b: {} for b in backends}

    total = len(BENCHMARKS) * len(SIZES) * len(backends)
    done = 0

    for bm in BENCHMARKS:
        name = bm["name"]
        results[name] = {
            "description": bm["desc"],
            "group": bm["group"],
            "complexity": bm["complexity"],
            "backends": {},
        }

        for backend in backends:
            expr_tmpl = bm["exprs"].get(backend)
            if expr_tmpl is None:
                done += len(SIZES)
                continue

            results[name]["backends"][backend] = {}

            for N in SIZES:
                expr = expr_tmpl.replace("{N}", str(N))
                times = []
                for _ in range(REPS):
                    ms = run_expr(backend, expr)
                    if ms is not None:
                        times.append(ms)
                done += 1
                pct = done * 100 // total
                label = f"{backend}/{name}(N={N:,})"

                if times:
                    med = statistics.median(times)
                    print(f"  [{pct:3d}%] {label:<45} {med:7.2f} ms")
                    results[name]["backends"][backend][N] = {
                        "median_ms": round(med, 3),
                        "min_ms":    round(min(times), 3),
                        "max_ms":    round(max(times), 3),
                        "reps":      len(times),
                    }
                    if name == "baseline":
                        baseline[backend][N] = med
                else:
                    print(f"  [{pct:3d}%] {label:<45}   ERROR")
                    results[name]["backends"][backend][N] = None

    # Subtract baseline startup cost → net_ms
    for name, data in results.items():
        if name == "baseline":
            continue
        for backend, sizes_data in data["backends"].items():
            for N, entry in sizes_data.items():
                if entry is None:
                    continue
                base = baseline.get(backend, {}).get(N, 0.0)
                entry["net_ms"] = round(max(entry["median_ms"] - base, 0.0), 3)

    return results


def bench_strategies(backends: list[str]) -> dict:
    results = {}
    for bm in STRATEGY_BENCHMARKS:
        name = bm["name"]
        results[name] = {
            "description": bm["desc"],
            "backends": {},
        }
        for backend in backends:
            path = bm["scripts"].get(backend)
            if path is None:
                continue
            times = []
            for _ in range(3):
                ms = run_script(backend, path)
                if ms is not None:
                    times.append(ms)
            label = f"{backend}/{name}"
            if times:
                med = statistics.median(times)
                print(f"  {label:<40} {med:7.2f} ms")
                results[name]["backends"][backend] = {
                    "median_ms": round(med, 3),
                    "min_ms":    round(min(times), 3),
                    "reps":      len(times),
                }
            else:
                print(f"  {label:<40}   SKIP (script not found or error)")
                results[name]["backends"][backend] = None
    return results


HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Array Language Benchmark — ink vs ngn/k vs goal vs q</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: 'Menlo','Monaco',monospace; background:#0f1117; color:#e2e8f0; padding:2rem; line-height:1.6; }
h1  { font-size:1.5rem; color:#a5b4fc; margin-bottom:.25rem; }
h2  { font-size:1.1rem; color:#94a3b8; margin:2rem 0 1rem; border-bottom:1px solid #2d3148; padding-bottom:.4rem; }
h3  { font-size:.9rem;  color:#7dd3fc; margin:1.5rem 0 .75rem; }
.meta { font-size:.75rem; color:#64748b; margin-bottom:2rem; }
.grid2 { display:grid; grid-template-columns:1fr 1fr; gap:1.5rem; }
@media(max-width:900px){ .grid2{ grid-template-columns:1fr; } }
.card { background:#1e2130; border:1px solid #2d3148; border-radius:8px; padding:1.25rem; }
.full { grid-column:1/-1; }
canvas { max-height:300px; }
table { width:100%; border-collapse:collapse; font-size:.77rem; margin-top:.5rem; }
th { color:#64748b; text-align:right; padding:.35rem .6rem; border-bottom:1px solid #2d3148; }
th:first-child { text-align:left; }
td { padding:.3rem .6rem; text-align:right; border-bottom:1px solid #1a1d2e; }
td:first-child { text-align:left; color:#a5b4fc; }
tr:hover td { background:#252840; }
.badge { display:inline-block; font-size:.62rem; padding:1px 5px; border-radius:3px; background:#1a2540; color:#60a5fa; margin-left:.35rem; }
.err { color:#f87171; }
.best { color:#34d399; font-weight:bold; }
.note { font-size:.72rem; color:#64748b; margin-top:.75rem; }
</style>
</head>
<body>
<h1>Array Language Benchmarks: ink · ngn/k · goal · q</h1>
<div class="meta" id="meta"></div>

<h2>Basic Array Verbs</h2>
<div class="grid2" id="charts-basic"></div>

<h2>Heavy Math</h2>
<div class="grid2" id="charts-math"></div>

<h2>Results Tables</h2>
<div id="tables"></div>

<h2>Trading Strategy Benchmarks</h2>
<div class="card" id="strategy-table"></div>

<script>
const DATA = __DATA__;

const COLORS = {
  "ink":   "#a78bfa",
  "ngn/k": "#34d399",
  "goal":  "#f59e0b",
  "q":     "#60a5fa",
};
const BACKENDS = Object.keys(COLORS);
const sizes = DATA.sizes;

document.getElementById("meta").textContent =
  `generated: ${DATA.generated}  ·  sizes: ${sizes.map(n=>n>=1e6?(n/1e6)+"M":n>=1e3?(n/1e3)+"k":n).join(", ")}  ·  5 reps each`;

function makeChart(container, title, benchmarks, useNet) {
  const wrap = document.createElement("div");
  wrap.className = "card";
  wrap.innerHTML = `<h3>${title}</h3><canvas id="c_${title.replace(/\W/g,"_")}"></canvas>`;
  container.appendChild(wrap);
  const datasets = [];
  for (const [bname, color] of Object.entries(COLORS)) {
    const data = sizes.map(N => {
      const e = benchmarks?.backends?.[bname]?.[N];
      if (!e) return null;
      return useNet ? (e.net_ms ?? e.median_ms) : e.median_ms;
    });
    if (data.some(v=>v!=null)) {
      datasets.push({ label: bname, data, borderColor: color, backgroundColor: color+"22",
        tension:.3, pointRadius:4, pointHoverRadius:6 });
    }
  }
  new Chart(wrap.querySelector("canvas"), {
    type:"line", data:{
      labels: sizes.map(n=>n>=1e6?(n/1e6)+"M":n>=1e3?(n/1e3)+"k":String(n)),
      datasets,
    },
    options:{
      responsive:true,
      interaction:{mode:"index",intersect:false},
      scales:{
        x:{ grid:{color:"#1e2130"}, ticks:{color:"#64748b"} },
        y:{ grid:{color:"#1e2130"}, ticks:{color:"#64748b", callback:v=>v.toFixed(1)+"ms"} },
      },
      plugins:{
        legend:{labels:{color:"#94a3b8",boxWidth:12,font:{size:11}}},
        tooltip:{callbacks:{label:ctx=>` ${ctx.dataset.label}: ${ctx.parsed.y?.toFixed(2)} ms`}},
      },
    },
  });
}

// Build charts per group
const basicC  = document.getElementById("charts-basic");
const mathC   = document.getElementById("charts-math");
for (const [name, bm] of Object.entries(DATA.benchmarks)) {
  if (name === "baseline") continue;
  const container = bm.group === "math" ? mathC : basicC;
  makeChart(container, `${name} — ${bm.description} (${bm.complexity})`, bm, true);
}

// Summary tables per group
const tablesDiv = document.getElementById("tables");
for (const group of ["basic","math"]) {
  const names = Object.entries(DATA.benchmarks)
    .filter(([,b])=>b.group===group)
    .map(([n])=>n);
  if (!names.length) continue;

  const section = document.createElement("div");
  section.className = "card";
  section.style.marginBottom = "1.5rem";
  section.innerHTML = `<h3>${group === "basic" ? "Basic Verbs" : "Math Operations"} — net median ms (startup subtracted)</h3>`;

  const tbl = document.createElement("table");
  const hdrs = ["benchmark", "complexity", ...BACKENDS.flatMap(b=>[b])];
  tbl.innerHTML = `<thead><tr>${hdrs.map(h=>`<th>${h}</th>`).join("")}</tr></thead>`;
  const tbody = document.createElement("tbody");
  for (const name of names) {
    const bm = DATA.benchmarks[name];
    // find best backend at N=1M
    const vals = {};
    for (const b of BACKENDS) {
      const e = bm.backends?.[b]?.[1000000];
      vals[b] = e ? (e.net_ms ?? e.median_ms) : null;
    }
    const validVals = Object.values(vals).filter(v=>v!=null);
    const best = validVals.length ? Math.min(...validVals) : null;
    const cells = [
      `${name}<span class="badge">${bm.complexity}</span>`,
      bm.description,
      ...BACKENDS.map(b => {
        const v = vals[b];
        if (v === null) return `<span class="err">—</span>`;
        const cls = v === best ? " class=\"best\"" : "";
        return `<span${cls}>${v.toFixed(1)}</span>`;
      }),
    ];
    tbody.innerHTML += `<tr>${cells.map(c=>`<td>${c}</td>`).join("")}</tr>`;
  }
  tbl.appendChild(tbody);
  section.appendChild(tbl);
  section.innerHTML += `<div class="note">Values at N=1,000,000. Green = fastest. "Net" subtracts per-backend startup/baseline time.</div>`;
  tablesDiv.appendChild(section);
}

// Strategy table
const stDiv = document.getElementById("strategy-table");
if (DATA.strategies && Object.keys(DATA.strategies).length) {
  const tbl = document.createElement("table");
  tbl.innerHTML = `<thead><tr><th>strategy</th><th>description</th>${BACKENDS.map(b=>`<th>${b}</th>`).join("")}</tr></thead>`;
  const tbody = document.createElement("tbody");
  for (const [name, s] of Object.entries(DATA.strategies)) {
    const vals = {};
    for (const b of BACKENDS) {
      const e = s.backends?.[b];
      vals[b] = e ? e.median_ms : null;
    }
    const validVals = Object.values(vals).filter(v=>v!=null);
    const best = validVals.length ? Math.min(...validVals) : null;
    const cells = [
      name, s.description,
      ...BACKENDS.map(b => {
        const v = vals[b];
        if (v === null) return `<span class="err">—</span>`;
        const cls = v === best ? " class=\"best\"" : "";
        return `<span${cls}>${v.toFixed(0)} ms</span>`;
      }),
    ];
    tbody.innerHTML += `<tr>${cells.map(c=>`<td>${c}</td>`).join("")}</tr>`;
  }
  tbl.appendChild(tbody);
  stDiv.appendChild(tbl);
  stDiv.innerHTML += `<div class="note">Whole-script timing including CSV load, parsing, param sweep, and output. 3 reps.</div>`;
} else {
  stDiv.innerHTML = "<p style='color:#64748b'>Strategy benchmarks not yet run.</p>";
}
</script>
</body>
</html>
"""


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--out",  default=str(ROOT / "bench" / "multi.json"))
    p.add_argument("--html", default=str(ROOT / "bench" / "multi.html"))
    p.add_argument("--open", action="store_true")
    p.add_argument("--backends", default="ink,ngn/k,goal,q",
                   help="comma-separated list of backends to run")
    p.add_argument("--no-strategies", action="store_true")
    args = p.parse_args()

    active_backends = [b.strip() for b in args.backends.split(",")]

    # Verify backends
    for b in active_backends:
        cfg = BACKENDS.get(b)
        if cfg is None:
            sys.exit(f"unknown backend: {b}")
        exe = cfg["cmd"][0]
        if not os.path.isfile(exe):
            sys.exit(f"backend '{b}' binary not found: {exe}")

    print(f"Backends: {', '.join(active_backends)}")
    print(f"Sizes:    {[f'{n:,}' for n in SIZES]}")
    print(f"Reps:     {REPS}\n")

    print("=== Micro-benchmarks ===")
    micro = bench_micro(active_backends)

    strategies = {}
    if not args.no_strategies:
        print("\n=== Strategy benchmarks ===")
        strategies = bench_strategies(active_backends)

    payload = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "backends":  active_backends,
        "sizes":     SIZES,
        "benchmarks": micro,
        "strategies": strategies,
    }

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2))
    print(f"\nJSON  → {out}")

    html_path = pathlib.Path(args.html)
    data_js = json.dumps(payload, separators=(",", ":"))
    html_path.write_text(HTML_TEMPLATE.replace("__DATA__", data_js))
    print(f"HTML  → {html_path}")

    if args.open:
        import webbrowser
        webbrowser.open(html_path.as_uri())


if __name__ == "__main__":
    main()
