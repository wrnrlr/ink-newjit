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
check kkred   test/kkred.k   'FAIL '     'kkred: [0-9]+ ok, 0 fail'
check kkint   test/kkint.k   'FAIL '     'kkint: [0-9]+ ok, 0 fail'
# kkbits: the bits CPU backend (lib/bits.k) interprets each nn kernel's neutral IR
# and must match the GPU-lowered SPIR-V from the SAME lambda (cross-backend oracle).
check kkbits  test/kkbits.k  'FAIL '     'kkbits: [0-9]+ ok, 0 fail'
# kkgrp: tier-2 histogram kk.freq (scatter-add) vs the CPU freq peephole.
check kkgrp   test/kkgrp.k   'FAIL '     'kkgrp: [0-9]+ ok, 0 fail'
check walkgpu test/walkgpu.k 'walkgpu: FAIL'  'walkgpu: PASS'
# clothgpu: native f32-atomic XPBD (kk2 §7). INK_CLOTH_CHECK runs the headless
# drape invariant instead of opening a window; asserts no NaN + physical drape.
INK_CLOTH_CHECK=1 check clothgpu test/clothgpu.k 'FAIL|lacks atomicFadd' 'clothgpu: .*PASS'

# spirv-val every kkgold module dump (optional — skipped when the validator or
# python3 is missing). This catches type errors MoltenVK silently tolerates
# (e.g. an OpIEqual fed a float const), which numeric oracles can miss.
if command -v spirv-val >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  echo "==> oracle: spirv-val (kkgold module dumps)"
  "$INK" test/kkgold.k 2>/dev/null | python3 -c '
import sys, struct, subprocess
ok = bad = 0
for line in sys.stdin:
    if ":" not in line: continue
    name, rest = line.split(":", 1)
    words = rest.split()
    if len(words) < 10 or not words[0].isdigit(): continue
    buf = b"".join(struct.pack("<I", int(w) & 0xFFFFFFFF) for w in words)
    r = subprocess.run(["spirv-val", "--target-env", "vulkan1.2", "-"], input=buf, capture_output=True)
    if r.returncode == 0: ok += 1
    else:
        bad += 1
        print("INVALID:", name.strip(), r.stderr.decode().splitlines()[0] if r.stderr else "")
print(f"spirv-val: {ok} valid, {bad} invalid")
sys.exit(1 if bad else 0)
' || { echo "ORACLE FAIL: spirv-val"; fail=1; }
  [ "$fail" -eq 0 ] && echo "ORACLE OK: spirv-val"
fi

if [ "$fail" -ne 0 ]; then
  echo "oracles: FAILED"
  exit 1
fi
echo "oracles: all passed"
