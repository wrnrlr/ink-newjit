#!/bin/sh
# test/oracles.sh — run the kk2 GPU/compiler oracles headless and FAIL with a
# nonzero exit if any check regresses. Wired into `make qa`.
#
# The oracle .k scripts print their own pass/fail markers but never set $? (a k
# script that prints "FAIL" still exits 0), so we capture each run and grep the
# output: fail if a "bad" marker appears, or if the expected "good" completion
# marker is missing (a crash mid-run leaves the good marker unprinted).
set -u
INK=${INK:-zig-out/bin/ink}
export INK_SNAP=0
fail=0

check() {  # check <name> <script> <bad-regex> <good-regex>
  name=$1; script=$2; bad=$3; good=$4
  echo "==> oracle: $name ($script)"
  out=$("$INK" "$script" 2>&1)
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -Eq "$bad"; then
    echo "ORACLE FAIL: $name — output matched /$bad/"; fail=1
  elif ! printf '%s\n' "$out" | grep -Eq "$good"; then
    echo "ORACLE FAIL: $name — expected /$good/ not found"; fail=1
  else
    echo "ORACLE OK: $name"
  fi
}

check kkgold  test/kkgold.k  'MISMATCH'  'foldMax: identical'
check kkopt   test/kkopt.k   'FAIL '     'kkopt: [0-9]+ ok, 0 fail'
check kkc     test/kkc.k     'FAIL '     'kkc: [0-9]+ ok, 0 fail'
check walkgpu test/walkgpu.k 'walkgpu: FAIL'  'walkgpu: PASS'

if [ "$fail" -ne 0 ]; then
  echo "oracles: FAILED"
  exit 1
fi
echo "oracles: all passed"
