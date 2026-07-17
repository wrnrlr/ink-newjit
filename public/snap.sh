#!/bin/sh
# Capture headless PNG screenshots of the GPU demos in demo/ using `ink -snap`,
# collecting each into out/demo/<name>.png alongside its k source.
#
# Runs from the repo root so demos that load fonts / data by relative path work.
# Failures (a demo that needs a display, args, or hangs) are skipped, not fatal.

set -u
cd "$(dirname "$0")/.." || exit 1

INK=${INK:-zig-out/bin/ink}
OUT=out/demo
mkdir -p "$OUT"

if [ ! -x "$INK" ]; then
  echo "snap: $INK not found — run 'make build' first" >&2
  exit 1
fi

# demo:capture-time(seconds)  — curated visual demos that render a frame
DEMOS="
cloth:3.5
sphere:1
eyes:0.6
sword:1
scene:1
pbr:1
typeset:0.5
earth:0.5
"

captured=0
for spec in $DEMOS; do
  name=${spec%%:*}
  t=${spec##*:}
  src="demo/$name.k"
  [ -f "$src" ] || { echo "snap: skip $name (no $src)"; continue; }

  echo "snap: $name (t=$t)"
  rm -f "$name"-snap*.png
  # Hidden offscreen render; kill if it overruns.
  timeout 40 "$INK" -snap "$t" "$src" >/dev/null 2>&1

  shot=$(ls -t "$name"-snap*.png 2>/dev/null | head -1)
  if [ -n "$shot" ] && [ -f "$shot" ]; then
    mv -f "$shot" "$OUT/$name.png"
    rm -f "$name"-snap*.png
    cp -f "$src" "$OUT/$name.k"
    captured=$((captured + 1))
    echo "  -> $OUT/$name.png"
  else
    echo "  -> skipped (no frame captured)"
  fi
done

echo "snap: captured $captured demo(s) into $OUT"
