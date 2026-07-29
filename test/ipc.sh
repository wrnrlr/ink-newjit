#!/bin/sh
# IPC integration tests.
#   1. text protocol   — test/server.k  + test/client.k   (0: line framing)
#   2. binary protocol — test/ipcback.k + test/ipcgate.k + test/ipccli.k
#                        (2: values, dyadic handlers, `on callbacks, po/pc)
#
# No `set -e`: several checks are `grep`s whose "no match" result is normal, and
# under -e the first of those would abort the run with the tests still passing.

INK=${INK:-zig-out/bin/ink}
TMP=$(mktemp -d)
RC=0
BACK_PID=
GATE_PID=

cleanup() {
  # `wait` after the kill so the shell reaps them quietly instead of printing a
  # "Terminated" line per background job.
  for p in "$BACK_PID" "$GATE_PID"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  rm -rf "$TMP"
  # `wait` on a killed job leaves $? at 143, which would otherwise become the
  # script's own exit status when this runs from the EXIT trap.
  exit $RC
}
trap cleanup EXIT

# Wait for a listener to come up rather than guessing with sleep.  The servers
# bind with SO_REUSEADDR, so a stale process from an earlier run can share the
# port and silently steal the traffic — refuse to start if one is there.
port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
await_port() {
  i=0
  while [ $i -lt 100 ]; do
    port_busy "$1" && return 0
    i=$((i + 1))
    sleep 0.05
  done
  echo "nothing listening on $1 after 5s"
  return 1
}

for p in 5210 5211; do
  if port_busy $p; then
    echo "port $p already in use — kill the stale ink process first"
    RC=1
    exit 1
  fi
done

# ── 1. text protocol ─────────────────────────────────────────────────────────
$INK test/server.k &
SERVER_PID=$!
await_port 5001 || RC=1
$INK test/client.k
CLIENT_RC=$?
wait $SERVER_PID
SERVER_RC=$?

if [ $CLIENT_RC -ne 0 ] || [ $SERVER_RC -ne 0 ]; then
  echo "text ipc FAILED (client=$CLIENT_RC server=$SERVER_RC)"
  RC=1
fi

# ── 2. binary protocol, three tiers ──────────────────────────────────────────
$INK test/ipcback.k >"$TMP/back.log" 2>&1 &
BACK_PID=$!
await_port 5211 || { RC=1; exit 1; }

$INK test/ipcgate.k >"$TMP/gate.log" 2>&1 &
GATE_PID=$!
await_port 5210 || { RC=1; exit 1; }

if ! $INK test/ipccli.k >"$TMP/cli.log" 2>&1; then
  echo "binary ipc client exited non-zero"
  RC=1
fi
cat "$TMP/cli.log"

if grep -q FAIL "$TMP/cli.log"; then
  RC=1
fi
if ! grep -q '^done$' "$TMP/cli.log"; then
  echo "binary ipc client did not run to completion"
  RC=1
fi

# the gateway's po/pc hooks must have seen the client come and go
if grep -q 'peer .* in' "$TMP/gate.log" && grep -q 'peer .* out' "$TMP/gate.log"; then
  echo "po/pc hooks ok"
else
  echo "po/pc hooks FAIL"
  cat "$TMP/gate.log"
  RC=1
fi

if [ $RC -ne 0 ]; then
  echo "ipc test FAILED"
  exit 1
fi

echo "ipc test passed"
exit 0
